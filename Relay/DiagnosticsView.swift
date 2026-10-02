import RelayCore
import SwiftUI

/// Debug-only sync diagnostics. In release builds it is just a short notice.
///
/// It contains no simulated failure modes. Everything shown comes from the real engine
/// (or "not configured" if sync is compiled out).
struct DiagnosticsView: View {
    let status: SyncStatusModel
    let sync: SyncCoordinator?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Sync Diagnostics")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        #if DEBUG
        Form {
            Section("State") {
                LabeledContent("Account", value: String(describing: status.availability))
                LabeledContent("Pending uploads", value: "\(status.pendingUploadCount)")
                LabeledContent("Activity", value: activity)
                LabeledContent("Last successful send", value: format(status.lastSuccessfulSend))
                LabeledContent("Last successful fetch", value: format(status.lastSuccessfulFetch))
                LabeledContent("Waiting to retry", value: status.waitingToRetry ? "Yes" : "No")
                if let problem = status.problem {
                    LabeledContent("Problem", value: problem.message)
                }
            }
            Section {
                Button("Sync Now") {
                    Task { await sync?.syncNow() }
                }
                .disabled(sync == nil)
            } footer: {
                Text("Asks CKSyncEngine to fetch, then send, immediately. Normal syncing is scheduled by the engine.")
            }
            Section("Recent events") {
                if status.recentEvents.isEmpty {
                    Text("No events yet.").foregroundStyle(.secondary)
                }
                ForEach(status.recentEvents) { entry in
                    VStack(alignment: .leading) {
                        Text(entry.message).font(.callout)
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        #else
        Text("Diagnostics are available in debug builds.")
        #endif
    }

    private var activity: String {
        switch (status.isFetching, status.isSending) {
        case (true, true): "Fetching and sending"
        case (true, false): "Fetching"
        case (false, true): "Sending"
        case (false, false): "Idle"
        }
    }

    private func format(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .standard) ?? "Never"
    }
}
