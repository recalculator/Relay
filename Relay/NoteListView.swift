import RelayCore
import SwiftUI

struct NoteListView: View {
    @Bindable var model: NotesModel

    var body: some View {
        let notes = model.visibleNotes
        List(selection: Binding(get: { model.selectedNoteID }, set: { model.select($0) })) {
            ForEach(notes) { note in
                NoteRow(note: note)
                    .tag(note.id)
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            Task { await model.deleteNote(id: note.id) }
                        }
                    }
            }
            .onDelete { offsets in
                let ids = offsets.map { notes[$0].id }
                Task {
                    for id in ids { await model.deleteNote(id: id) }
                }
            }
        }
        .overlay {
            if notes.isEmpty {
                if model.searchText.isEmpty {
                    ContentUnavailableView("No Entries", systemImage: "terminal",
                                           description: Text("Create a snippet (⌘N) or a command template (⇧⌘N)."))
                } else {
                    ContentUnavailableView.search(text: model.searchText)
                }
            }
        }
        .searchable(text: $model.searchText)
        .navigationTitle("Relay")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // Keyboard shortcuts live in the File menu (RelayApp's commands).
                Menu {
                    Button("New Snippet") { Task { await model.createNote(kind: .snippet) } }
                    Button("New Template") { Task { await model.createNote(kind: .template) } }
                } label: {
                    Label("New Entry", systemImage: "square.and.pencil")
                } primaryAction: {
                    Task { await model.createNote(kind: .snippet) }
                }
            }
        }
    }
}

private struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if note.kind == .template {
                    Image(systemName: "curlybraces")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Template")
                }
                if note.conflictOf != nil {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Conflict copy")
                }
                Text(note.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(note.modifiedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                Text(note.preview)
                    .lineLimit(1)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
