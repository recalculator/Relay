import CloudKit
import Foundation
import os

// The only file that touches CloudKit. It translates between CKSyncEngine and the
// CloudKit-free `SyncCoordinator`.
//
// Approach informed by Apple's "CKSyncEngine" sample
// (github.com/apple/sample-cloudkit-sync-engine, MIT License, © 2023 Apple Inc.): which
// events to handle and the zoneNotFound/unknownItem recovery. No sample code is copied.
// Relay's storage, conflict policy, tombstone deletes, and account handling differ from
// the sample.

/// Mapping between `Note` rows and `CKRecord`s.
public enum NoteRecord {
    public static let recordType: CKRecord.RecordType = "Note"
    public static let zoneName = "Notes"
    public static let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)

    enum Field {
        static let title = "title"
        static let body = "body"
        static let createdAt = "createdAt"
        static let modifiedAt = "modifiedAt"
        static let conflictOf = "conflictOf"
        static let isDeleted = "isDeleted"
        /// `EntryKind` raw value. Absent on records from builds before entry kinds.
        static let kind = "kind"
    }

    /// The record name is the note's UUID. A retried upload therefore always targets the
    /// same record and can never create a duplicate logical note.
    public static func recordID(for id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    }

    public static func noteID(from recordID: CKRecord.ID) -> UUID? {
        guard recordID.zoneID == zoneID else { return nil }
        return UUID(uuidString: recordID.recordName)
    }

    /// Builds the record to upload. Starting from the last-known server record's system
    /// fields carries its change tag, so CloudKit rejects the save with
    /// `serverRecordChanged` if someone else wrote the record in the meantime.
    public static func makeRecord(from snapshot: UploadSnapshot) -> CKRecord {
        let recordID = recordID(for: snapshot.id)
        var record = CKRecord(recordType: recordType, recordID: recordID)
        if let fields = snapshot.baseSystemFields {
            if let base = decodeSystemFields(fields), base.recordID == recordID {
                record = base
            } else {
                Log.sync.error("Ignoring undecodable system fields for note \(snapshot.id, privacy: .public)")
            }
        }
        record[Field.title] = snapshot.title
        record[Field.body] = snapshot.body
        record[Field.createdAt] = snapshot.createdAt
        record[Field.modifiedAt] = snapshot.modifiedAt
        record[Field.conflictOf] = snapshot.conflictOf?.uuidString
        record[Field.isDeleted] = snapshot.isDeleted ? 1 : 0
        record[Field.kind] = snapshot.kind.rawValue
        return record
    }

    /// Validates and converts a server record. Returns nil (and logs) for records that
    /// aren't valid notes, rather than crashing or storing garbage.
    public static func remoteNote(from record: CKRecord) -> RemoteNote? {
        guard record.recordType == recordType, let id = noteID(from: record.recordID) else {
            Log.sync.error("Ignoring record of unexpected type or id")
            return nil
        }
        let isDeleted = (record[Field.isDeleted] as? Int64 ?? 0) != 0
        guard
            let createdAt = record[Field.createdAt] as? Date,
            let modifiedAt = record[Field.modifiedAt] as? Date
        else {
            Log.sync.error("Ignoring note record \(id, privacy: .public) with missing dates")
            return nil
        }
        return RemoteNote(
            id: id,
            title: record[Field.title] as? String ?? "",
            body: record[Field.body] as? String ?? "",
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            conflictOf: (record[Field.conflictOf] as? String).flatMap(UUID.init(uuidString:)),
            kind: EntryKind(storedValue: record[Field.kind] as? String),
            isDeleted: isDeleted,
            changeTag: record.recordChangeTag,
            systemFields: encodeSystemFields(of: record)
        )
    }

    /// Encodes only the record's metadata (id, change tag, …), not its field values.
    public static func encodeSystemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    public static func decodeSystemFields(_ data: Data) -> CKRecord? {
        do {
            let coder = try NSKeyedUnarchiver(forReadingFrom: data)
            coder.requiresSecureCoding = true
            defer { coder.finishDecoding() }
            return CKRecord(coder: coder)
        } catch {
            Log.sync.error("System fields decode failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Sorts a per-record save error into one of the categories the coordinator handles.
    ///
    /// The transient set matches the errors Apple documents CKSyncEngine as retrying
    /// automatically, plus `operationCancelled`, where the change is kept and resent.
    public static func classify(_ error: CKError) -> SendFailure {
        switch error.code {
        case .serverRecordChanged:
            guard let serverRecord = error.serverRecord, let server = remoteNote(from: serverRecord) else {
                return .invalid(code: error.errorCode)
            }
            return .conflict(server: server)
        case .unknownItem:
            return .recordMissing
        case .zoneNotFound, .userDeletedZone:
            return .zoneMissing
        case .networkFailure, .networkUnavailable, .requestRateLimited, .serviceUnavailable,
             .zoneBusy, .notAuthenticated, .accountTemporarilyUnavailable, .operationCancelled:
            return .transient(code: error.errorCode)
        case .quotaExceeded:
            return .quotaExceeded
        default:
            return .invalid(code: error.errorCode)
        }
    }
}

/// Wraps a real `CKSyncEngine` behind `SyncEngineControl`.
final class CloudKitEngineControl: SyncEngineControl {
    let engine: CKSyncEngine

    init(database: CKDatabase, stateSerialization: CKSyncEngine.State.Serialization?, delegate: SyncCoordinator) {
        let configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: stateSerialization,
            delegate: delegate
        )
        engine = CKSyncEngine(configuration)
    }

    /// Delegate callbacks receive the `CKSyncEngine` itself, so events are matched by
    /// its identity.
    var eventSourceID: ObjectIdentifier { ObjectIdentifier(engine) }

    func addPendingSaves(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: ids.map { .saveRecord(NoteRecord.recordID(for: $0)) })
    }

    func removePendingSaves(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        engine.state.remove(pendingRecordZoneChanges: ids.map { .saveRecord(NoteRecord.recordID(for: $0)) })
    }

    func addPendingZoneSave() {
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: NoteRecord.zoneID))])
    }

    func fetchChanges() async throws { try await engine.fetchChanges() }
    func sendChanges() async throws { try await engine.sendChanges() }
    func cancelOperations() async { await engine.cancelOperations() }
}

