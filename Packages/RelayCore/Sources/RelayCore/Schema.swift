/// Database schema and migrations.
///
/// The schema version lives in SQLite's `PRAGMA user_version` header field. Each
/// migration runs in the same transaction as the version bump, so a crash mid-migration
/// leaves the file at the old version with the old schema. SQLite DDL is transactional.
///
/// Policy: add a new numbered migration for every schema change. Never edit a migration
/// that has run on real data. A file whose version is newer than `currentVersion` is
/// refused rather than opened.
enum Schema {
    static let currentVersion = 4

    private static let migrations: [(version: Int, sql: String)] = [
        (1, v1),
        (2, v2),
        (3, v3),
        (4, v4),
    ]

    static func migrate(_ db: SQLiteConnection) throws(StoreError) {
        let found = try db.userVersion()
        guard found <= currentVersion else {
            throw .unsupportedSchemaVersion(found: found, supported: currentVersion)
        }
        for migration in migrations where migration.version > found {
            try db.transaction { () throws(StoreError) in
                try db.execute(migration.sql)
                try db.setUserVersion(migration.version)
            }
            Log.storage.info("Migrated database to schema v\(migration.version)")
        }
    }

    /// v1: notes, plus the local bookkeeping that makes pending work durable.
    ///
    /// - `local_version` increments on every local edit or delete.
    /// - `synced_version` records the highest `local_version` the server has confirmed.
    ///   A row is pending upload exactly when `local_version > synced_version`.
    /// - `is_deleted = 1` is a tombstone: the note is hidden locally but kept until the
    ///   deletion is confirmed remotely.
    ///
    /// `STRICT` makes SQLite reject values of the wrong type instead of coercing them.
    private static let v1 = """
        CREATE TABLE notes (
            id             TEXT    PRIMARY KEY NOT NULL,
            title          TEXT    NOT NULL,
            body           TEXT    NOT NULL,
            created_at     REAL    NOT NULL,
            modified_at    REAL    NOT NULL,
            is_deleted     INTEGER NOT NULL DEFAULT 0,
            local_version  INTEGER NOT NULL,
            synced_version INTEGER NOT NULL DEFAULT 0
        ) STRICT;
        """

    /// v2: CloudKit sync metadata.
    ///
    /// - `conflict_of`: for conflict copies, the id of the original note.
    /// - `server_change_tag`: the change tag of the last server version this row is based
    ///   on. Comparing it with a fetched record's tag tells "new server change" apart from
    ///   "an echo of a version we already have".
    /// - `server_system_fields`: that server record's encoded system fields
    ///   (`CKRecord.encodeSystemFields`). Uploads are built from it, so CloudKit can detect
    ///   conflicting writes.
    /// - `sync_state`: small key/value table for the serialized CKSyncEngine state and
    ///   the iCloud account this database belongs to. It lives in the same file as the
    ///   notes, so it is committed alongside the data it describes.
    private static let v2 = """
        ALTER TABLE notes ADD COLUMN conflict_of TEXT;
        ALTER TABLE notes ADD COLUMN server_change_tag TEXT;
        ALTER TABLE notes ADD COLUMN server_system_fields BLOB;
        CREATE TABLE sync_state (
            key   TEXT PRIMARY KEY NOT NULL,
            value BLOB NOT NULL
        ) STRICT;
        """

    /// v3: an index matching `NoteStore.allNotes()`'s `WHERE is_deleted = 0 ORDER BY
    /// modified_at DESC, id`, so SQLite reads live notes in order instead of copying
    /// every row (bodies included) into a temporary B-tree to sort it. Measured in
    /// BENCHMARKS.md. The query and its results are unchanged.
    private static let v3 = """
        CREATE INDEX notes_live_by_modified ON notes (is_deleted, modified_at DESC, id);
        """

    /// v4: entry kinds and local revision history.
    ///
    /// - `kind`: `'snippet'` or `'template'` (`EntryKind`). Existing rows become snippets.
    /// - `note_revisions`: explicit "Save Version" checkpoints, plus the automatic
    ///   checkpoint taken before a restore. Local only; never part of a CloudKit record.
    ///   `id` increases with each insert, so the newest revision has the highest id.
    /// - The triggers delete an entry's history in the same transaction that deletes or
    ///   tombstones the entry, whichever code path does it (user delete, remote
    ///   deletion, purge after upload, zone reset).
    private static let v4 = """
        ALTER TABLE notes ADD COLUMN kind TEXT NOT NULL DEFAULT 'snippet';
        CREATE TABLE note_revisions (
            id         INTEGER PRIMARY KEY,
            note_id    TEXT    NOT NULL,
            created_at REAL    NOT NULL,
            title      TEXT    NOT NULL,
            body       TEXT    NOT NULL,
            kind       TEXT    NOT NULL,
            reason     TEXT    NOT NULL
        ) STRICT;
        CREATE INDEX note_revisions_by_note ON note_revisions (note_id, id);
        CREATE TRIGGER note_revisions_on_delete AFTER DELETE ON notes
        BEGIN
            DELETE FROM note_revisions WHERE note_id = OLD.id;
        END;
        CREATE TRIGGER note_revisions_on_tombstone AFTER UPDATE OF is_deleted ON notes
        WHEN NEW.is_deleted = 1
        BEGIN
            DELETE FROM note_revisions WHERE note_id = NEW.id;
        END;
        """
}
