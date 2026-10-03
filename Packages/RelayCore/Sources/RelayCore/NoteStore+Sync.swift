import Foundation

/// Store operations used by the sync layer. Every operation that changes several things
/// runs in one transaction, so a crash can't leave content and sync metadata
/// disagreeing.
///
/// None of these bump `local_version`. Only user edits do. That is what keeps changes
/// fetched from the server from being re-uploaded as if they were new local edits.
extension NoteStore {
    /// The full local row, including sync bookkeeping.
    struct SyncRow {
        var note: Note
        var isDeleted: Bool
        var localVersion: Int64
        var syncedVersion: Int64
        var changeTag: String?
        var systemFields: Data?

        var hasUnsyncedChanges: Bool { localVersion > syncedVersion }

        var resolverState: ConflictResolver.LocalState {
            .init(
                title: note.title,
                body: note.body,
                kind: note.kind,
                isDeleted: isDeleted,
                hasUnsyncedChanges: hasUnsyncedChanges,
                baseChangeTag: changeTag
            )
        }
    }

    /// Result of applying a server version.
    public struct ApplyResult: Sendable, Equatable {
        public let resolution: ConflictResolver.Resolution
        /// Set when a conflict copy was inserted.
        public let conflictCopyID: UUID?
    }

    // MARK: Sync sessions

    /// Starts a sync session owned by `owner` and returns its fence. Any earlier session
    /// ends. Called when the coordinator creates an engine.
    public nonisolated func beginSyncSession(owner: String) -> SyncFence {
        SyncFence(owner: owner, epoch: syncEpoch.withLock { epoch in
            epoch += 1
            return epoch
        })
    }

    /// Ends the current sync session, so writes fenced to it are rejected from now on.
    /// Called when the coordinator stops an engine. Synchronous, so it can run inside
    /// that engine's own callback.
    public nonisolated func endSyncSession() {
        syncEpoch.withLock { $0 += 1 }
    }

    /// Throws unless `fence` belongs to the current session and the database is still
    /// owned by the fence's account. Called first inside each fenced write transaction.
    ///
    /// The coordinator also checks its own state before writing, but a write is queued
    /// on this actor and can run after the coordinator has moved on. This check runs
    /// where the write happens. A write that started before the session ended finishes
    /// before any write of a later session can begin, because this actor runs one call
    /// at a time.
    private func checkFence(_ fence: SyncFence?) throws(StoreError) {
        guard let fence else { return }
        guard syncEpoch.withLock({ $0 }) == fence.epoch, try boundAccount() == fence.owner else {
            throw .staleSyncOperation
        }
    }

    // MARK: Uploads

    /// The data to upload for `id`, or nil if there's nothing to upload: the note is
    /// unknown, or it has no unsynced changes.
    public func uploadSnapshot(id: UUID) throws(StoreError) -> UploadSnapshot? {
        guard let row = try fetchSyncRow(id), row.hasUnsyncedChanges else { return nil }
        return UploadSnapshot(
            id: id,
            title: row.note.title,
            body: row.note.body,
            createdAt: row.note.createdAt,
            modifiedAt: row.note.modifiedAt,
            conflictOf: row.note.conflictOf,
            kind: row.note.kind,
            isDeleted: row.isDeleted,
            localVersion: row.localVersion,
            baseSystemFields: row.systemFields
        )
    }

    /// Records that the server accepted the upload of `sentVersion`.
    ///
    /// The row is marked synced only up to `sentVersion`. If the user edited the note
    /// while the upload was in flight, `local_version` is higher and the row stays
    /// pending, so the newer edit is uploaded next and never lost.
    ///
    /// - Returns: Whether the row still has unsynced changes.
    @discardableResult
    public func markUploaded(_ saved: RemoteNote, sentVersion: Int64, fence: SyncFence? = nil) throws(StoreError) -> Bool {
        try db.transaction { () throws(StoreError) -> Bool in
            try checkFence(fence)
            guard let row = try fetchSyncRow(saved.id) else { return false }
            let synced = min(max(row.syncedVersion, sentVersion), row.localVersion)

            if row.isDeleted != saved.isDeleted {
                // The server now holds a different live/deleted state than the row. Keep
                // the row pending so its current state is uploaded over it.
                Log.sync.fault("Uploaded state disagrees with local row for note \(saved.id, privacy: .public); re-queuing")
                try db.run(
                    """
                    UPDATE notes SET local_version = ?, synced_version = ?, server_change_tag = ?, server_system_fields = ?
                    WHERE id = ?
                    """,
                    [.integer(max(row.localVersion, synced + 1)), .integer(synced), tagValue(saved), fieldsValue(saved), .text(saved.id.uuidString)]
                )
                return true
            }

            if row.isDeleted, synced >= row.localVersion {
                // Deletion confirmed. The server keeps a content-free tombstone record,
                // so this device needs nothing more. Purge the local tombstone.
                try db.run("DELETE FROM notes WHERE id = ?", [.text(saved.id.uuidString)])
                return false
            }

            try db.run(
                "UPDATE notes SET synced_version = ?, server_change_tag = ?, server_system_fields = ? WHERE id = ?",
                [.integer(synced), tagValue(saved), fieldsValue(saved), .text(saved.id.uuidString)]
            )
            return row.localVersion > synced
        }
    }

