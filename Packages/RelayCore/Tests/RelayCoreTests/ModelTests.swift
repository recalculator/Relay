import Foundation
import Testing
@testable import RelayCore

/// UI-state tests. They run on the main actor, like the real UI does.
///
/// Autosave is configured with a one-hour delay so it never fires during a test; tests
/// call `save()` explicitly. This keeps them deterministic, with no sleeps.
@MainActor
@Suite("NoteEditorModel")
struct NoteEditorModelTests {
    let directory: TemporaryDirectory
    let store: NoteStore

    init() throws {
        directory = try TemporaryDirectory()
        store = try NoteStore(url: directory.storeURL, now: steppingClock())
    }

    private func makeEditor(for note: Note, onSaved: @escaping @MainActor (Note) -> Void = { _ in }) -> NoteEditorModel {
        NoteEditorModel(note: note, store: store, autosaveDelay: .seconds(3600), onSaved: onSaved)
    }

    @Test func editingMarksDraftUnsavedUntilSaved() async throws {
        let note = try await store.createNote(title: "t", body: "b")
        var savedNotes: [Note] = []
        let editor = makeEditor(for: note) { savedNotes.append($0) }

        editor.body = "b2"
        #expect(editor.status == .editing)
        #expect(editor.hasUnsavedChanges)
        #expect(try await store.note(id: note.id)?.body == "b")  // Not saved yet.

        await editor.save()
        #expect(editor.status == .saved)
        #expect(!editor.hasUnsavedChanges)
        #expect(try await store.note(id: note.id)?.body == "b2")
        #expect(savedNotes.map(\.body) == ["b2"])
    }

    /// Turning a snippet into a template is an ordinary edit: it's saved through
    /// `updateNote` and becomes pending sync work carrying the new kind.
    @Test func changingTheKindIsSavedAndQueuedForUpload() async throws {
        let note = try await store.createNote(title: "deploy", body: "make deploy ENV={{env}}")
        let before = try #require(try await store.uploadSnapshot(id: note.id)).localVersion
        let editor = makeEditor(for: note)

        editor.kind = .template
        #expect(editor.hasUnsavedChanges)
        await editor.save()

        #expect(editor.status == .saved)
        #expect(try await store.note(id: note.id)?.kind == .template)
        let snapshot = try #require(try await store.uploadSnapshot(id: note.id))
        #expect(snapshot.kind == .template)
        #expect(snapshot.localVersion == before + 1)
    }

    @Test func revertingDraftToSavedContentIsNotAnEdit() async throws {
        let note = try await store.createNote(title: "t", body: "b")
        let editor = makeEditor(for: note)
        editor.body = "changed"
        editor.body = "b"
        #expect(editor.status == .saved)
        await editor.save()
        #expect(try await store.pendingChanges().map(\.localVersion) == [1])
    }

    @Test func overlappingSavesCommitLatestDraftInOrder() async throws {
        let note = try await store.createNote(title: "t", body: "")
        let editor = makeEditor(for: note)

        editor.body = "first"
        async let firstSave: Void = editor.save()
        editor.body = "second"
        await editor.save()
        await firstSave

        // However the two saves interleave, the chain ensures the final committed
        // content is the latest draft, and no older snapshot is written after it.
        #expect(try await store.note(id: note.id)?.body == "second")
        #expect(editor.status == .saved)
    }

    @Test func failedSaveKeepsDraftAndReportsErrorThenRecovers() async throws {
        let note = try await store.createNote(title: "t", body: "original")
        let editor = makeEditor(for: note)
        try await store.executeForTesting(failAllUpdatesTrigger)

        editor.body = "precious edit"
        await editor.save()

        guard case .failed(.sqlite) = editor.status else {
            Issue.record("Expected .failed(.sqlite), got \(editor.status)")
            return
        }
        #expect(editor.body == "precious edit")  // Draft kept in memory.
        #expect(editor.hasUnsavedChanges)
        #expect(try await store.note(id: note.id)?.body == "original")

        try await store.executeForTesting(removeFailureTrigger)
        await editor.save()
        #expect(editor.status == .saved)
        #expect(try await store.note(id: note.id)?.body == "precious edit")
    }

    @Test func savingANoteDeletedElsewhereReportsNotFound() async throws {
        let note = try await store.createNote(title: "t", body: "")
        let editor = makeEditor(for: note)
        try await store.deleteNote(id: note.id)

        editor.body = "late edit"
        await editor.save()
        #expect(editor.status == .failed(.noteNotFound(note.id)))
        #expect(editor.body == "late edit")
    }
}

@MainActor
@Suite("NotesModel")
struct NotesModelTests {
    let directory: TemporaryDirectory
    let store: NoteStore

    init() throws {
        directory = try TemporaryDirectory()
        store = try NoteStore(url: directory.storeURL, now: steppingClock())
    }

    private func makeModel() async -> NotesModel {
        let model = NotesModel(autosaveDelay: .seconds(3600))
        await model.attach(store)
        return model
    }

    @Test func createSelectsNewNoteAndEditsAreFlushedOnSelectionChange() async throws {
        let model = await makeModel()
        await model.createNote()
        let firstID = try #require(model.selectedNoteID)
        model.editor?.title = "First"

        await model.createNote()  // Selecting the new note flushes the old editor.
        await model.flushPendingEdits()

        #expect(model.notes.count == 2)
        #expect(try await store.note(id: firstID)?.title == "First")
        #expect(model.notes.first { $0.id == firstID }?.title == "First")
        #expect(!model.hasWorkInProgress)
    }

    @Test func searchMatchesTitleAndBodyIgnoringCaseAndDiacritics() async throws {
        try await store.createNote(title: "Café plans", body: "")
        try await store.createNote(title: "Other", body: "Meet at the CAFE")
        try await store.createNote(title: "Unrelated", body: "nothing")
        let model = await makeModel()

        model.searchText = "cafe"
        #expect(Set(model.visibleNotes.map(\.title)) == ["Café plans", "Other"])
        model.searchText = ""
        #expect(model.visibleNotes.count == 3)
    }

    @Test func deletingSelectedNoteClearsSelectionAndPersists() async throws {
        let model = await makeModel()
        await model.createNote()
        let id = try #require(model.selectedNoteID)

        await model.deleteNote(id: id)
        #expect(model.selectedNoteID == nil)
        #expect(model.editor == nil)
        #expect(model.notes.isEmpty)
        #expect(try await store.allNotes().isEmpty)
        #expect(try await store.pendingChanges().map(\.kind) == [.delete])
    }

    @Test func failedDeleteIsPresentedAndNoteRemains() async throws {
        try await store.createNote(title: "keep me")
        let model = await makeModel()
        try await store.executeForTesting(failAllUpdatesTrigger)

        await model.deleteNote(id: try #require(model.notes.first).id)
        #expect(model.presentedError != nil)
        #expect(model.notes.map(\.title) == ["keep me"])
    }

    @Test func openReportsFailureForUnreadableDatabase() async throws {
        try Data("this is not a sqlite file, just some text padding it out".utf8)
            .write(to: directory.url.appending(path: "Bad.sqlite"))
        let model = NotesModel()
        await model.open(at: directory.url.appending(path: "Bad.sqlite"))
        guard case .failed = model.state else {
            Issue.record("Expected failed state, got \(model.state)")
            return
        }
    }
}
