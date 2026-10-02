import Foundation

/// Every failure the local store can produce.
///
/// Store APIs use typed throws (`throws(StoreError)`), so callers know the complete set
/// of failures at compile time and can switch over them without a generic `any Error`.
public enum StoreError: Error, Equatable, Sendable {
    /// The database file could not be opened or created.
    case openFailed(code: Int32, message: String)
    /// The directory holding the database could not be created.
    case fileSystem(message: String)
    /// A SQLite statement failed. `code` is SQLite's extended result code.
    case sqlite(code: Int32, message: String)
    /// The note does not exist, or has been deleted.
    case noteNotFound(UUID)
    /// A stored row could not be decoded into a model value.
    case corruptRow(column: String)
    /// The file was written by a newer schema than this build understands. Opening it
    /// anyway could damage data, so the store refuses.
    case unsupportedSchemaVersion(found: Int, supported: Int)
    /// The store was used after `close()`.
    case closed
    /// A sync write came from a sync session that has since ended (its engine stopped,
    /// or the database's owner changed). It was discarded without changing anything.
    case staleSyncOperation
}

extension StoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .openFailed(let code, _):
            "Relay couldn’t open its notes database (SQLite error \(code))."
        case .fileSystem:
            "Relay couldn’t create its storage folder."
        case .sqlite(let code, _):
            "The database operation failed (SQLite error \(code))."
        case .noteNotFound:
            "This note no longer exists."
        case .corruptRow:
            "Some stored data couldn’t be read."
        case .unsupportedSchemaVersion:
            "These notes were saved by a newer version of Relay. Update the app to open them."
        case .closed:
            "The notes database is closed."
        case .staleSyncOperation:
            "A sync change from an earlier sync session was discarded."
        }
    }
}
