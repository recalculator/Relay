import Foundation
import os
@testable import RelayCore

// SIMULATED SYNC. Nothing in this file talks to iCloud.
//
// These doubles stand in for CKSyncEngine, the CloudKit server, and the iCloud account,
// so that sync logic can be tested deterministically. Passing tests built on them show
// that Relay's logic handles the simulated situations. They are NOT evidence that real
// iCloud sync works. See TESTING.md for the manual CloudKit procedure.

/// Stand-in for one CKSyncEngine instance.
///
/// It models the parts of the engine's documented lifecycle that Relay depends on:
/// * It's created from a persisted state serialization. Here, that's the fetch
///   position (change token) in `FakeCloud`'s change log.
/// * It delivers fetched changes, *then* a state update reflecting them.
/// * Its pending list deduplicates, and changes leave it when taken for sending.
final class FakeSyncEngine: SyncEngineControl {
    private struct State {
        var pending: [UUID] = []  // Ordered, unique.
        var zoneSaves = 0
        var addCalls: [[UUID]] = []  // Every addPendingSaves call made by the coordinator.
        var fetchToken = 0
        var cancelled = false
    }

    private let state: OSAllocatedUnfairLock<State>
    /// Yields every `addPendingSaves` call, so tests can await the change-stream path
    /// without sleeping.
    let adds: AsyncStream<[UUID]>
    private let addsContinuation: AsyncStream<[UUID]>.Continuation

    init(restoring serialized: Data? = nil) {
        let token = serialized.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        state = OSAllocatedUnfairLock(initialState: State(fetchToken: token))
        (adds, addsContinuation) = AsyncStream.makeStream(of: [UUID].self)
    }

    var eventSourceID: ObjectIdentifier { ObjectIdentifier(self) }
    var pending: [UUID] { state.withLock { $0.pending } }
    var zoneSaveCount: Int { state.withLock { $0.zoneSaves } }
    var fetchToken: Int { state.withLock { $0.fetchToken } }
    var wasCancelled: Bool { state.withLock { $0.cancelled } }

    /// Ids the coordinator has asked to (re)queue, across all calls.
    var coordinatorAddedIDs: [UUID] { state.withLock { $0.addCalls.flatMap { $0 } } }

    func addPendingSaves(_ ids: [UUID]) {
        state.withLock { state in
            state.addCalls.append(ids)
            for id in ids where !state.pending.contains(id) { state.pending.append(id) }
        }
        addsContinuation.yield(ids)
    }

    func removePendingSaves(_ ids: [UUID]) {
        state.withLock { $0.pending.removeAll { ids.contains($0) } }
    }

    func addPendingZoneSave() {
        state.withLock { $0.zoneSaves += 1 }
    }

    /// Simulates CKSyncEngine keeping a change after a recoverable failure. This is the
    /// engine's own behavior, so it isn't recorded as a coordinator call.
    func retainAfterTransientFailure(_ id: UUID) {
        state.withLock { state in
            if !state.pending.contains(id) { state.pending.append(id) }
        }
    }

    /// Removes and returns everything pending, as the engine does when it builds a batch.
    func takePending() -> [UUID] {
        state.withLock { state in
            defer { state.pending.removeAll() }
            return state.pending
        }
    }

    func advanceFetchToken(to token: Int) {
        state.withLock { $0.fetchToken = token }
    }

    /// What the engine would hand the delegate in a `stateUpdate` event.
    var serializedState: Data { Data(String(fetchToken).utf8) }

    func fetchChanges() async throws {}
    func sendChanges() async throws {}
    func cancelOperations() async {
        state.withLock { $0.cancelled = true }
    }
}

/// The iCloud account as tests want it to appear.
final class FakeAccountProvider: AccountProvider {
    private let state: OSAllocatedUnfairLock<(account: ICloudAccount, queries: Int, invalidations: Int)>

    init(_ account: ICloudAccount) {
        state = OSAllocatedUnfairLock(initialState: (account, 0, 0))
    }

    var account: ICloudAccount {
        get { state.withLock { $0.account } }
        set { state.withLock { $0.account = newValue } }
    }

    var queryCount: Int { state.withLock { $0.queries } }

    /// When set, each query suspends on the gate until the test releases it. This lets
    /// a test hold several account resolutions in flight at once.
    let gate = OSAllocatedUnfairLock<ManualSleeper?>(initialState: nil)

    func currentAccount() async -> ICloudAccount {
        state.withLock { $0.queries += 1 }
        if let gate = gate.withLock({ $0 }) {
            try? await gate.sleep(.zero)
        }
        return state.withLock { $0.account }
    }

    func invalidate() {
        state.withLock { $0.invalidations += 1 }
    }
}

/// A `sleep` replacement for account retries that suspends until the test calls
/// `release()`. Retry timing is therefore controlled by the test, not a clock.
/// `requests` yields each requested delay as a sleep begins, so tests can await it.
final class ManualSleeper: Sendable {
    private struct State {
        var waiters: [CheckedContinuation<Void, Never>] = []
        var credits = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    let requests: AsyncStream<Duration>
    private let requestsContinuation: AsyncStream<Duration>.Continuation

