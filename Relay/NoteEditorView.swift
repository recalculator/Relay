import RelayCore
import SwiftUI

struct NoteEditorView: View {
    /// `@Bindable` lets the view produce `$editor.title`-style bindings into an
    /// `@Observable` object it doesn't own.
    @Bindable var editor: NoteEditorModel
    let keepAsNewNote: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if editor.noteWasDeleted {
                DeletedElsewhereBanner { Task { await keepAsNewNote() } }
            }
            TextField("Title", text: $editor.title)
                .font(.title2.bold())
                .textFieldStyle(.plain)
                .padding([.horizontal, .top])
                .padding(.bottom, 8)
            Divider()
            TextEditor(text: $editor.body)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
        }
        .safeAreaInset(edge: .bottom) {
            if !editor.noteWasDeleted {
                SaveStatusBar(status: editor.status) {
                    Task { await editor.save() }
                }
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct SaveStatusBar: View {
    let status: NoteEditorModel.SaveStatus
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
            Label("This note was deleted on another device. Your unsaved text is still here.",
                  systemImage: "trash.slash")
            Spacer()
            Button("Keep as New Note", action: keep)
        }
        .font(.callout)
        .padding()
        .background(.orange.opacity(0.15))
    }
}
