import RelayCore
import SwiftUI

struct NoteEditorView: View {
    /// `@Bindable` lets the view produce `$editor.title`-style bindings into an
    /// `@Observable` object it doesn't own.
    @Bindable var editor: NoteEditorModel
    let keepAsNewNote: () async -> Void

    @State private var fillingTemplate = false
    @State private var history: RevisionHistoryModel?
    @State private var notice: Notice?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if editor.noteWasDeleted {
                DeletedElsewhereBanner { Task { await keepAsNewNote() } }
            }
            HStack(alignment: .firstTextBaseline) {
                TextField("Title", text: $editor.title)
                    .font(.title2.bold())
                    .textFieldStyle(.plain)
                Picker("Entry type", selection: $editor.kind) {
                    Text("Snippet").tag(EntryKind.snippet)
                    Text("Template").tag(EntryKind.template)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("A template has {{placeholders}} you fill in before copying")
            }
            .padding([.horizontal, .top])
            .padding(.bottom, 8)
            if editor.kind == .template {
                PlaceholderSummary(template: Template(parsing: editor.body))
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
            Divider()
            TextEditor(text: $editor.body)
                .font(.body.monospaced())
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .accessibilityLabel(editor.kind == .template ? "Template text" : "Snippet text")
        }
        .safeAreaInset(edge: .bottom) {
            if !editor.noteWasDeleted {
                SaveStatusBar(status: editor.status, notice: notice) {
                    Task { await editor.save() }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Save Version", systemImage: "bookmark") { Task { await saveVersion() } }
                    .keyboardShortcut("s")
                    .help("Keep this version in History (⌘S)")
                Button("History", systemImage: "clock.arrow.circlepath") { history = editor.makeHistory() }
                    .keyboardShortcut("y")
                    .help("Saved versions of this entry (⌘Y)")
                if editor.kind == .template {
                    Button("Fill Template…", systemImage: "curlybraces") { fillingTemplate = true }
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                        .help("Fill in the placeholders and copy the result (⇧⌘C)")
                } else {
                    Button("Copy", systemImage: "doc.on.doc") { copy(editor.body) }
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                        .help("Copy the snippet (⇧⌘C)")
                }
            }
        }
        .sheet(isPresented: $fillingTemplate) {
            // The editor is behind a modal sheet, so the text can't change while it's open.
            FillTemplateView(text: editor.body) { copy($0) }
        }
        .sheet(item: $history) { history in
            HistoryView(history: history)
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func copy(_ text: String) {
        Clipboard.copy(text)
        notice = Notice("Copied", systemImage: "doc.on.clipboard")
    }

    private func saveVersion() async {
        notice = switch await editor.saveVersion() {
        case .saved: Notice("Version saved", systemImage: "bookmark.fill")
        case .unchanged: Notice("No changes since the last saved version", systemImage: "bookmark")
        case .failed: Notice("Version not saved", systemImage: "exclamationmark.triangle")
        }
    }
}

/// A short message in the status bar, shown for a few seconds. Never includes the text
/// that was copied.
struct Notice: Equatable {
    let text: String
    let systemImage: String
    let date = Date.now

    init(_ text: String, systemImage: String) {
        self.text = text
        self.systemImage = systemImage
    }
}

/// One line under the title: which placeholders a template has, and any malformed ones.
private struct PlaceholderSummary: View {
    let template: Template

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if template.placeholders.isEmpty {
                Text("No placeholders yet. Add one like {{host}}.")
            } else {
                Text("Placeholders: \(template.placeholders.joined(separator: ", "))")
                    .lineLimit(1)
            }
            if let issue = template.issues.first {
                Label("Line \(issue.line): \(issue.text) isn't a valid placeholder"
                      + (template.issues.count > 1 ? " (+\(template.issues.count - 1) more)" : ""),
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
    }
}

private struct SaveStatusBar: View {
    let status: NoteEditorModel.SaveStatus
    let notice: Notice?
    let retry: () -> Void

    var body: some View {
        HStack {
            switch status {
            case .saved:
                Label("Saved on this device", systemImage: "checkmark.circle")
            case .editing:
                Label("Editing…", systemImage: "pencil")
            case .saving:
                Label("Saving…", systemImage: "arrow.down.doc")
            case .failed(let error):
                Label {
                    Text("Not saved: \(error.localizedDescription) Your text is still here.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Retry", action: retry)
            }
            Spacer(minLength: 0)
            if let notice {
                TimelineView(.periodic(from: notice.date, by: 1)) { context in
                    if context.date.timeIntervalSince(notice.date) < 3 {
                        Label(notice.text, systemImage: notice.systemImage)
                    }
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct DeletedElsewhereBanner: View {
    let keep: () -> Void

    var body: some View {
        HStack {
            Label("This entry was deleted on another device. Your unsaved text is still here.",
                  systemImage: "trash.slash")
            Spacer()
            Button("Keep as New Entry", action: keep)
        }
        .font(.callout)
        .padding()
        .background(.orange.opacity(0.15))
    }
}
