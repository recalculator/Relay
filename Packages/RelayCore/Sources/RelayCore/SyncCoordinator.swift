import Foundation

/// The part of `CKSyncEngine` the coordinator drives. Production uses
/// `CloudKitEngineControl`, a thin wrapper over a real engine. Tests use a fake that
/// records calls.
///
/// This protocol is the test boundary for remote behavior. Pending-change scheduling,
/// batching, and retry belong to the engine, so the protocol only exposes ways to *tell*
/// the engine about work, never to retry.
public protocol SyncEngineControl: AnyObject, Sendable {
    /// Identifies the engine instance that events come from. Events from any instance
    /// other than the coordinator's current one are ignored.
    var eventSourceID: ObjectIdentifier { get }
    func addPendingSaves(_ ids: [UUID])
    func removePendingSaves(_ ids: [UUID])
    func addPendingZoneSave()
    /// Manual "sync now" (diagnostics). The engine still decides batching.
    func fetchChanges() async throws
    func sendChanges() async throws
    func cancelOperations() async
}

/// Coordinates the local store with CKSyncEngine.
///
/// This file contains no CloudKit types. `CloudKitSync.swift` makes this actor the
/// engine's delegate and translates CloudKit events into the calls below. Tests drive
/// these calls directly with a simulated server.
///
/// ## Invariants
///
/// 1. **An engine exists only while the iCloud account is confirmed and owns this
///    database** (`accountState == .active`). The account is established with
///    `AccountProvider` *before* the engine is created. In every other state there is no
///    engine, so there is nothing that could deliver changes we'd have to drop.
/// 2. **Every event names its source engine.** Events from an engine that has been torn
///    down (after an account change) are ignored entirely, including its state updates.
/// 3. **Engine state is persisted only for the current engine, and only while every
///    change it delivered has been applied.** If applying a fetched change fails, state
///    persistence stops for that engine. The last persisted state therefore never
///    claims a change we don't have, and recreating the engine from it (at the next
///    launch, or via Sync Now) redelivers the change.
///
/// ## Isolation
///
/// An actor, because the engine calls its delegate from background tasks. Every
/// `await` is a suspension point where another call can interleave (reentrancy).
/// Account resolution guards against that with a resolution id: a resolution that was
/// superseded while suspended abandons its result.
public actor SyncCoordinator {
    public enum AccountState: Sendable, Equatable {
        /// Not yet established (startup, or just after an account change). No engine.
        case unknown
        /// Syncing with this account, which owns the local database. Engine running.
        case active(user: String)
        /// No iCloud account, or iCloud is restricted. No engine. Notes stay local.
        case noAccount
        /// iCloud is temporarily unavailable, or the account couldn't be determined.
        /// No engine. Relay waits for `CKAccountChanged` or a retry.
        case waitingForAccount
        /// The database belongs to `bound`, but the device is signed in as `current`.
        /// No engine.
        case mismatch(bound: String, current: String)
    }

    public typealias EngineFactory = @Sendable (_ coordinator: SyncCoordinator, _ state: Data?) -> any SyncEngineControl

    public private(set) var accountState: AccountState = .unknown
    private var store: NoteStore
    private let accounts: any AccountProvider
    private let status: SyncStatusModel?
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void

    private var makeEngine: EngineFactory?
    /// Non-nil only while `accountState` is `.active` (invariant 1).
    private var engine: (any SyncEngineControl)?
    /// False once the current engine delivered a change that couldn't be applied
    /// (invariant 3). Reset when a new engine is created.
    private var canPersistEngineState = true
    /// Incremented by each account resolution. Lets a resolution that was suspended
    /// at an `await` notice that a newer one has started.
    private var resolutionID = 0
    private var accountRetryAttempt = 0
    private(set) var pendingAccountRetry: Task<Void, Never>?

    private var localChangesTask: Task<Void, Never>?
    private var fetchHadError = false
    private var observesLocalChanges = true
    private var accountObserver: (any NSObjectProtocol)?
    private var teardowns: [Task<Void, Never>] = []

    /// Uploads awaiting a result: note id → the `local_version` that was sent.
    ///
    /// When the result arrives, only that version is marked synced. Any edit made after
    /// the snapshot stays pending, so an older upload finishing late can't hide a newer
    /// edit.
    private var inFlight: [UUID: Int64] = [:]

    /// - Parameter sleep: Waits between account-determination retries. Tests inject a
    ///   controllable version.
    public init(
        store: NoteStore,
        status: SyncStatusModel?,
        accountProvider: any AccountProvider,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.store = store
        self.status = status
        self.accounts = accountProvider
        self.now = now
        self.sleep = sleep
    }

    // MARK: Lifecycle

    /// Establishes the iCloud account, checks it against the account that owns the
    /// database, and only then creates the engine (from the persisted state, if it
    /// belongs to that account).
    public func start(makeEngine: @escaping EngineFactory) async {
        await start(makeEngine: makeEngine, observeLocalChanges: true)
    }

    /// `observeLocalChanges: false` is for deterministic tests that announce local
    /// changes explicitly with `localNotesChanged`.
    func start(makeEngine: @escaping EngineFactory, observeLocalChanges: Bool) async {
        self.makeEngine = makeEngine
        self.observesLocalChanges = observeLocalChanges
        await self.observeLocalChanges()
        await resolveAccount()
    }

    /// Call when the account may have changed: on `CKAccountChanged`, which the CloudKit
    /// adapter observes. The cached identity is dropped and the account is checked again.
    public func accountMayHaveChanged() async {
        accounts.invalidate()
        await revalidateAccount()
    }

    /// Re-checks the account using any cached identity. It's called before each engine
    /// fetch and send, and when the app returns to the foreground. If the account is
    /// still the active one, nothing changes. Otherwise the engine is torn down and the
    /// new account is resolved.
    public func revalidateAccount() async {
        guard case .active(let user) = accountState else {
            await resolveAccount()
            return
        }
        resolutionID += 1
        let id = resolutionID
        let account = await accounts.currentAccount()
        guard id == resolutionID, accountState == .active(user: user) else { return }
        switch account {
        case .available(user):
            return
        case .couldNotDetermine, .temporarilyUnavailable:
            // No evidence of a different account. Keep running; the engine itself
            // waits while the account isn't usable.
            return
        case .available, .noAccount, .restricted:
            log("Account changed while syncing; stopping sync before anything else is applied")
            tearDownEngine()
            accountState = .unknown
            await resolveAccount()
        }
    }

    // MARK: Local changes

    /// Tells the engine about notes the user just changed. Called from the store's
    /// change stream. It's only a latency optimization: whenever an engine is created,
    /// every unsynced row is re-queued from the database.
    public func localNotesChanged(_ ids: Set<UUID>) async {
        if case .active = accountState {
            engine?.addPendingSaves(Array(ids))
        }
        await publishPendingCount()
    }

    // MARK: Uploading

    /// Upload data for one pending note, or nil to skip it.
    public func snapshotForUpload(_ id: UUID, from source: ObjectIdentifier) async -> UploadSnapshot? {
        guard isCurrent(source), case .active = accountState else { return nil }
        do throws(StoreError) {
            guard let snapshot = try await store.uploadSnapshot(id: id) else {
                // Nothing to upload (already synced or gone). Drop the stale entry.
                engine?.removePendingSaves([id])
                return nil
            }
            guard isCurrent(source) else { return nil }  // Torn down while reading.
            inFlight[id] = snapshot.localVersion
            return snapshot
        } catch {
            Log.sync.error("Couldn’t read note \(id, privacy: .public) for upload: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    public func canUpload(from source: ObjectIdentifier) -> Bool {
        guard isCurrent(source), case .active = accountState else { return false }
        return true
    }

    /// Applies the per-record results of one sent batch.
    ///
    /// Results from an engine that has since been torn down are ignored. The affected
    /// rows stay pending, and the next upload reconciles them through change tags: if
    /// the ignored save had succeeded, the retry fails with `serverRecordChanged`
    /// carrying identical content, which resolves to "adopt metadata". No duplicate is
    /// created and nothing is lost.
    public func handleSendResults(_ results: [SendResult], from source: ObjectIdentifier) async {
        guard isCurrent(source) else {
            log("Ignored \(results.count) send results from a stopped engine; affected notes stay pending")
            return
        }
        var touched: Set<UUID> = []
        var anySaved = false

        for result in results {
            switch result {
            case .saved(let remote):
                let sentVersion = inFlight.removeValue(forKey: remote.id)
                if sentVersion == nil {
                    Log.sync.error("Save result for note \(remote.id, privacy: .public) with no recorded in-flight version")
                }
                // With an unknown sent version, use 0: the server metadata is stored, but
                // the row stays pending and is re-sent on top of the new base.
                await perform("record upload of \(remote.id)") { store throws(StoreError) in
                    try await store.markUploaded(remote, sentVersion: sentVersion ?? 0)
                }
                touched.insert(remote.id)
                anySaved = true

            case .failed(let id, let failure):
                inFlight[id] = nil
                touched.formUnion(await handleSendFailure(id: id, failure))
            }
        }

        if anySaved { await status?.recordSendSuccess(at: now()) }
        await reconcilePending(touched)
    }

    private func handleSendFailure(id: UUID, _ failure: SendFailure) async -> Set<UUID> {
        switch failure {
        case .conflict(let server):
            log("Server had a newer version of a note; resolving")
            return await applyRemote(.modified(server)) ?? []

        case .recordMissing:
            log("Uploaded note referred to a missing record; recreating")
            return await applyRemote(.recordGone(id)) ?? []

        case .zoneMissing:
            log("Zone missing; recreating it")
            engine?.addPendingZoneSave()
            await perform("clear server metadata") { store throws(StoreError) in try await store.clearServerMetadata(id: id) }
            return [id]

        case .transient(let code):
            // CKSyncEngine keeps the change and retries it once conditions improve,
            // respecting any server retry-after. Re-adding it here would be a second,
            // competing retry mechanism.
            Log.sync.info("Transient send failure (CKError \(code)) for \(id, privacy: .public); engine will retry")
            await status?.recordTransientFailure()
            return []

        case .quotaExceeded:
            await reportProblem("iCloud storage is full. Changes are saved on this device and will upload when space is available.")
            return []

        case .invalid(let code):
            Log.sync.fault("Non-retryable send failure (CKError \(code)) for note \(id, privacy: .public)")
            await reportProblem("A note couldn’t be uploaded (CloudKit error \(code)). It is still saved on this device.")
            return []
        }
    }

    // MARK: Fetching

    /// Applies changes fetched by the current engine.
    ///
    /// * From a stopped engine: ignored. Its state updates are ignored as well
    ///   (invariant 2), so the persisted state still predates these changes and they are
    ///   redelivered by the next engine.
    /// * For a note with an upload in flight: skipped. That upload's result covers it,
    ///   either confirming our version (the change was our own echo) or failing with
    ///   `serverRecordChanged` and carrying the newest server version. If the app dies
    ///   first, the row is still pending, and the re-upload hits the same conflict path.
    /// * If applying fails: state persistence stops for this engine (invariant 3).
    public func handleFetchedChanges(_ changes: [RemoteChange], from source: ObjectIdentifier) async {
        guard isCurrent(source), case .active = accountState else {
            log("Ignored \(changes.count) fetched changes from a stopped engine; they will be fetched again")
            return
        }
        var touched: Set<UUID> = []
        for change in changes {
            let id: UUID = switch change {
            case .modified(let note): note.id
            case .recordGone(let id): id
            }
            if inFlight[id] != nil {
                Log.sync.debug("Deferring fetched change for in-flight note \(id, privacy: .public)")
                continue
            }
            guard let applied = await applyRemote(change) else {
                stopPersistingEngineState(reason: "a fetched change couldn’t be saved")
                continue
            }
            touched.formUnion(applied)
        }
        await reconcilePending(touched)
    }

    public func handleZoneDeleted(_ reason: ZoneDeletionReason, from source: ObjectIdentifier) async {
        guard isCurrent(source), case .active = accountState else { return }
        inFlight.removeAll()
        log("Server zone was removed (\(reason)); reconciling")
        do throws(StoreError) {
            let pending = try await store.handleZoneDeleted(reason)
            engine?.addPendingZoneSave()
            engine?.addPendingSaves(pending)
        } catch {
            stopPersistingEngineState(reason: "a server reset couldn’t be applied")
            await reportProblem("Couldn’t apply a server reset: \(error.localizedDescription)")
        }
        await publishPendingCount()
    }

    // MARK: Engine state and engine-reported account changes

    /// Persists the engine's state, subject to invariants 2 and 3.
    public func handleEngineStateUpdate(_ serialized: Data, from source: ObjectIdentifier) async {
        guard isCurrent(source), case .active = accountState else {
            Log.sync.info("Not persisting state from a stopped engine")
            return
        }
        guard canPersistEngineState else {
            Log.sync.info("Not persisting engine state: an earlier change from this engine wasn’t applied")
            return
        }
        await perform("save engine state") { store throws(StoreError) in try await store.saveEngineState(serialized) }
    }

    /// The engine reports an account transition. Per Apple's documentation, it has
    /// already reset its internal state, including pending changes.
    ///
    /// * The same account that is active (for example a fresh engine announcing the
    ///   current user): benign. Re-queue pending work, since the engine cleared it.
    /// * Anything else: stop this engine immediately, so none of its later events are
    ///   applied, then re-establish the account from scratch.
    public func handleAccountChange(_ change: AccountChange, from source: ObjectIdentifier) async {
        guard isCurrent(source) else {
            log("Ignored account change from a stopped engine")
            return
        }
        log("Engine reported account change: \(change)")
        let reportedUser: String? = switch change {
        case .signIn(let user): user
        case .switchAccounts(_, let current): current
        case .signOut: nil
        }
        if case .active(let user) = accountState, reportedUser == user {
            await queueAllPendingWork()
            return
        }
        tearDownEngine()
        accountState = .unknown
        accounts.invalidate()
        await publishAvailability()
        await resolveAccount()
    }

    // MARK: Account switch (user action)

    /// Replaces the database during an account mismatch: the caller has archived the old
    /// account's database and opened `newStore` at the same path. The new store is bound
    /// to the current account, and a fresh engine fetches that account's data.
    public func startFresh(with newStore: NoteStore) async throws(StoreError) {
        guard case .mismatch(_, let current) = accountState else { return }
        tearDownEngine()
        store = newStore
        await observeLocalChanges()
        try await newStore.bindAccount(current)
        await activate(user: current, savedState: nil)
        log("Started a fresh database for the current account")
    }

    /// The account the device is signed in to, if it differs from the database's.
    public var mismatchedCurrentAccount: String? {
        if case .mismatch(_, let current) = accountState { return current }
        return nil
    }

    // MARK: Manual sync and status hooks

    /// Diagnostics "Sync Now". If an earlier fetched change couldn't be applied, it first
    /// recreates the engine from the last persisted state, so that change is
    /// redelivered.
    public func syncNow() async {
        guard case .active(let user) = accountState else {
            await revalidateAccount()
            return
        }
        if !canPersistEngineState {
            log("Recreating the sync engine from the last saved state to re-fetch unapplied changes")
            tearDownEngine()
            await activate(user: user, savedState: (try? await store.engineState()) ?? nil)
        }
        guard let engine else { return }
        do {
            try await engine.fetchChanges()
            try await engine.sendChanges()
        } catch {
            await reportProblem("Sync didn’t complete: \(error.localizedDescription)")
        }
    }

    /// The engine is about to fetch or send. Events are delivered serially, so this
    /// check completes before the operation's results are delivered.
    func operationWillStart(isFetch: Bool, from source: ObjectIdentifier) async {
        guard isCurrent(source) else { return }
        await revalidateAccount()
        guard isCurrent(source) else { return }
        if isFetch {
            fetchHadError = false
            await status?.fetchStarted()
        } else {
            await status?.sendStarted()
        }
    }

    func fetchZoneFailed(from source: ObjectIdentifier) {
        guard isCurrent(source) else { return }
        fetchHadError = true
    }

    /// A fetch counts as successful only if no zone fetch inside it reported an error.
    func fetchFinished(from source: ObjectIdentifier) async {
        await status?.fetchFinished(succeeded: isCurrent(source) && !fetchHadError, at: now())
    }

    func sendFinished(from source: ObjectIdentifier) async {
        await status?.sendFinished()
        await publishPendingCount()
    }

    func reportProblem(_ message: String) async {
        Log.sync.error("\(message, privacy: .public)")
        await status?.recordProblem(message, at: now())
    }

    func log(_ message: String) {
        Log.sync.info("\(message, privacy: .public)")
        let date = now()
        if let status {
            Task { await status.log(message, at: date) }
        }
    }

    /// Observes `CKAccountChanged` (posted by CloudKit on an arbitrary queue).
    func setAccountObserver(_ observer: any NSObjectProtocol) {
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
        accountObserver = observer
    }

    // MARK: Account resolution

    /// Determines the account and acts on it. The rules:
    ///
    /// | Account | Database owner | Result |
    /// |---|---|---|
    /// | available(U) | none | bind to U (adopt local notes), fresh engine |
    /// | available(U) | U | engine from U's persisted state |
    /// | available(U) | V ≠ U | mismatch, no engine |
    /// | no account / restricted | any | noAccount, no engine |
    /// | temporarily unavailable | any | wait for `CKAccountChanged` (per Apple) |
    /// | couldn't determine | any | wait, retry with backoff |
    private func resolveAccount() async {
        guard makeEngine != nil else { return }  // Not started yet; `start` resolves.
        resolutionID += 1
        let id = resolutionID
        let account = await accounts.currentAccount()
        let bound: String?
        let savedState: Data?
        do throws(StoreError) {
            bound = try await store.boundAccount()
            savedState = try await store.engineState()
        } catch {
            await reportProblem("Couldn’t read sync state: \(error.localizedDescription)")
            return
        }
        guard id == resolutionID else { return }  // Superseded while suspended.

        switch account {
        case .available(let user):
            accountRetryAttempt = 0
            if bound == nil {
                // First account seen by this database: notes created so far belong to
                // this user. Any engine state without an owner can't be trusted.
                await perform("bind account") { store throws(StoreError) in
                    try await store.bindAccount(user)
                    if savedState != nil { try await store.clearEngineState() }
                }
                guard id == resolutionID else { return }
                log("Bound this database to the signed-in iCloud account")
                await activate(user: user, savedState: nil)
            } else if bound == user {
                await activate(user: user, savedState: savedState)
            } else if let bound {
                tearDownEngine()
                accountState = .mismatch(bound: bound, current: user)
                log("Signed-in account doesn’t own this database; sync paused")
            }
        case .noAccount, .restricted:
            tearDownEngine()
            accountState = .noAccount
        case .temporarilyUnavailable:
            tearDownEngine()
            accountState = .waitingForAccount  // Resumed by CKAccountChanged.
        case .couldNotDetermine(let reason):
            tearDownEngine()
            accountState = .waitingForAccount
            log("Couldn’t determine iCloud account (\(reason)); will retry")
            scheduleAccountRetry()
        }
        await publishAvailability()
    }

    private func activate(user: String, savedState: Data?) async {
        guard let makeEngine else { return }
        tearDownEngine()  // Never two engines at once.
        accountState = .active(user: user)
        canPersistEngineState = true
        inFlight.removeAll()
        pendingAccountRetry?.cancel()
        engine = makeEngine(self, savedState)
        log("Sync engine started (\(savedState == nil ? "fresh state" : "restored state"))")
        await publishAvailability()
        await queueAllPendingWork()
    }

    /// Stops the current engine. Its later events are ignored because they no longer
    /// match `engine`. The cancellation isn't awaited, because this may run inside one of
    /// that engine's own callbacks, which it would wait for.
    private func tearDownEngine() {
        guard let old = engine else { return }
        engine = nil
        inFlight.removeAll()
        teardowns.append(Task { await old.cancelOperations() })
    }

    /// Waits for every stopped engine's cancellation to finish. Used by tests. Nothing
    /// in the app depends on it, since stopped engines' events are ignored either way.
    func waitForEngineTeardowns() async {
        let pending = teardowns
        teardowns.removeAll()
        for task in pending { await task.value }
    }

    private func stopPersistingEngineState(reason: String) {
        guard canPersistEngineState else { return }
        canPersistEngineState = false
        log("Pausing sync-state saves: \(reason). The change will be fetched again after relaunch or Sync Now.")
    }

    /// Bounded exponential backoff (15 s doubling, up to 5 min) for an account that
    /// couldn't be determined. This isn't a retry around CKSyncEngine: no engine exists
    /// in this state.
    private func scheduleAccountRetry() {
        pendingAccountRetry?.cancel()
        let delay = min(Duration.seconds(15) * (1 << min(accountRetryAttempt, 5)), .seconds(300))
        accountRetryAttempt += 1
        pendingAccountRetry = Task { [weak self, sleep] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            await self?.retryAccountResolution()
        }
    }

    private func retryAccountResolution() async {
        guard accountState == .waitingForAccount else { return }
        await resolveAccount()
    }

    private func isCurrent(_ source: ObjectIdentifier) -> Bool {
        engine?.eventSourceID == source
    }

    // MARK: Private helpers

    /// Subscribes *before* returning, so no change committed after this call is missed.
    /// (Subscribing inside the Task would leave a window before the Task first runs.)
    private func observeLocalChanges() async {
        localChangesTask?.cancel()
        guard observesLocalChanges else { return }
        let changes = await store.changes()
        localChangesTask = Task { [weak self] in
            for await change in changes where change.origin == .local {
                await self?.localNotesChanged(change.noteIDs)
            }
        }
    }

    /// Returns the affected ids, or nil if the store failed to apply the change.
    private func applyRemote(_ change: RemoteChange) async -> Set<UUID>? {
        do throws(StoreError) {
            let result = try await store.applyRemote(change)
            if let copy = result.conflictCopyID {
                log("Conflict: kept both versions (copy \(copy.uuidString.prefix(8)))")
            }
            switch result.resolution {
            case .ignore: return []
            default:
                let id: UUID = switch change {
                case .modified(let note): note.id
                case .recordGone(let id): id
                }
                return Set([id] + (result.conflictCopyID.map { [$0] } ?? []))
            }
        } catch {
            await reportProblem("Couldn’t save a change from iCloud: \(error.localizedDescription)")
            return nil
        }
    }

    /// Makes the engine's pending list match the database for `ids`: unsynced rows are
    /// added, and rows with nothing left to upload are removed.
    private func reconcilePending(_ ids: Set<UUID>) async {
        guard !ids.isEmpty, let engine else {
            await publishPendingCount()
            return
        }
        do throws(StoreError) {
            let pending = Set(try await store.pendingChanges().map(\.noteID))
            engine.addPendingSaves(Array(ids.intersection(pending)))
            engine.removePendingSaves(Array(ids.subtracting(pending)))
        } catch {
            Log.sync.error("Couldn’t reconcile pending changes: \(String(describing: error), privacy: .public)")
        }
        await publishPendingCount()
    }

    /// Re-queues every unsynced row. The database, not the engine's state, is the record
    /// of pending work. The engine deduplicates, so repeating this is harmless.
    private func queueAllPendingWork() async {
        guard case .active = accountState, let engine else {
            await publishPendingCount()
            return
        }
        do throws(StoreError) {
            let ids = try await store.pendingChanges().map(\.noteID)
            engine.addPendingZoneSave()
            engine.addPendingSaves(ids)
            if !ids.isEmpty { log("Queued \(ids.count) pending changes from the database") }
        } catch {
            await reportProblem("Couldn’t read pending changes: \(error.localizedDescription)")
        }
        await publishPendingCount()
    }

    private func publishPendingCount() async {
        guard let status else { return }
        // Display only: a failed count read shows 0 rather than an error.
        let count = (try? await store.pendingChanges().count) ?? 0
        await status.setPendingUploadCount(count)
    }

    private func publishAvailability() async {
        let availability: SyncStatusModel.Availability = switch accountState {
        case .unknown: .starting
        case .active: .available
        case .noAccount: .noAccount
        case .waitingForAccount: .waitingForAccount
        case .mismatch: .accountMismatch
        }
        await status?.setAvailability(availability)
    }

    /// Runs a store operation, reporting rather than swallowing a failure.
    private func perform<T>(_ what: String, _ body: (NoteStore) async throws(StoreError) -> T) async {
        do throws(StoreError) {
            _ = try await body(store)
        } catch {
            await reportProblem("Couldn’t \(what): \(error.localizedDescription)")
        }
    }
}
