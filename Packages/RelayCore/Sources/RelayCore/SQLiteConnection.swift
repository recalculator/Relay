import Foundation
import SQLite3

/// A value bound to a `?` placeholder in a SQL statement.
enum SQLiteValue {
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
    case null
}

/// Read access to the current row of a stepping statement. Only valid inside the
/// `query` callback that receives it.
struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    func int64(_ column: Int32) -> Int64 {
        sqlite3_column_int64(statement, column)
    }

    func double(_ column: Int32) -> Double {
        sqlite3_column_double(statement, column)
    }

    /// Returns nil for SQL NULL. Uses the stored byte length rather than scanning for a
    /// terminator, so text containing U+0000 round-trips intact.
    func string(_ column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    func data(_ column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        // SQLite returns a NULL pointer for a zero-length blob.
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}

/// A thin wrapper over one SQLite connection.
///
/// This class is deliberately *not* `Sendable` and has no locks. It is owned by the
/// `NoteStore` actor, and the actor's isolation guarantees that only one task at a time
/// touches the connection. The compiler enforces that it cannot escape the actor.
final class SQLiteConnection {
    private var handle: OpaquePointer?

    init(url: URL) throws(StoreError) {
        var db: OpaquePointer?
        // NOMUTEX: SQLite's own per-connection mutex is unnecessary because the owning
        // actor already serializes access.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(url.path(percentEncoded: false), &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle"
            // sqlite3_open_v2 may allocate a handle even on failure; it must be closed.
            sqlite3_close_v2(db)
            throw .openFailed(code: rc, message: message)
        }
        handle = db
        sqlite3_extended_result_codes(db, 1)
        // If another connection holds the write lock, wait up to 5 s instead of failing
        // immediately with SQLITE_BUSY.
        sqlite3_busy_timeout(db, 5_000)
    }

    deinit {
        close()
    }

    func close() {
        guard let handle else { return }
        sqlite3_close_v2(handle)
        self.handle = nil
    }

    // MARK: Executing SQL

    /// Runs one or more statements that take no parameters and return no rows we need
    /// (schema DDL, pragmas, BEGIN/COMMIT).
    func execute(_ sql: String) throws(StoreError) {
        let db = try openHandle()
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard rc == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            throw .sqlite(code: rc, message: message)
        }
    }

    /// Runs a single parameterized statement that returns no rows.
    func run(_ sql: String, _ values: [SQLiteValue] = []) throws(StoreError) {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        let rc = sqlite3_step(statement)
        guard rc == SQLITE_DONE else { throw lastError(rc) }
    }

    /// Runs a parameterized query and decodes every row with `decode`.
    func query<T>(
        _ sql: String,
        _ values: [SQLiteValue] = [],
        _ decode: (SQLiteRow) throws(StoreError) -> T
    ) throws(StoreError) -> [T] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        var results: [T] = []
        while true {
            let rc = sqlite3_step(statement)
            switch rc {
            case SQLITE_ROW:
                results.append(try decode(SQLiteRow(statement: statement)))
            case SQLITE_DONE:
                return results
            default:
                throw lastError(rc)
            }
        }
    }

    /// Number of rows changed by the most recent INSERT/UPDATE/DELETE.
    var changes: Int {
        handle.map { Int(sqlite3_changes($0)) } ?? 0
    }

    /// Runs `body` inside a write transaction. Either everything in `body` commits, or
    /// nothing does: any thrown error rolls the transaction back and is rethrown.
    ///
    /// `BEGIN IMMEDIATE` takes the write lock up front, so a read-then-write sequence in
    /// `body` cannot be invalidated by another connection between the read and the write.
    func transaction<T>(_ body: () throws(StoreError) -> T) throws(StoreError) -> T {
        try execute("BEGIN IMMEDIATE")
        do throws(StoreError) {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            rollbackIfNeeded()
            throw error
        }
    }

    /// Durability settings applied to every connection. See ARCHITECTURE.md
    /// ("Durability") for what these do and do not guarantee.
    ///
    /// - `journal_mode = WAL`: commits append to a write-ahead log. Readers don't block
    ///   the writer.
    /// - `synchronous = FULL`: SQLite syncs the WAL at every commit, rather than only at
    ///   checkpoints as with NORMAL.
    /// - `fullfsync = ON` / `checkpoint_fullfsync = ON`: on Apple platforms, plain
    ///   `fsync()` doesn't ask the drive to flush its write cache. These make SQLite use
    ///   `F_FULLFSYNC`, which does. It costs latency on each commit, which is acceptable
    ///   at autosave rates.
    func configureForDurability() throws(StoreError) {
        try execute("""
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = FULL;
            PRAGMA fullfsync = ON;
            PRAGMA checkpoint_fullfsync = ON;
            """)
    }

    // MARK: Schema version

    func userVersion() throws(StoreError) -> Int {
        try query("PRAGMA user_version") { row in Int(row.int64(0)) }.first ?? 0
    }

    func setUserVersion(_ version: Int) throws(StoreError) {
        // PRAGMA arguments cannot be bound as parameters. `version` is an Int, so
        // interpolating it cannot inject SQL.
        try execute("PRAGMA user_version = \(version)")
    }

    // MARK: Private

    private func openHandle() throws(StoreError) -> OpaquePointer {
        guard let handle else { throw .closed }
        return handle
    }

    private func prepare(_ sql: String) throws(StoreError) -> OpaquePointer {
        let db = try openHandle()
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else { throw lastError(rc) }
        return statement
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws(StoreError) {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)  // SQLite parameters are 1-based.
            let rc: Int32 = switch value {
            case .integer(let int):
                sqlite3_bind_int64(statement, index, int)
            case .real(let double):
                sqlite3_bind_double(statement, index, double)
            case .text(let string):
                // Pass the UTF-8 byte count so embedded NULs are preserved.
                // SQLITE_TRANSIENT makes SQLite copy the bytes before this call returns.
                sqlite3_bind_text(statement, index, string, Int32(string.utf8.count), sqliteTransient)
            case .blob(let data):
                data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
                }
            case .null:
                sqlite3_bind_null(statement, index)
            }
            guard rc == SQLITE_OK else { throw lastError(rc) }
        }
    }

    private func lastError(_ rc: Int32) -> StoreError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed"
        return .sqlite(code: rc, message: message)
    }

    private func rollbackIfNeeded() {
        guard let handle else { return }
        // autocommit == 0 means a transaction is still open. A failed COMMIT can leave
        // one open; some errors make SQLite roll back on its own.
        guard sqlite3_get_autocommit(handle) == 0 else { return }
        if sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) != SQLITE_OK {
            Log.storage.fault("ROLLBACK failed: \(String(cString: sqlite3_errmsg(handle)), privacy: .public)")
        }
    }
}

/// SQLite's `SQLITE_TRANSIENT` destructor sentinel. The C macro is not importable into
/// Swift, so it is rebuilt here.
private var sqliteTransient: sqlite3_destructor_type {
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
