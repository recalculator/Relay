import Foundation
import os

/// The durable local store, and the source of truth the UI reads and edits.
///
/// `NoteStore` is an `actor`. All of its state, including the SQLite connection, is
/// isolated to it. Callers outside the actor must `await` each call, which (a) runs the
/// work off the main thread and (b) means only one call touches the database at a time.
///
/// Every method is synchronous *inside* the actor, with no `await` in the middle. That
/// matters because actors are reentrant: at an `await`, another call could run on the
/// actor and observe half-finished state. With no suspension points inside a
/// transaction, each method runs to completion before the next one starts.
public actor NoteStore {
    // `internal` (not `private`) so the sync extension in NoteStore+Sync.swift can use
    // them. They are still actor-isolated.
    let db: SQLiteConnection
    let now: @Sendable () -> Date
    private var observers: [UUID: AsyncStream<StoreChange>.Continuation] = [:]
    /// The current sync session's number. See `beginSyncSession(owner:)`. A lock rather
    /// than actor state, so the coordinator can end a session without an `await`.
    let syncEpoch = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    /// Opens, or creates, the database at `url` and migrates it to the current schema.
    ///
    /// - Parameter now: Clock used for timestamps. Tests inject a deterministic one.
    public init(url: URL, now: @escaping @Sendable () -> Date = { Date() }) throws(StoreError) {
        let db = try SQLiteConnection(url: url)
        try db.configureForDurability()
        try Schema.migrate(db)
        self.db = db
        self.now = now
    }

    /// Opens the store on a background executor rather than the caller's.
    ///
    /// `@concurrent` states explicitly that this async function never runs on the
    /// caller's actor. When the app calls it from the main actor at launch, file I/O and
    /// any migration stay off the main thread.
    @concurrent
    public static func open(
        at url: URL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws(StoreError) -> NoteStore {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw .fileSystem(message: error.localizedDescription)
        }
        let store = try NoteStore(url: url, now: now)
        Log.storage.info("Opened note store")
        return store
    }

    /// Default on-disk location: Application Support/Relay/Notes.sqlite.
    public static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Relay", directoryHint: .isDirectory)
            .appending(path: "Notes.sqlite", directoryHint: .notDirectory)
    }

    public func close() {
        db.close()
        for continuation in observers.values { continuation.finish() }
        observers.removeAll()
    }

    // MARK: Change observation

    /// A stream of committed changes. Each call returns an independent stream. The
    /// stream ends when the store closes or the consumer stops iterating.
    ///
    /// Changes are yielded only *after* their transaction commits, so an observer never
    /// sees data that could still be rolled back.
    public func changes() -> AsyncStream<StoreChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: StoreChange.self)
        let id = UUID()
        observers[id] = continuation
        // `onTermination` is a `@Sendable` closure the stream calls from an arbitrary
        // thread, so it hops back onto the actor with a Task to mutate `observers`.
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    /// - Parameter everything: The change may affect any note (for example a zone reset),
    ///   so observers should reload everything. It is signalled with an empty `noteIDs`.
    func notify(_ origin: StoreChange.Origin, _ ids: some Collection<UUID>, everything: Bool = false) {
        guard !ids.isEmpty || everything else { return }
        let change = StoreChange(origin: origin, noteIDs: Set(ids))
        for continuation in observers.values { continuation.yield(change) }
    }

    // MARK: Reading

    /// All live (non-deleted) notes, most recently modified first.
    public func allNotes() throws(StoreError) -> [Note] {
        try db.query(Self.allNotesQuery, [], Self.decodeNote)
    }

    /// Served in order by the `notes_live_by_modified` index (schema v3), with no sort.
    static let allNotesQuery =
        "SELECT \(noteColumns) FROM notes WHERE is_deleted = 0 ORDER BY modified_at DESC, id"

    /// The live note with this id, or nil if it doesn't exist or has been deleted.
    public func note(id: UUID) throws(StoreError) -> Note? {
        try fetchLiveNote(id)
    }

    /// Notes with local changes the server has not confirmed yet, including deletions.
    public func pendingChanges() throws(StoreError) -> [PendingChange] {
        try db.query(
            """
            SELECT id, is_deleted, local_version FROM notes
            WHERE local_version > synced_version
            ORDER BY modified_at, id
            """
        ) { row throws(StoreError) in
            PendingChange(
                noteID: try Self.decodeID(row),
                kind: row.int64(1) == 0 ? .save : .delete,
                localVersion: row.int64(2)
            )
        }
    }

    // MARK: Writing

    /// Creates and persists a new note. When this returns, the note and its pending
    /// upload are committed together.
    @discardableResult
    public func createNote(title: String = "", body: String = "") throws(StoreError) -> Note {
        let timestamp = now()
        let note = Note(id: UUID(), title: title, body: body, createdAt: timestamp, modifiedAt: timestamp)
        // One INSERT writes both the content and local_version = 1 > synced_version = 0.
        // The "needs upload" marker is part of the same row, so it can't be lost separately.
        try insert(note, localVersion: 1)
        notify(.local, [note.id])
        return note
    }

    /// Replaces a note's title and body.
    ///
    /// If nothing actually changed, the call is a no-op that does not bump the version.
    /// Repeated identical saves therefore produce no new sync work.
    ///
    /// - Parameter base: The content the caller's draft was based on. If the stored
    ///   content no longer matches it, someone else changed the note (normally a sync
    ///   from another device) after the draft was loaded. Rather than silently
    ///   overwriting that change, the store keeps it as a conflict copy in the same
    ///   transaction, then writes the draft.
    /// - Throws: `StoreError.noteNotFound` if the note doesn't exist or was deleted.
    @discardableResult
    public func updateNote(
        id: UUID,
        title: String,
        body: String,
        base: (title: String, body: String)? = nil
    ) throws(StoreError) -> Note {
        var changedIDs: [UUID] = []
        let note = try db.transaction { () throws(StoreError) -> Note in
            guard var note = try fetchLiveNote(id) else { throw .noteNotFound(id) }
            guard note.title != title || note.body != body else { return note }

            if let base, (note.title, note.body) != base {
                if let copyID = try insertConflictCopy(of: id, title: note.title, body: note.body) {
                    changedIDs.append(copyID)
                    Log.storage.notice("Draft was based on stale content; kept newer stored version as conflict copy for note \(id, privacy: .public)")
                }
            }

            note.title = title
            note.body = body
            note.modifiedAt = now()
            try db.run(
                """
                UPDATE notes
                SET title = ?, body = ?, modified_at = ?, local_version = local_version + 1
                WHERE id = ?
                """,
                [.text(title), .text(body), .real(note.modifiedAt.timeIntervalSinceReferenceDate), .text(id.uuidString)]
            )
            changedIDs.append(id)
            return note
        }
        notify(.local, changedIDs)
        return note
    }

    /// Deletes a note locally by turning it into a tombstone.
    ///
    /// The row is kept, with its content cleared and a version bump, so the deletion is
    /// durable pending work. Deleting a missing or already-deleted note is a no-op, so
    /// the operation is idempotent.
    public func deleteNote(id: UUID) throws(StoreError) {
        try db.run(
            """
            UPDATE notes
            SET is_deleted = 1, title = '', body = '', modified_at = ?, local_version = local_version + 1
            WHERE id = ? AND is_deleted = 0
            """,
            [.real(now().timeIntervalSinceReferenceDate), .text(id.uuidString)]
        )
        if db.changes > 0 { notify(.local, [id]) }
    }

    // MARK: Test support

    /// Runs raw SQL against the store. `internal`, so visible only to `@testable` tests.
    /// Used to inject deterministic failures, for example a trigger that aborts writes.
    func executeForTesting(_ sql: String) throws(StoreError) {
        try db.execute(sql)
    }

    func queryIntForTesting(_ sql: String) throws(StoreError) -> Int64? {
        try db.query(sql) { $0.int64(0) }.first
    }

    func queryTextForTesting(_ sql: String) throws(StoreError) -> String? {
        try db.query(sql) { $0.string(0) }.first ?? nil
    }

    /// SQLite's plan for `sql`: one "detail" string per step.
    func queryPlanForTesting(_ sql: String) throws(StoreError) -> [String] {
        try db.query("EXPLAIN QUERY PLAN " + sql) { $0.string(3) ?? "" }
    }

    // MARK: Shared helpers

    static let noteColumns = "id, title, body, created_at, modified_at, conflict_of"

    func fetchLiveNote(_ id: UUID) throws(StoreError) -> Note? {
        try db.query(
            "SELECT \(Self.noteColumns) FROM notes WHERE id = ? AND is_deleted = 0",
            [.text(id.uuidString)],
            Self.decodeNote
        ).first
    }

    func insert(_ note: Note, localVersion: Int64) throws(StoreError) {
        try db.run(
            """
            INSERT INTO notes (id, title, body, created_at, modified_at, conflict_of, local_version)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(note.id.uuidString),
                .text(note.title),
                .text(note.body),
                .real(note.createdAt.timeIntervalSinceReferenceDate),
                .real(note.modifiedAt.timeIntervalSinceReferenceDate),
                note.conflictOf.map { .text($0.uuidString) } ?? .null,
                .integer(localVersion),
            ]
        )
    }

    /// Saves `title`/`body` as a pending conflict copy of note `original`. The copy's id is
    /// derived from the content, so repeating this for the same content is a no-op.
    ///
    /// - Returns: The copy's id if a row was inserted, or nil if it already existed. An
    ///   existing row could also be a tombstone for a copy the user already deleted;
    ///   that stays deleted.
    func insertConflictCopy(of original: UUID, title: String, body: String) throws(StoreError) -> UUID? {
        let copyID = ConflictCopy.id(original: original, title: title, body: body)
        let timestamp = now()
        try db.run(
            """
            INSERT INTO notes (id, title, body, created_at, modified_at, conflict_of, local_version)
            VALUES (?, ?, ?, ?, ?, ?, 1)
            ON CONFLICT(id) DO NOTHING
            """,
            [
                .text(copyID.uuidString),
                .text(ConflictCopy.title(forCopyOf: title)),
                .text(body),
                .real(timestamp.timeIntervalSinceReferenceDate),
                .real(timestamp.timeIntervalSinceReferenceDate),
                .text(original.uuidString),
            ]
        )
        return db.changes > 0 ? copyID : nil
    }

    static func decodeID(_ row: SQLiteRow, column: Int32 = 0) throws(StoreError) -> UUID {
        guard let string = row.string(column), let id = UUID(uuidString: string) else {
            throw .corruptRow(column: "notes.id")
        }
        return id
    }

    static func decodeOptionalID(_ row: SQLiteRow, column: Int32) throws(StoreError) -> UUID? {
        guard let string = row.string(column) else { return nil }
        guard let id = UUID(uuidString: string) else { throw .corruptRow(column: "notes.conflict_of") }
        return id
    }

    /// Decodes the columns listed in `noteColumns`, in that order.
    static func decodeNote(_ row: SQLiteRow) throws(StoreError) -> Note {
        let id = try decodeID(row)
        guard let title = row.string(1) else { throw .corruptRow(column: "notes.title") }
        guard let body = row.string(2) else { throw .corruptRow(column: "notes.body") }
        return Note(
            id: id,
            title: title,
            body: body,
            createdAt: Date(timeIntervalSinceReferenceDate: row.double(3)),
            modifiedAt: Date(timeIntervalSinceReferenceDate: row.double(4)),
            conflictOf: try decodeOptionalID(row, column: 5)
        )
    }
}
