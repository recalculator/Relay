import Foundation
import os
@testable import RelayCore

/// A unique on-disk directory per test, removed when the value is deallocated.
/// Tests use real files (not `:memory:`) so that close-and-reopen is meaningful.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "RelayCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var storeURL: URL { url.appending(path: "Notes.sqlite") }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A deterministic clock: each call returns one second later than the previous one.
/// `OSAllocatedUnfairLock` makes the mutable counter safe to share (`Sendable`).
func steppingClock() -> @Sendable () -> Date {
    let seconds = OSAllocatedUnfairLock(initialState: 0.0)
    return {
        seconds.withLock { value in
            value += 1
            return Date(timeIntervalSinceReferenceDate: value)
        }
    }
}

/// SQL that makes every UPDATE on `notes` fail. This deterministically simulates a
/// write failure such as a full disk or I/O error.
let failAllUpdatesTrigger = """
    CREATE TRIGGER fail_updates BEFORE UPDATE ON notes
    BEGIN SELECT RAISE(ABORT, 'injected test failure'); END;
    """

let removeFailureTrigger = "DROP TRIGGER fail_updates;"
