import RelayCore
import SwiftUI

/// An entry's saved versions: pick one, preview it or see what restoring it would
/// change, and restore it. History is kept on this device only.
struct HistoryView: View {
    @State var history: RevisionHistoryModel
    @State private var showChanges = true
    @State private var confirmingRestore = false
    @State private var restoring = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("History")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Restore…") { confirmingRestore = true }
                            .disabled(history.selectedRevision == nil || restoring || selectedIsCurrent)
                    }
                }
                .confirmationDialog("Restore this version?", isPresented: $confirmingRestore, titleVisibility: .visible) {
                    Button("Restore") {
                        Task {
                            restoring = true
                            if await history.restoreSelected() { dismiss() }
                            restoring = false
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The current version is saved in History first, so you can switch back. The restored version syncs like any edit.")
                }
        }
        .frame(minWidth: 720, minHeight: 460)
        .task { await history.load() }
    }

    @ViewBuilder private var content: some View {
        switch history.state {
        case .loading:
            ProgressView()
        case .failed(let error):
            ContentUnavailableView("Couldn't Load History", systemImage: "exclamationmark.triangle",
                                   description: Text(error.localizedDescription))
        case .loaded where history.revisions.isEmpty:
            ContentUnavailableView("No Saved Versions", systemImage: "clock.arrow.circlepath",
                                   description: Text("Choose Save Version (⌘S) to keep a copy of this entry you can come back to. History stays on this device."))
        case .loaded:
            HStack(spacing: 0) {
                List(history.revisions, selection: $history.selectedRevisionID) { revision in
                    RevisionRow(revision: revision).tag(revision.id)
                }
                .frame(width: 240)
                Divider()
                detail
            }
        }
    }

    private var selectedIsCurrent: Bool {
        history.selectedRevision?.content == history.current
    }

    @ViewBuilder private var detail: some View {
        if let revision = history.selectedRevision, let current = history.current {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Show", selection: $showChanges) {
                    Text("Changes").tag(true)
                    Text("Version").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                if let error = history.restoreError {
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if showChanges {
                    ChangesView(current: current, revision: revision.content, lines: history.bodyDiff)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(revision.content.title.isEmpty ? "Untitled" : revision.content.title).font(.headline)
                        Text(revision.content.kind == .template ? "Template" : "Snippet")
                            .font(.caption).foregroundStyle(.secondary)
                        ScrollView {
                            Text(revision.content.body)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView("Select a Version", systemImage: "clock")
        }
    }
}

private struct RevisionRow: View {
    let revision: Revision

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(revision.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                .font(.headline)
            Text(revision.content.title.isEmpty ? "Untitled" : revision.content.title)
                .lineLimit(1)
            if revision.reason == .beforeRestore {
                Text("Saved before a restore").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// What restoring would change, from the current version to the selected one.
private struct ChangesView: View {
    let current: NoteContent
    let revision: NoteContent
    let lines: [LineDiff.Line]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("If you restore: − lines leave the current version, + lines come back.")
                .font(.caption).foregroundStyle(.secondary)
            if current.title != revision.title {
                Text("Title: “\(current.title)” → “\(revision.title)”").font(.callout)
            }
            if current.kind != revision.kind {
                Text("Type: \(name(current.kind)) → \(name(revision.kind))").font(.callout)
            }
            if lines.allSatisfy({ $0.change == .unchanged }) {
                Text(current == revision ? "Identical to the current version." : "The text is the same.")
                    .foregroundStyle(.secondary)
            }
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        DiffLineView(line: line)
                    }
                }
            }
        }
    }

    private func name(_ kind: EntryKind) -> String { kind == .template ? "Template" : "Snippet" }
}

private struct DiffLineView: View {
    let line: LineDiff.Line

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(symbol).frame(width: 12)  // The symbol carries the meaning; color only helps.
            Text(line.text.isEmpty ? " " : line.text)
        }
        .font(.body.monospaced())
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(spokenChange): \(line.text.isEmpty ? "empty line" : line.text)")
    }

    private var symbol: String {
        switch line.change {
        case .unchanged: " "
        case .removed: "−"
        case .added: "+"
        }
    }

    private var spokenChange: String {
        switch line.change {
        case .unchanged: "Unchanged"
        case .removed: "Removed"
        case .added: "Added"
        }
    }

    private var background: Color {
        switch line.change {
        case .unchanged: .clear
        case .removed: .red.opacity(0.15)
        case .added: .green.opacity(0.15)
        }
    }
}