    init() {
        (requests, requestsContinuation) = AsyncStream.makeStream(of: Duration.self)
    }

    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] delay in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state -> Bool in
                    if state.credits > 0 {
                        state.credits -= 1
                        return true
                    }
                    state.waiters.append(continuation)
                    return false
                }
                requestsContinuation.yield(delay)
                if resumeNow { continuation.resume() }
            }
            try Task.checkCancellation()
        }
    }

    /// Ends the oldest pending sleep, or the next one if none is pending yet.
    func release() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            if state.waiters.isEmpty {
                state.credits += 1
                return nil
            }
            return state.waiters.removeFirst()
        }
        waiter?.resume()
    }
}

/// In-memory stand-in for the CloudKit server's zone.
///
/// It enforces the same rule CloudKit applies to saves (`.ifServerRecordUnchanged`): a
/// save must be based on the server's current change tag, or it fails with a conflict
/// carrying the server's version. "System fields" are simply the tag's UTF-8 bytes.
actor FakeCloud {
    private var records: [UUID: RemoteNote] = [:]
    private var changeLog: [(sequence: Int, change: RemoteChange)] = []
    private var sequence = 0
    private var tagCounter = 0
    private var injectedFailures: [SendFailure] = []

    /// The next `count` saves fail with `failure` (for example a transient network error).
    func failNextSaves(with failure: SendFailure, count: Int = 1) {
        injectedFailures += Array(repeating: failure, count: count)
    }

    func save(_ snapshot: UploadSnapshot) -> SendResult {
        if !injectedFailures.isEmpty {
            return .failed(id: snapshot.id, injectedFailures.removeFirst())
        }
        let baseTag = snapshot.baseSystemFields.map { String(decoding: $0, as: UTF8.self) }
        let existing = records[snapshot.id]
        switch (baseTag, existing) {
        case (.some, nil):
            return .failed(id: snapshot.id, .recordMissing)
        case (let base?, let current?) where current.changeTag != base:
            return .failed(id: snapshot.id, .conflict(server: current))
        case (nil, let current?):
            return .failed(id: snapshot.id, .conflict(server: current))
        default:
            break
        }
        tagCounter += 1
        let tag = "tag-\(tagCounter)"
        let saved = RemoteNote(
            id: snapshot.id,
            title: snapshot.title,
            body: snapshot.body,
            createdAt: snapshot.createdAt,
            modifiedAt: snapshot.modifiedAt,
            conflictOf: snapshot.conflictOf,
            isDeleted: snapshot.isDeleted,
            changeTag: tag,
            systemFields: Data(tag.utf8)
        )
        records[snapshot.id] = saved
        appendChange(.modified(saved))
        return .saved(saved)
    }

    /// Removes a record outright, as other tools or a zone reset might.
    func hardDelete(_ id: UUID) {
        records[id] = nil
        appendChange(.recordGone(id))
    }

    /// Changes after `token`, collapsed to the latest change per record (as CloudKit
    /// delivers them), plus the new token.
    func changes(since token: Int) -> (changes: [RemoteChange], token: Int) {
        var latest: [UUID: RemoteChange] = [:]
        var order: [UUID] = []
        for entry in changeLog where entry.sequence > token {
            let id: UUID = switch entry.change {
            case .modified(let note): note.id
            case .recordGone(let id): id
            }
            if latest[id] == nil { order.append(id) }
            latest[id] = entry.change
        }
        return (order.compactMap { latest[$0] }, sequence)
    }

    func record(_ id: UUID) -> RemoteNote? { records[id] }
    var liveRecords: [RemoteNote] { records.values.filter { !$0.isDeleted } }
    var recordCount: Int { records.count }

    private func appendChange(_ change: RemoteChange) {
        sequence += 1
        changeLog.append((sequence, change))
    }
}

/// One device: a real SQLite store, a real `SyncCoordinator`, a fake account, and fake
/// engines (a new one each time the coordinator creates one), talking to a shared
/// `FakeCloud`. Each `FakeCloud` instance stands for one iCloud account's private
/// database.
final class SimulatedDevice {
    let name: String
    let directory: TemporaryDirectory
    let accounts: FakeAccountProvider
    let sleeper = ManualSleeper()
    private(set) var store: NoteStore
    private(set) var coordinator: SyncCoordinator
    private let createdEngines = OSAllocatedUnfairLock<[(engine: FakeSyncEngine, restoredState: Data?)]>(initialState: [])
    /// The server the device talks to. Tests switching accounts point this elsewhere.
    var cloud: FakeCloud

    init(_ name: String, cloud: FakeCloud, account: ICloudAccount = .available(user: "user-A")) async throws {
        self.name = name
        self.cloud = cloud
        directory = try TemporaryDirectory()
        accounts = FakeAccountProvider(account)
        store = try NoteStore(url: directory.storeURL, now: steppingClock())
        coordinator = SyncCoordinator(store: store, status: nil, accountProvider: accounts, sleep: sleeper.sleep)
    }

