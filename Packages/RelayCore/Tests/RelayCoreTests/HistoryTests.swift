import Foundation
import Testing
@testable import RelayCore

@Suite("Revision history (local SQLite)")
struct RevisionHistoryTests {
    let directory: TemporaryDirectory
    let store: NoteStore

    init() throws {
        directory = try TemporaryDirectory()
        store = try NoteStore(url: directory.storeURL, now: steppingClock())
    }

    private func history(_ id: UUID, in store: NoteStore? = nil) async throws -> [Revision] {
        try await (store ?? self.store).revisionHistory(of: id).revisions
    }

    @Test func checkpointsSurviveRestart() async throws {
        let note = try await store.createNote(title: "Deploy", body: "make deploy\nmake verify", kind: .template)
        let result = try await store.saveCheckpoint(of: note.id)
        guard case .saved = result else { Issue.record("expected a saved revision, got \(result)"); return }
        await store.close()

        let reopened = try NoteStore(url: directory.storeURL)
        let revisions = try await history(note.id, in: reopened)
        #expect(revisions.map(\.content) == [NoteContent(title: "Deploy", body: "make deploy\nmake verify", kind: .template)])
        #expect(revisions.map(\.reason) == [.checkpoint])
    }

    @Test func identicalConsecutiveCheckpointsAreNoOps() async throws {
        let note = try await store.createNote(title: "t", body: "v1")
        _ = try await store.saveCheckpoint(of: note.id)
        #expect(try await store.saveCheckpoint(of: note.id) == .unchanged)
        try await store.updateNote(id: note.id, title: "t", body: "v2")
        guard case .saved = try await store.saveCheckpoint(of: note.id) else { Issue.record("expected saved"); return }
        #expect(try await history(note.id).map(\.content.body) == ["v2", "v1"])
    }

    @Test func historyKeepsOnlyTheNewestRevisionsPerEntry() async throws {
        let note = try await store.createNote(title: "t", body: "0")
        let other = try await store.createNote(title: "other", body: "keep me")
        _ = try await store.saveCheckpoint(of: other.id)
        let total = NoteStore.revisionLimit + 5
        for version in 1...total {
            try await store.updateNote(id: note.id, title: "t", body: "\(version)")
            _ = try await store.saveCheckpoint(of: note.id)
        }
        let bodies = try await history(note.id).map(\.content.body)
        #expect(bodies.count == NoteStore.revisionLimit)
        #expect(bodies.first == "\(total)")  // Newest kept…
        #expect(bodies.last == "\(total - NoteStore.revisionLimit + 1)")  // …oldest pruned.
        #expect(try await history(other.id).count == 1)  // Pruning is per entry.
    }

    @Test func restoreFailureRollsBackEverything() async throws {
        let note = try await store.createNote(title: "t", body: "old")
        _ = try await store.saveCheckpoint(of: note.id)
        try await store.updateNote(id: note.id, title: "t", body: "current")
        let revision = try #require(try await history(note.id).first)
        let pendingBefore = try await store.pendingChanges()

        try await store.executeForTesting(failAllUpdatesTrigger)  // The UPDATE of the entry fails.
        await #expect(throws: StoreError.self) { try await store.restore(revision: revision.id, of: note.id) }
        try await store.executeForTesting(removeFailureTrigger)

        // No recovery checkpoint, no content change, no extra pending work.
        #expect(try await history(note.id).map(\.content.body) == ["old"])
        #expect(try await store.note(id: note.id)?.body == "current")
        #expect(try await store.pendingChanges() == pendingBefore)
    }

    @Test func restoringADeletedEntryOrAForeignRevisionIsRejected() async throws {
        let note = try await store.createNote(title: "t", body: "v1")
        let other = try await store.createNote(title: "other", body: "x")
        _ = try await store.saveCheckpoint(of: other.id)
        let foreign = try #require(try await history(other.id).first)
        await #expect(throws: StoreError.revisionNotFound) { try await store.restore(revision: foreign.id, of: note.id) }

        _ = try await store.saveCheckpoint(of: note.id)
        let revision = try #require(try await history(note.id).first)
        try await store.deleteNote(id: note.id)
        await #expect(throws: StoreError.noteNotFound(note.id)) { try await store.restore(revision: revision.id, of: note.id) }
        // The history went with the entry (deleted in the same transaction).
        #expect(try await store.queryIntForTesting(
            "SELECT COUNT(*) FROM note_revisions WHERE note_id = '\(note.id.uuidString)'") == 0)
    }

    @Test func restoringTheCurrentContentChangesNothing() async throws {
        let note = try await store.createNote(title: "t", body: "same")
        _ = try await store.saveCheckpoint(of: note.id)
        let revision = try #require(try await history(note.id).first)
        let versionBefore = try await store.pendingChanges().first?.localVersion
        try await store.restore(revision: revision.id, of: note.id)
        #expect(try await store.pendingChanges().first?.localVersion == versionBefore)
        #expect(try await history(note.id).count == 1)
    }
}

