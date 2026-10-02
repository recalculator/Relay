import RelayCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: NotesModel
    let syncStatus: SyncStatusModel
    let sync: SyncCoordinator?

    @State private var showingDiagnostics = false

    var body: some View {
        switch model.state {
        case .loading:
            ProgressView("Opening notes…")
        case .failed(let error):
            ContentUnavailableView {
                Label("Couldn’t Open Notes", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.localizedDescription)
            }
        case .ready:
            NavigationSplitView {
                NoteListView(model: model)
                    .safeAreaInset(edge: .bottom) {
                        SyncStatusView(status: syncStatus) {
                            await model.startFreshForCurrentAccount()
                        } showDiagnostics: {
                            showingDiagnostics = true
                        }
                    }
            } detail: {
                if let editor = model.editor {
                    // `.id` gives each note a fresh editor view, so text-field state
                    // can't carry over from the previously selected note.
                    NoteEditorView(editor: editor) {
                        await model.keepDeletedNoteDraftAsNewNote()
                    }
                    .id(editor.noteID)
                } else {
                    ContentUnavailableView("No Note Selected", systemImage: "note.text")
                }
            }
            .sheet(isPresented: $showingDiagnostics) {
                DiagnosticsView(status: syncStatus, sync: sync)
            }
            .alert(
                "Something Went Wrong",
                isPresented: Binding(
                    get: { model.presentedError != nil },
                    set: { if !$0 { model.presentedError = nil } }
                ),
                presenting: model.presentedError
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { error in
                Text(error.localizedDescription)
            }
        }
    }
}
