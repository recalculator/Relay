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
                    ContentUnavailableView("No Notes", systemImage: "note.text", description: Text("Create a note to get started."))
                } else {
                    ContentUnavailableView.search(text: model.searchText)
                }
            }
        }
        .searchable(text: $model.searchText)
        .navigationTitle("Notes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Note", systemImage: "square.and.pencil") {
                    Task { await model.createNote() }
                }
                .keyboardShortcut("n")
            }
        }
    }
}

private struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
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
