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
    static let currentVersion = 2

    private static let migrations: [(version: Int, sql: String)] = [
        (1, v1),
        (2, v2),
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
}