/// Restore is a new local edit on the normal sync path. SIMULATED server.
@Suite("Revision restore and simulated sync")
struct RestoreSyncTests {
    @Test func restoreKeepsTheCurrentVersionAndUploadsTheRestoredOne() async throws {
        let cloud = FakeCloud()
        let device = try await SimulatedDevice("A", cloud: cloud)
        await device.start()
        let note = try await device.store.createNote(title: "Release", body: "git tag {{version}}", kind: .template)
        _ = try await device.store.saveCheckpoint(of: note.id)
        try await device.store.updateNote(id: note.id, title: "Release", body: "git tag v2\ngit push --tags", kind: .snippet)
        try await device.sync()
        let syncedTag = try #require(await cloud.record(note.id)?.changeTag)
        let versionBefore = try #require(try await device.store.queryIntForTesting(
            "SELECT local_version FROM notes WHERE id = '\(note.id.uuidString)'"))
        #expect(try await device.store.pendingChanges().isEmpty)

        let checkpoint = try #require(try await device.store.revisionHistory(of: note.id).revisions.first)
        try await device.store.restore(revision: checkpoint.id, of: note.id)

        // A new pending local edit: the counter moved forward, never back.
        let snapshot = try #require(try await device.store.uploadSnapshot(id: note.id))
        #expect(snapshot.localVersion == versionBefore + 1)
        #expect(snapshot.kind == .template)
        // The version it replaced is kept as a recovery checkpoint.
        let revisions = try await device.store.revisionHistory(of: note.id).revisions
        #expect(revisions.first?.reason == .beforeRestore)
        #expect(revisions.first?.content.body == "git tag v2\ngit push --tags")

        // It uploads on top of the latest server version: no conflict, no copy.
        try await device.sync()
        #expect(try await device.store.pendingChanges().isEmpty)
        #expect(await cloud.record(note.id)?.body == "git tag {{version}}")
        #expect(await cloud.record(note.id)?.kind == .template)
        #expect(await cloud.record(note.id)?.changeTag != syncedTag)
        #expect(try await device.liveNotes.count == 1)
    }
}

@MainActor
@Suite("History sheet model")
struct RevisionHistoryModelTests {
    @Test func restoreSavesTheDraftFirstAndUpdatesTheEditor() async throws {
        let directory = try TemporaryDirectory()
        let store = try NoteStore(url: directory.storeURL, now: steppingClock())
        let note = try await store.createNote(title: "t", body: "v1")
        let editor = NoteEditorModel(note: note, store: store, autosaveDelay: .seconds(3600), onSaved: { _ in })
        #expect(await editor.saveVersion() == .saved)
        #expect(await editor.saveVersion() == .unchanged)

        editor.body = "unsaved draft"  // Typed but not yet autosaved.
        let history = editor.makeHistory()
        await history.load()
        #expect(history.revisions.count == 1)
        #expect(await history.restoreSelected())

        #expect(editor.body == "v1")
        #expect(!editor.hasUnsavedChanges)
        // The draft was saved first, then preserved by the recovery checkpoint.
        #expect(history.revisions.map(\.content.body) == ["unsaved draft", "v1"])
        #expect(history.current?.body == "v1")
    }
}

@Suite("Line diff (pure)")
struct LineDiffTests {
    typealias Line = LineDiff.Line

    @Test func identicalTextIsAllUnchanged() {
        #expect(LineDiff.compare(old: "a\nb", new: "a\nb") == [Line(change: .unchanged, text: "a"), Line(change: .unchanged, text: "b")])
    }

    @Test func insertionsAndDeletionsAppearInPlace() {
        #expect(LineDiff.compare(old: "a\nc", new: "a\nb\nc") == [
            Line(change: .unchanged, text: "a"), Line(change: .added, text: "b"), Line(change: .unchanged, text: "c"),
        ])
        #expect(LineDiff.compare(old: "a\nb\nc", new: "a\nc") == [
            Line(change: .unchanged, text: "a"), Line(change: .removed, text: "b"), Line(change: .unchanged, text: "c"),
        ])
    }

    @Test func aChangedLineIsARemovalThenAnAddition() {
        #expect(LineDiff.compare(old: "ssh {{host}}\nexit", new: "ssh -p 2222 {{host}}\nexit") == [
            Line(change: .removed, text: "ssh {{host}}"), Line(change: .added, text: "ssh -p 2222 {{host}}"),
            Line(change: .unchanged, text: "exit"),
        ])
    }

    @Test func emptyTexts() {
        #expect(LineDiff.compare(old: "", new: "").isEmpty)
        #expect(LineDiff.compare(old: "", new: "x\ny") == [Line(change: .added, text: "x"), Line(change: .added, text: "y")])
        #expect(LineDiff.compare(old: "x", new: "") == [Line(change: .removed, text: "x")])
        // A trailing newline is a change you can see.
        #expect(LineDiff.compare(old: "x", new: "x\n") == [Line(change: .unchanged, text: "x"), Line(change: .added, text: "")])
    }
}