    /// The most recently created engine (the coordinator's current one, if it's active).
    var engine: FakeSyncEngine {
        get throws {
            guard let engine = createdEngines.withLock({ $0.last?.engine }) else { throw NoEngine() }
            return engine
        }
    }

    struct NoEngine: Error {}

    var engineCount: Int { createdEngines.withLock { $0.count } }
    func restoredState(ofEngine index: Int) -> Data? { createdEngines.withLock { $0[index].restoredState } }

    /// Starts sync as the app does at launch.
    ///
    /// - Parameter observeLocalChanges: Off by default. The store's change stream would
    ///   then announce edits to the engine at a nondeterministic time. Instead, `beginSend`
    ///   announces them explicitly, which is what the stream eventually does.
    func start(observeLocalChanges: Bool = false) async {
        let created = createdEngines
        await coordinator.start(
            makeEngine: { _, state in
                let engine = FakeSyncEngine(restoring: state)
                created.withLock { $0.append((engine, state)) }
                return engine
            },
            observeLocalChanges: observeLocalChanges
        )
    }

    /// Simulates quitting and relaunching: same database file, new store, coordinator,
    /// and engine.
    func relaunch() async throws {
        await store.close()
        store = try NoteStore(url: directory.storeURL, now: steppingClock())
        coordinator = SyncCoordinator(store: store, status: nil, accountProvider: accounts, sleep: sleeper.sleep)
        await start()
    }

    /// The device signs in to `user`, and the current engine reports it, as CKSyncEngine
    /// does after an account change.
    func switchAccount(to user: String) async throws {
        let previous: String = if case .active(let current) = await coordinator.accountState { current } else { "?" }
        accounts.account = .available(user: user)
        await coordinator.handleAccountChange(
            .switchAccounts(previousUser: previous, currentUser: user), from: try engine.eventSourceID)
    }

    /// Takes the engine's pending list and snapshots each record, as the engine does when
    /// it builds a batch. The uploads are now "in flight" until `finishSend`.
    func beginSend() async throws -> (engine: FakeSyncEngine, snapshots: [UploadSnapshot]) {
        await announceLocalChanges()
        let engine = try engine
        var snapshots: [UploadSnapshot] = []
        for id in engine.takePending() {
            if let snapshot = await coordinator.snapshotForUpload(id, from: engine.eventSourceID) {
                snapshots.append(snapshot)
            }
        }
        return (engine, snapshots)
    }

    /// Delivers the server's responses for an earlier `beginSend`, from the engine that
    /// sent them (which may since have been replaced).
    func finishSend(_ batch: (engine: FakeSyncEngine, snapshots: [UploadSnapshot])) async {
        var results: [SendResult] = []
        for snapshot in batch.snapshots {
            let result = await cloud.save(snapshot)
            if case .failed(let id, .transient) = result {
                batch.engine.retainAfterTransientFailure(id)  // The real engine retains these.
            }
            results.append(result)
        }
        await coordinator.handleSendResults(results, from: batch.engine.eventSourceID)
    }

    func send() async throws {
        await finishSend(try await beginSend())
    }

    /// One fetch by `engine` (default: the current one): fetched changes, then the
    /// state update, in that order, as CKSyncEngine delivers them.
    func fetch(using engine: FakeSyncEngine? = nil) async throws {
        let engine = try engine ?? self.engine
        let (changes, token) = await cloud.changes(since: engine.fetchToken)
        await coordinator.handleFetchedChanges(changes, from: engine.eventSourceID)
        engine.advanceFetchToken(to: token)
        await coordinator.handleEngineStateUpdate(engine.serializedState, from: engine.eventSourceID)
    }

    /// Fetch, then send until nothing is pending (bounded, to catch ping-pong bugs).
    func sync() async throws {
        try await fetch()
        for _ in 0..<5 {
            try await send()
            await announceLocalChanges()
            if try engine.pending.isEmpty { break }
        }
    }

    var liveNotes: [Note] {
        get async throws { try await store.allNotes() }
    }

    /// The token stored in the database's persisted engine state.
    var persistedFetchToken: Int? {
        get async throws {
            try await store.engineState().flatMap { Int(String(decoding: $0, as: UTF8.self)) }
        }
    }

    /// The store's change stream notifies the coordinator asynchronously. Tests call this
    /// so the outcome doesn't depend on that task's timing. The engine deduplicates, so a
    /// repeat announcement is harmless.
    func announceLocalChanges() async {
        let ids = (try? await store.pendingChanges().map(\.noteID)) ?? []
        await coordinator.localNotesChanged(Set(ids))
    }
}

/// Sorted (title, body) pairs, for comparing what two devices show.
func contents(_ notes: [Note]) -> [String] {
    notes.map { "\($0.title)|\($0.body)" }.sorted()
}