/// Reads the account from `CKContainer`, as Apple recommends before using the private
/// database: `accountStatus()` first, then the user record id for identity.
///
/// The record name is cached, because each check may otherwise be a network request.
/// The cache is dropped on `invalidate()`, which runs on every `CKAccountChanged` and
/// engine-reported account change. `accountStatus()` itself is checked every time.
final class CloudKitAccountProvider: AccountProvider {
    private let container: CKContainer
    private let cachedUser = OSAllocatedUnfairLock<String?>(initialState: nil)

    init(container: CKContainer) {
        self.container = container
    }

    func currentAccount() async -> ICloudAccount {
        let status: CKAccountStatus
        do {
            status = try await container.accountStatus()
        } catch {
            return .couldNotDetermine(reason: "accountStatus: \(error.localizedDescription)")
        }
        switch status {
        case .available:
            if let cached = cachedUser.withLock({ $0 }) { return .available(user: cached) }
            do {
                let user = try await container.userRecordID().recordName
                cachedUser.withLock { $0 = user }
                return .available(user: user)
            } catch {
                return .couldNotDetermine(reason: "userRecordID: \(error.localizedDescription)")
            }
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        case .temporarilyUnavailable: return .temporarilyUnavailable
        case .couldNotDetermine: return .couldNotDetermine(reason: "status could not be determined")
        @unknown default: return .couldNotDetermine(reason: "unknown status \(status.rawValue)")
        }
    }

    func invalidate() {
        cachedUser.withLock { $0 = nil }
    }
}

extension SyncCoordinator {
    /// Creates a coordinator for real iCloud sync against the private database of
    /// `containerIdentifier`, and starts observing `CKAccountChanged`. Call
    /// `startCloudKit(containerIdentifier:)` next.
    ///
    /// Requires the iCloud (CloudKit) entitlement. Without it, creating the container
    /// crashes, so the app calls this only in builds compiled with `RELAY_CLOUDKIT`.
    public static func cloudKit(store: NoteStore, status: SyncStatusModel?, containerIdentifier: String) async -> SyncCoordinator {
        let container = CKContainer(identifier: containerIdentifier)
        let coordinator = SyncCoordinator(
            store: store, status: status, accountProvider: CloudKitAccountProvider(container: container)
        )
        // CloudKit posts this on an arbitrary queue. The closure only hops to the actor.
        let observer = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: nil
        ) { [weak coordinator] _ in
            Task { await coordinator?.accountMayHaveChanged() }
        }
        await coordinator.setAccountObserver(observer)
        return coordinator
    }

    /// Establishes the account (which may need the network), then creates the engine.
    public func startCloudKit(containerIdentifier: String) async {
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        await start { coordinator, savedState in
            var serialization: CKSyncEngine.State.Serialization?
            if let savedState {
                do {
                    serialization = try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: savedState)
                } catch {
                    // Starting without state is safe: the engine refetches, and applying
                    // already-known server versions is a no-op (matching change tags).
                    Log.sync.fault("Discarding undecodable engine state: \(error.localizedDescription, privacy: .public)")
                }
            }
            return CloudKitEngineControl(database: database, stateSerialization: serialization, delegate: coordinator)
        }
    }
}

