import Foundation
import Testing
@testable import RelayCore

@MainActor
@Suite("Sync status summary")
struct SyncStatusTests {
    @Test func notConfiguredBuildSaysSoPlainly() {
        let status = SyncStatusModel(availability: .notConfigured)
        #expect(status.summary().text.contains("isn’t enabled"))
    }

    @Test func pendingWorkIsNeverReportedAsSynced() {
        let status = SyncStatusModel(availability: .available)
        status.recordSendSuccess(at: .now)
        status.setPendingUploadCount(2)
        #expect(status.summary().text == "2 changes not uploaded yet.")

        status.recordTransientFailure()
        #expect(status.summary().text == "2 changes not uploaded yet. Will retry automatically.")
    }

    @Test func uploadedOnlyAfterObservedSuccess() {
        let status = SyncStatusModel(availability: .available)
        #expect(status.summary().text == "Waiting for first sync.")
        status.recordSendSuccess(at: .now)
        #expect(status.summary().tone == .good)
    }

    @Test func problemsTakePriorityAndClearOnNextSuccess() {
        let status = SyncStatusModel(availability: .available)
        status.recordProblem("iCloud storage is full.", at: .now)
        #expect(status.summary().text == "iCloud storage is full.")
        status.recordSendSuccess(at: .now)
        #expect(status.problem == nil)
    }

    @Test func accountStatesAreExplained() {
        #expect(SyncStatusModel(availability: .noAccount).summary().tone == .attention)
        #expect(SyncStatusModel(availability: .accountMismatch).summary().text.contains("different iCloud account"))
    }

    @Test func eventLogIsBoundedAndNewestFirst() {
        let status = SyncStatusModel(availability: .available)
        for i in 0..<150 { status.log("event \(i)") }
        #expect(status.recentEvents.count == 100)
        #expect(status.recentEvents.first?.message == "event 149")
    }
}