    /// Forgets the server version a row is based on (zone recreated, record missing).
    /// The next upload creates the record afresh.
    public func clearServerMetadata(id: UUID, fence: SyncFence? = nil) throws(StoreError) {
        try db.transaction { () throws(StoreError) in
            try checkFence(fence)
            try clearServerMetadataRow(id)
        }
    }

    private func clearServerMetadataRow(_ id: UUID) throws(StoreError) {
        try db.run(
            "UPDATE notes SET server_change_tag = NULL, server_system_fields = NULL WHERE id = ?",
            [.text(id.uuidString)]
        )
    }

    // MARK: Remote changes

    /// Applies one server version using `ConflictResolver`, in a single transaction.
    ///
    /// Applying the same change twice is safe. The second time, the stored change tag
    /// matches, so it resolves to `.ignore`.
    @discardableResult
    public func applyRemote(_ change: RemoteChange, fence: SyncFence? = nil) throws(StoreError) -> ApplyResult {
        let id: UUID = switch change {
        case .modified(let note): note.id
        case .recordGone(let id): id
        }
        let result = try db.transaction { () throws(StoreError) -> ApplyResult in
            try checkFence(fence)
            let row = try fetchSyncRow(id)
            let resolution = ConflictResolver.resolve(local: row?.resolverState, remote: change)
            var copyID: UUID?

            switch (resolution, change) {
            case (.ignore, _):
                break
            case (.applyRemote, .modified(let server)):
                try writeServerVersion(server, over: row)
            case (.adoptRemoteMetadata, .modified(let server)):
                try db.run(
                    "UPDATE notes SET synced_version = local_version, server_change_tag = ?, server_system_fields = ? WHERE id = ?",
                    [tagValue(server), fieldsValue(server), .text(id.uuidString)]
                )
            case (.deleteLocal, _):
                try db.run("DELETE FROM notes WHERE id = ?", [.text(id.uuidString)])
            case (.keepLocal, .modified(let server)):
                // Re-base onto the server's current version (for example its tombstone)
                // so the pending upload overwrites it.
                try db.run(
                    "UPDATE notes SET server_change_tag = ?, server_system_fields = ? WHERE id = ?",
                    [tagValue(server), fieldsValue(server), .text(id.uuidString)]
                )
            case (.keepLocal, .recordGone):
                try clearServerMetadataRow(id)
            case (.applyRemoteAndCopyLocal, .modified(let server)):
                if let row {
                    copyID = try insertConflictCopy(of: id, content: row.note.content)
                }
                try writeServerVersion(server, over: row)
            case (.applyRemote, .recordGone), (.adoptRemoteMetadata, .recordGone), (.applyRemoteAndCopyLocal, .recordGone):
                // The resolver never produces these. Treat as a no-op rather than crash.
                Log.sync.fault("Unexpected resolution \(String(describing: resolution), privacy: .public) for missing record")
            }
            return ApplyResult(resolution: resolution, conflictCopyID: copyID)
        }

        if result.resolution != .ignore {
            notify(.sync, [id] + (result.conflictCopyID.map { [$0] } ?? []))
        }
        if let copyID = result.conflictCopyID {
            Log.sync.notice("Conflict on note \(id, privacy: .public): kept server version, saved local version as copy \(copyID, privacy: .public)")
        }
        return result
    }

