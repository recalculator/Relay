import Foundation

/// A saved version of an entry, kept on this device only.
public struct Revision: Identifiable, Sendable, Hashable {
    public enum Reason: String, Sendable {
        /// The user chose Save Version.
        case checkpoint
        /// Saved automatically just before a restore replaced the entry's content.
        case beforeRestore = "before_restore"
    }

    /// Increases with every insert, so a higher id is a newer revision.
    public let id: Int64
    public let noteID: UUID
    public let createdAt: Date
    public let content: NoteContent
    public let reason: Reason
}

/// An entry's current content and its revisions, read together.
public struct RevisionHistory: Sendable, Equatable {
    public let current: Note
    /// Newest first.
    public let revisions: [Revision]
}

public enum CheckpointResult: Sendable, Equatable {
    case saved(Revision)
    /// The content equals the newest revision, so nothing was added.
    case unchanged
}

/// Local revision history (schema v4 `note_revisions`).
///
/// **Local only.** Revisions are never part of an upload: `UploadSnapshot` and the
/// CloudKit record carry only an entry's current content. Another device's history
/// doesn't sync. History lives in the same database file as its entries, so it can't
/// cross an account switch: the archived database keeps its own history.
///
/// **Retention.** At most `revisionLimit` revisions per entry. Older ones are pruned in
/// the same transaction that adds a new one. An entry's history is deleted with the
/// entry (schema triggers), in the same transaction.
extension NoteStore {
    public static let revisionLimit = 50

    /// The entry's current content and its revisions (newest first), in one read.
    ///
    /// - Throws: `noteNotFound` if the entry doesn't exist or was deleted.
    public func revisionHistory(of noteID: UUID) throws(StoreError) -> RevisionHistory {
        guard let current = try fetchLiveNote(noteID) else { throw .noteNotFound(noteID) }
        let revisions = try db.query(
            """
            SELECT id, note_id, created_at, title, body, kind, reason FROM note_revisions
            WHERE note_id = ? ORDER BY id DESC
            """,
            [.text(noteID.uuidString)],
            Self.decodeRevision
        )
        return RevisionHistory(current: current, revisions: revisions)
    }

    /// Saves the entry's current stored content as a revision ("Save Version").
    ///
    /// Callers save their draft first; this records what's committed. If the content
    /// equals the newest revision, nothing is added.
    public func saveCheckpoint(of noteID: UUID) throws(StoreError) -> CheckpointResult {
        try db.transaction { () throws(StoreError) -> CheckpointResult in
            guard let note = try fetchLiveNote(noteID) else { throw .noteNotFound(noteID) }
            return try insertRevision(of: note, reason: .checkpoint).map(CheckpointResult.saved) ?? .unchanged
        }
    }

    /// Makes a revision's content the entry's current content, as a new local edit.
    ///
    /// In one transaction:
    /// 1. The current content is saved as a `beforeRestore` revision (unless it already
    ///    equals the newest revision), so the restore can be undone.
    /// 2. Title, body, and kind are replaced, and `local_version` is incremented, so the
    ///    restore is pending sync work like any edit. Version counters are never reset,
    ///    and CloudKit metadata (change tag, system fields) isn't touched: the upload is
    ///    based on the latest server version this device knows.
    ///
    /// If anything fails, the transaction rolls back and nothing changes.
    ///
    /// - Returns: The entry after the restore (unchanged if it already had that content).
    /// - Throws: `noteNotFound` if the entry was deleted meanwhile; `revisionNotFound` if
    ///   the revision doesn't exist or belongs to another entry.
    @discardableResult
    public func restore(revision revisionID: Int64, of noteID: UUID) throws(StoreError) -> Note {
        var changed = false
        let note = try db.transaction { () throws(StoreError) -> Note in
            guard var note = try fetchLiveNote(noteID) else { throw .noteNotFound(noteID) }
            guard let revision = try fetchRevision(revisionID), revision.noteID == noteID else {
                throw .revisionNotFound
            }
            guard note.content != revision.content else { return note }

            _ = try insertRevision(of: note, reason: .beforeRestore)
            note.title = revision.content.title
            note.body = revision.content.body
            note.kind = revision.content.kind
            note.modifiedAt = now()
            try db.run(
                """
                UPDATE notes
                SET title = ?, body = ?, kind = ?, modified_at = ?, local_version = local_version + 1
                WHERE id = ? AND is_deleted = 0
                """,
                [.text(note.title), .text(note.body), .text(note.kind.rawValue),
                 .real(note.modifiedAt.timeIntervalSinceReferenceDate), .text(noteID.uuidString)]
            )
            changed = true
            return note
        }
        // Like any local edit: the sync coordinator hears about it and queues an upload.
        if changed { notify(.local, [noteID]) }
        return note
    }

    // MARK: Private

    /// Inserts a revision of `note`'s content unless it equals the newest one, then
    /// prunes to `revisionLimit`. Must run inside a transaction.
    private func insertRevision(of note: Note, reason: Revision.Reason) throws(StoreError) -> Revision? {
        let newest = try db.query(
            "SELECT title, body, kind FROM note_revisions WHERE note_id = ? ORDER BY id DESC LIMIT 1",
            [.text(note.id.uuidString)]
        ) { row in
            NoteContent(title: row.string(0) ?? "", body: row.string(1) ?? "", kind: EntryKind(storedValue: row.string(2)))
        }.first
        guard newest != note.content else { return nil }

        let createdAt = now()
        try db.run(
            """
            INSERT INTO note_revisions (note_id, created_at, title, body, kind, reason)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [.text(note.id.uuidString), .real(createdAt.timeIntervalSinceReferenceDate), .text(note.title),
             .text(note.body), .text(note.kind.rawValue), .text(reason.rawValue)]
        )
        let id = try db.query("SELECT last_insert_rowid()") { $0.int64(0) }.first ?? 0
        try db.run(
            """
            DELETE FROM note_revisions WHERE note_id = ?1 AND id NOT IN (
                SELECT id FROM note_revisions WHERE note_id = ?1 ORDER BY id DESC LIMIT ?2)
            """,
            [.text(note.id.uuidString), .integer(Int64(Self.revisionLimit))]
        )
        return Revision(id: id, noteID: note.id, createdAt: createdAt, content: note.content, reason: reason)
    }

    private func fetchRevision(_ id: Int64) throws(StoreError) -> Revision? {
        try db.query(
            "SELECT id, note_id, created_at, title, body, kind, reason FROM note_revisions WHERE id = ?",
            [.integer(id)],
            Self.decodeRevision
        ).first
    }

    private static func decodeRevision(_ row: SQLiteRow) throws(StoreError) -> Revision {
        guard let title = row.string(3), let body = row.string(4) else {
            throw .corruptRow(column: "note_revisions.content")
        }
        return Revision(
            id: row.int64(0),
            noteID: try decodeID(row, column: 1),
            createdAt: Date(timeIntervalSinceReferenceDate: row.double(2)),
            content: NoteContent(title: title, body: body, kind: EntryKind(storedValue: row.string(5))),
            reason: Revision.Reason(rawValue: row.string(6) ?? "") ?? .checkpoint
        )
    }
}