extension SyncCoordinator: CKSyncEngineDelegate {
    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        let source = ObjectIdentifier(syncEngine)
        switch event {
        case .stateUpdate(let update):
            do {
                await handleEngineStateUpdate(try JSONEncoder().encode(update.stateSerialization), from: source)
            } catch {
                await reportProblem("Couldn’t encode sync state: \(error.localizedDescription)")
            }

        case .accountChange(let change):
            switch change.changeType {
            case .signIn(let user):
                await handleAccountChange(.signIn(user: user.recordName), from: source)
            case .signOut(let previous):
                await handleAccountChange(.signOut(previousUser: previous.recordName), from: source)
            case .switchAccounts(let previous, let current):
                await handleAccountChange(
                    .switchAccounts(previousUser: previous.recordName, currentUser: current.recordName), from: source)
            @unknown default:
                // Treat an unrecognized transition as "account may have changed".
                await accountMayHaveChanged()
            }

        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions where deletion.zoneID == NoteRecord.zoneID {
                let reason: ZoneDeletionReason = switch deletion.reason {
                case .encryptedDataReset: .encryptedDataReset
                default: .deletedOrPurged
                }
                await handleZoneDeleted(reason, from: source)
            }

        case .fetchedRecordZoneChanges(let changes):
            var remote: [RemoteChange] = changes.modifications.compactMap { modification in
                NoteRecord.remoteNote(from: modification.record).map(RemoteChange.modified)
            }
            remote += changes.deletions.compactMap { deletion in
                guard deletion.recordType == NoteRecord.recordType else { return nil }
                return NoteRecord.noteID(from: deletion.recordID).map(RemoteChange.recordGone)
            }
            await handleFetchedChanges(remote, from: source)

        case .sentRecordZoneChanges(let sent):
            var results: [SendResult] = sent.savedRecords.compactMap { record in
                NoteRecord.remoteNote(from: record).map(SendResult.saved)
            }
            for failure in sent.failedRecordSaves {
                guard let id = NoteRecord.noteID(from: failure.record.recordID) else { continue }
                results.append(.failed(id: id, NoteRecord.classify(failure.error)))
            }
            if !sent.failedRecordDeletes.isEmpty {
                // Relay deletes by uploading tombstones and never queues record deletions.
                Log.sync.fault("Unexpected failed record deletions: \(sent.failedRecordDeletes.count)")
            }
            await handleSendResults(results, from: source)

        case .sentDatabaseChanges(let sent):
            for failure in sent.failedZoneSaves {
                switch NoteRecord.classify(failure.error) {
                case .transient: Log.sync.info("Zone save will be retried by the engine")
                default: await reportProblem("Couldn’t create the iCloud zone (CloudKit error \(failure.error.errorCode)).")
                }
            }

        case .willFetchChanges:
            await operationWillStart(isFetch: true, from: source)
        case .didFetchRecordZoneChanges(let fetched):
            if let error = fetched.error {
                fetchZoneFailed(from: source)
                switch NoteRecord.classify(error) {
                case .transient: Log.sync.info("Zone fetch interrupted (CKError \(error.errorCode)); engine will retry")
                default: await reportProblem("Fetching changes failed (CloudKit error \(error.errorCode)).")
                }
            }
        case .didFetchChanges:
            await fetchFinished(from: source)
        case .willSendChanges:
            await operationWillStart(isFetch: false, from: source)
        case .didSendChanges:
            await sendFinished(from: source)
        case .willFetchRecordZoneChanges:
            break
        @unknown default:
            log("Unhandled sync engine event")
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let source = ObjectIdentifier(syncEngine)
        guard canUpload(from: source) else { return nil }
        // Only changes within the requested scope may be returned, or the send fails
        // with invalidArguments.
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        // The record provider is `@Sendable` and async. It hops back onto this actor for
        // each record, which also records the in-flight version.
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [self] recordID in
            guard let id = NoteRecord.noteID(from: recordID),
                  let snapshot = await snapshotForUpload(id, from: source)
            else { return nil }
            return NoteRecord.makeRecord(from: snapshot)
        }
    }
}