    /// Handles the app's zone disappearing from the server.
    ///
    /// - `.deletedOrPurged`: synced notes are removed locally, matching the server.
    ///   Notes with unsynced edits are kept and queued to recreate the zone (edits win).
    /// - `.encryptedDataReset`: nothing on the server can be trusted any more, so every
    ///   live note is queued for re-upload.
    ///
    /// In both cases, local tombstones are dropped, because there is nothing left on the
    /// server to delete.
    ///
    /// - Returns: Ids of notes that now need uploading.
    public func handleZoneDeleted(_ reason: ZoneDeletionReason, fence: SyncFence? = nil) throws(StoreError) -> [UUID] {
        let pending = try db.transaction { () throws(StoreError) -> [UUID] in
            try checkFence(fence)
            try db.run("DELETE FROM notes WHERE is_deleted = 1")
            switch reason {
            case .deletedOrPurged:
                try db.run("DELETE FROM notes WHERE local_version <= synced_version")
            case .encryptedDataReset:
                try db.run("UPDATE notes SET local_version = synced_version + 1 WHERE local_version <= synced_version")
            }
            try db.run("UPDATE notes SET server_change_tag = NULL, server_system_fields = NULL")
            return try db.query("SELECT id FROM notes") { row throws(StoreError) in try Self.decodeID(row) }
        }
        Log.sync.notice("Applied zone deletion (\(String(describing: reason), privacy: .public)); \(pending.count) notes queued")
        notify(.sync, [], everything: true)
        return pending
    }

    // MARK: Sync state (engine state + account binding)

    enum SyncStateKey: String {
        case engineState = "ck_engine_state"
        case account = "ck_account"
    }

    /// The CloudKit user record name this database's synced data belongs to, if any.
    public func boundAccount() throws(StoreError) -> String? {
        try syncStateValue(.account).map { String(decoding: $0, as: UTF8.self) }
    }

    public func bindAccount(_ userRecordName: String) throws(StoreError) {
        try setSyncState(.account, Data(userRecordName.utf8))
    }

    /// Serialized `CKSyncEngine.State` (opaque bytes to the store).
    public func engineState() throws(StoreError) -> Data? {
        try syncStateValue(.engineState)
    }

    public func saveEngineState(_ data: Data, fence: SyncFence? = nil) throws(StoreError) {
        try db.transaction { () throws(StoreError) in
            try checkFence(fence)
            try setSyncState(.engineState, data)
        }
    }

    public func clearEngineState() throws(StoreError) {
        try db.run("DELETE FROM sync_state WHERE key = ?", [.text(SyncStateKey.engineState.rawValue)])
    }

    // MARK: Private

    private func syncStateValue(_ key: SyncStateKey) throws(StoreError) -> Data? {
        try db.query("SELECT value FROM sync_state WHERE key = ?", [.text(key.rawValue)]) { $0.data(0) }.first ?? nil
    }

    private func setSyncState(_ key: SyncStateKey, _ value: Data) throws(StoreError) {
        try db.run(
            "INSERT INTO sync_state (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(key.rawValue), .blob(value)]
        )
    }

    func fetchSyncRow(_ id: UUID) throws(StoreError) -> SyncRow? {
        try db.query(
            """
            SELECT \(Self.noteColumns), is_deleted, local_version, synced_version, server_change_tag, server_system_fields
            FROM notes WHERE id = ?
            """,
            [.text(id.uuidString)]
        ) { row throws(StoreError) in
            SyncRow(
                note: try Self.decodeNote(row),
                isDeleted: row.int64(7) != 0,
                localVersion: row.int64(8),
                syncedVersion: row.int64(9),
                changeTag: row.string(10),
                systemFields: row.data(11)
            )
        }.first
    }

    /// Writes the server's content and metadata, and marks the row synced without
    /// touching `local_version`. A new row starts at version 0/0: present, not pending.
    private func writeServerVersion(_ server: RemoteNote, over row: SyncRow?) throws(StoreError) {
        if row == nil {
            let note = Note(
                id: server.id, title: server.title, body: server.body,
                createdAt: server.createdAt, modifiedAt: server.modifiedAt, conflictOf: server.conflictOf,
                kind: server.kind
            )
            try insert(note, localVersion: 0)
        } else {
            try db.run(
                """
                UPDATE notes
                SET title = ?, body = ?, kind = ?, created_at = ?, modified_at = ?, conflict_of = ?, is_deleted = 0,
                    synced_version = local_version
                WHERE id = ?
                """,
                [
                    .text(server.title), .text(server.body), .text(server.kind.rawValue),
                    .real(server.createdAt.timeIntervalSinceReferenceDate),
                    .real(server.modifiedAt.timeIntervalSinceReferenceDate),
                    server.conflictOf.map { .text($0.uuidString) } ?? .null,
                    .text(server.id.uuidString),
                ]
            )
        }
        try db.run(
            "UPDATE notes SET server_change_tag = ?, server_system_fields = ? WHERE id = ?",
            [tagValue(server), fieldsValue(server), .text(server.id.uuidString)]
        )
    }

    private func tagValue(_ note: RemoteNote) -> SQLiteValue {
        note.changeTag.map { .text($0) } ?? .null
    }

    private func fieldsValue(_ note: RemoteNote) -> SQLiteValue {
        note.systemFields.map { .blob($0) } ?? .null
    }
}
