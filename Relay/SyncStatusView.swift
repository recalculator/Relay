import RelayCore
import SwiftUI

/// The small status area under the notes list. The text comes from
/// `SyncStatusModel.summary`, which reflects observed sync outcomes only.
struct SyncStatusView: View {
    let status: SyncStatusModel
    let startFreshForCurrentAccount: () async -> Void
    let showDiagnostics: () -> Void

    @State private var confirmingSwitch = false

    var body: some View {
        // Re-evaluate the relative "last synced" time periodically.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let summary = status.summary(now: context.date)
            VStack(alignment: .leading, spacing: 6) {
                Label(summary.text, systemImage: summary.systemImage)
                    .foregroundStyle(summary.tone == .attention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                if status.availability == .accountMismatch {
                    Button("Use This Account’s Notes…") { confirmingSwitch = true }
                        .buttonStyle(.borderless)
                }
            }
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        #if DEBUG
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: showDiagnostics)
        .help("Double-click for sync diagnostics (debug builds)")
        #endif
        .confirmationDialog(
            "Use this iCloud account’s notes?",
            isPresented: $confirmingSwitch,
            titleVisibility: .visible
        ) {
            Button("Switch Accounts") {
                Task { await startFreshForCurrentAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The notes on this device belong to the iCloud account that was signed in before. They’ll be moved to an archive on this device (not uploaded and not deleted), and Relay will download the current account’s notes.")
        }
    }
}
