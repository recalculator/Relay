import os

/// Unified-logging categories. View in Console.app by filtering on the subsystem.
///
/// Rule: log identifiers, counts, and error codes, never note titles or bodies.
enum Log {
    static let subsystem = "com.ayaanchawla.Relay"

    static let storage = Logger(subsystem: subsystem, category: "Storage")
    static let editor = Logger(subsystem: subsystem, category: "Editor")
    static let sync = Logger(subsystem: subsystem, category: "Sync")
}
