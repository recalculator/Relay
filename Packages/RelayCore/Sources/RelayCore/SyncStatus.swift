import Foundation
import Observation

/// What the UI shows about sync. It is driven only by observed sync outcomes (events and
/// results from CKSyncEngine), never by "is the network reachable".
@MainActor
@Observable
public final class SyncStatusModel {
    public enum Availability: Sendable, Equatable {
        /// This build has no CloudKit entitlement (see README). Notes stay local.
        case notConfigured
        /// Waiting for CKSyncEngine to report the iCloud account.
        case starting
        case available
        case noAccount
        /// iCloud is temporarily unavailable, or the account couldn't be determined yet.
        case waitingForAccount
        /// The device's iCloud account differs from the one these notes belong to. Sync is
        /// paused, so the two accounts' data never mix.
        case accountMismatch
    }

    /// A problem that needs attention, as opposed to a transient failure the engine is
    /// already retrying.
    public struct Problem: Sendable, Equatable {
        public let message: String
        public let date: Date
    }

    public struct LogEntry: Sendable, Equatable, Identifiable {
        public let id: Int
        public let date: Date
        public let message: String
    }

    public private(set) var availability: Availability
    public private(set) var isFetching = false
    public private(set) var isSending = false
    public private(set) var pendingUploadCount = 0
    public private(set) var lastSuccessfulSend: Date?
    public private(set) var lastSuccessfulFetch: Date?
    /// True after a transient failure (offline, rate limited, …). Cleared on the next
    /// success. CKSyncEngine retries on its own.
    public private(set) var waitingToRetry = false
    public private(set) var problem: Problem?
    /// Most recent first, capped. Shown in the debug diagnostics view.
    public private(set) var recentEvents: [LogEntry] = []

    @ObservationIgnored private var nextLogID = 0
    @ObservationIgnored private let maxLogEntries = 100

    public init(availability: Availability = .notConfigured) {
        self.availability = availability
    }

    /// One-line description for the status area. It is built only from observed
    /// outcomes. "All changes uploaded" means the server confirmed them, not that a
    /// network is available.
    public struct Summary: Equatable, Sendable {
        public enum Tone: Sendable { case neutral, good, attention }
        public let text: String
        public let systemImage: String
        public let tone: Tone
    }

    public func summary(now: Date = Date()) -> Summary {
        switch availability {
        case .notConfigured:
            return Summary(text: "iCloud sync isn’t enabled in this build. Notes are saved on this device.",
                           systemImage: "icloud.slash", tone: .neutral)
        case .starting:
            return Summary(text: "Connecting to iCloud…", systemImage: "icloud", tone: .neutral)
        case .noAccount:
            return Summary(text: "Not signed in to iCloud. Notes are saved on this device.",
                           systemImage: "icloud.slash", tone: .attention)
        case .waitingForAccount:
            return Summary(text: "Waiting for iCloud to confirm the account. Notes are saved on this device.",
                           systemImage: "icloud", tone: .neutral)
        case .accountMismatch:
            return Summary(text: "These notes belong to a different iCloud account. Sync is paused.",
                           systemImage: "exclamationmark.icloud", tone: .attention)
        case .available:
            break
        }
        if let problem {
            return Summary(text: problem.message, systemImage: "exclamationmark.icloud", tone: .attention)
        }
        if isSending || isFetching {
            return Summary(text: "Syncing…", systemImage: "arrow.triangle.2.circlepath.icloud", tone: .neutral)
        }
        let changes = pendingUploadCount == 1 ? "1 change" : "\(pendingUploadCount) changes"
        if pendingUploadCount > 0 {
            let suffix = waitingToRetry ? " Will retry automatically." : ""
            return Summary(text: "\(changes) not uploaded yet.\(suffix)", systemImage: "icloud.and.arrow.up", tone: .neutral)
        }
        if let last = [lastSuccessfulSend, lastSuccessfulFetch].compactMap({ $0 }).max() {
            let when = last.formatted(.relative(presentation: .named, unitsStyle: .wide))
            return Summary(text: "All changes uploaded. Last synced \(when).", systemImage: "checkmark.icloud", tone: .good)
        }
        return Summary(text: "Waiting for first sync.", systemImage: "icloud", tone: .neutral)
    }

    // MARK: Updates (called by SyncCoordinator)

    func setAvailability(_ availability: Availability) {
        guard availability != self.availability else { return }
        self.availability = availability
        log("Account state: \(availability)")
    }

    func setPendingUploadCount(_ count: Int) {
        pendingUploadCount = count
    }

    func fetchStarted() {
        isFetching = true
    }

    func fetchFinished(succeeded: Bool, at date: Date) {
        isFetching = false
        if succeeded {
            lastSuccessfulFetch = date
            waitingToRetry = false
        }
    }

    func sendStarted() {
        isSending = true
    }

    func sendFinished() {
        isSending = false
    }

    func recordSendSuccess(at date: Date) {
        lastSuccessfulSend = date
        waitingToRetry = false
        problem = nil
    }

    func recordTransientFailure() {
        waitingToRetry = true
    }

    func recordProblem(_ message: String, at date: Date) {
        problem = Problem(message: message, date: date)
        log("Problem: \(message)")
    }

    func log(_ message: String, at date: Date = Date()) {
        recentEvents.insert(LogEntry(id: nextLogID, date: date, message: message), at: 0)
        nextLogID += 1
        if recentEvents.count > maxLogEntries { recentEvents.removeLast() }
    }
}
