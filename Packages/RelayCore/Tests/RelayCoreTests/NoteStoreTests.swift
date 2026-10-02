import Foundation
import Testing
@testable import RelayCore

@Suite("NoteStore")
struct NoteStoreTests {
    let directory: TemporaryDirectory

    init() throws {
        directory = try TemporaryDirectory()
    }

    private func makeStore() throws -> NoteStore {
        try NoteStore(url: directory.storeURL, now: steppingClock())
    }

    // MARK: CRUD

    @Test func createReadUpdateDelete() async throws {
        let store = try makeStore()

        let created = try await store.createNote(title: "Groceries", body: "Milk")
        #expect(try await store.note(id: created.id) == created)

        let updated = try await store.updateNote(id: created.id, title: "Groceries", body: "Milk\nEggs")
        #expect(updated.body == "Milk\nEggs")
        #expect(updated.modifiedAt > created.modifiedAt)
        #expect(try await store.note(id: created.id) == updated)

        try await store.deleteNote(id: created.id)
        #expect(try await store.note(id: created.id) == nil)
        #expect(try await store.allNotes().isEmpty)
    }

    @Test func listIsOrderedByMostRecentlyModified() async throws {
        let store = try makeStore()
        let first = try await store.createNote(title: "first")
        let second = try await store.createNote(title: "second")
        try await store.updateNote(id: first.id, title: "first, edited", body: "")

        let titles = try await store.allNotes().map(\.title)
        #expect(titles == ["first, edited", "second"])
        _ = second
    }

    @Test func textRoundTripsExactly() async throws {
        let store = try makeStore()
        let tricky = "emoji 👩🏽‍💻, combining é, quote ' \", nul \u{0} end"
        let note = try await store.createNote(title: tricky, body: tricky)
        #expect(try await store.note(id: note.id)?.body == tricky)
        #expect(try await store.note(id: note.id)?.title == tricky)
    }

    @Test func updatingDeletedNoteThrowsNotFound() async throws {
        let store = try makeStore()
        let note = try await store.createNote(title: "x")
        try await store.deleteNote(id: note.id)

        await #expect(throws: StoreError.noteNotFound(note.id)) {
            try await store.updateNote(id: note.id, title: "y", body: "")
        }
    }

    // MARK: Durability

    @Test func notesPersistAcrossReopen() async throws {
        let store = try makeStore()
        let kept = try await store.createNote(title: "Kept", body: "body")
        let edited = try await store.updateNote(id: kept.id, title: "Kept", body: "edited body")
        let gone = try await store.createNote(title: "Gone")
        try await store.deleteNote(id: gone.id)
        await store.close()

        let reopened = try makeStore()
        #expect(try await reopened.allNotes() == [edited])
    }

    @Test func pendingChangesSurviveReopen() async throws {
        let store = try makeStore()
        let saved = try await store.createNote(title: "A")
        try await store.updateNote(id: saved.id, title: "A2", body: "")
        let deleted = try await store.createNote(title: "B")
        try await store.deleteNote(id: deleted.id)
        await store.close()

        let reopened = try makeStore()
        let pending = try await reopened.pendingChanges()
        #expect(Set(pending.map(\.noteID)) == [saved.id, deleted.id])
        #expect(pending.first { $0.noteID == saved.id }?.kind == .save)
        #expect(pending.first { $0.noteID == saved.id }?.localVersion == 2)
        #expect(pending.first { $0.noteID == deleted.id }?.kind == .delete)
    }

    @Test func deletedNoteContentIsNotRetained() async throws {
        let store = try makeStore()
        let note = try await store.createNote(title: "secret", body: "secret body")
        try await store.deleteNote(id: note.id)
        await store.close()

        let reopened = try makeStore()
        // The tombstone exists only as pending work; nothing readable remains.
        #expect(try await reopened.note(id: note.id) == nil)
        #expect(try await reopened.pendingChanges().map(\.kind) == [.delete])
    }

    // MARK: Idempotence

    @Test func identicalUpdateCreatesNoNewPendingVersion() async throws {
        let store = try makeStore()
        let note = try await store.createNote(title: "same", body: "same")
        let first = try await store.updateNote(id: note.id, title: "same", body: "same")
        let second = try await store.updateNote(id: note.id, title: "same", body: "same")

        #expect(first == note)
        #expect(second == note)
        #expect(try await store.pendingChanges().map(\.localVersion) == [1])
    }

    @Test func repeatedDeleteIsANoOp() async throws {
        let store = try makeStore()
        let note = try await store.createNote(title: "x")
        try await store.deleteNote(id: note.id)
        try await store.deleteNote(id: note.id)
        try await store.deleteNote(id: UUID())  // Unknown id: also a no-op.

        let pending = try await store.pendingChanges()
        #expect(pending.count == 1)
        #expect(pending.first?.localVersion == 2)  // Create (1) + one delete (2).
    }

    // MARK: Failures

    @Test func failedWriteLeavesNoteAndPendingStateUnchanged() async throws {
        let store = try makeStore()
        let note = try await store.createNote(title: "original", body: "original")
        let pendingBefore = try await store.pendingChanges()

        try await store.executeForTesting(failAllUpdatesTrigger)

        let updateError = await #expect(throws: StoreError.self) {
            try await store.updateNote(id: note.id, title: "new", body: "new")
        }
        guard case .sqlite = updateError else {
            Issue.record("Expected a SQLite error, got \(String(describing: updateError))")
            return
        }
        await #expect(throws: StoreError.self) {
            try await store.deleteNote(id: note.id)
        }

        #expect(try await store.note(id: note.id) == note)
        #expect(try await store.pendingChanges() == pendingBefore)

        // The store stays usable once the fault clears: the failed transaction was
        // rolled back, not left open.
        try await store.executeForTesting(removeFailureTrigger)
        let updated = try await store.updateNote(id: note.id, title: "new", body: "new")
        #expect(updated.title == "new")
    }

    @Test func databaseFromNewerSchemaIsRefusedAndLeftIntact() async throws {
        let store = try makeStore()
        let note = try await store.createNote(title: "from the future")
        try await store.executeForTesting("PRAGMA user_version = 99")
        await store.close()

        #expect(throws: StoreError.unsupportedSchemaVersion(found: 99, supported: Schema.currentVersion)) {
            _ = try makeStore()
        }

        // Prove the file was not modified: put the version back and read the note.
        let raw = try SQLiteConnection(url: directory.storeURL)
        try raw.setUserVersion(Schema.currentVersion)
        raw.close()
        #expect(try await makeStore().note(id: note.id)?.title == "from the future")
    }

    @Test func usingClosedStoreThrowsClosed() async throws {
        let store = try makeStore()
        await store.close()
        await #expect(throws: StoreError.closed) {
            try await store.allNotes()
        }
    }

    @Test func openCreatesMissingDirectory() async throws {
        let nested = directory.url.appending(path: "a/b/Notes.sqlite")
        let store = try await NoteStore.open(at: nested)
        #expect(try await store.allNotes().isEmpty)
    }
}
