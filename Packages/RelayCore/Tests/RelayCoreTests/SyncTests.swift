import Foundation
import os
import Testing
@testable import RelayCore

// SIMULATED SYNC: every test here runs against FakeCloud/FakeSyncEngine/
// FakeAccountProvider, not iCloud.

@Suite("Sync (simulated server)")
struct SyncTests {
    let cloud = FakeCloud()

    // MARK: Uploads

    @Test func uploadMarksNoteSyncedAndStoresServerMetadata() async throws {
        let device = try await SimulatedDevice("A", cloud: cloud)
        await device.start()
        let note = try await device.store.createNote(title: "Hello", body: "World")

        try await device.send()

        #expect(try await device.store.pendingChanges().isEmpty)
        #expect(await cloud.record(note.id)?.body == "World")
        #expect(try device.engine.pending.isEmpty)
        #expect(try await device.store.queryTextForTesting(
            "SELECT server_change_tag FROM notes WHERE id = '\(note.id.uuidString)'") == "tag-1")
    }

    @Test func olderUploadCompletingAfterNewerEditKeepsTheEditPending() async throws {
        let device = try await SimulatedDevice("A", cloud: cloud)
        await device.start()
        let note = try await device.store.createNote(title: "v1", body: "")

        let inFlight = try await device.beginSend()  // Uploading local_version 1…
        try await device.store.updateNote(id: note.id, title: "v2", body: "")  // …user edits (v2)…
        await device.finishSend(inFlight)  // …then the v1 upload succeeds.

        // v2 must still be pending and queued with the engine, not marked synced.
        #expect(try await device.store.pendingChanges().map(\.localVersion) == [2])
        #expect(try device.engine.pending == [note.id])
        #expect(await cloud.record(note.id)?.title == "v1")

        try await device.send()
        #expect(await cloud.record(note.id)?.title == "v2")
        #expect(try await device.store.pendingChanges().isEmpty)
    }

    @Test func retryAfterTransientFailureKeepsWorkAndDoesNotDuplicate() async throws {
        let device = try await SimulatedDevice("A", cloud: cloud)
        await device.start()
        let note = try await device.store.createNote(title: "t", body: "b")
        await cloud.failNextSaves(with: .transient(code: 4), count: 2)  // e.g. networkFailure

        for _ in 0..<2 {
            let batch = try await device.beginSend()
            let addsBefore = batch.engine.coordinatorAddedIDs.count
            await device.finishSend(batch)
            // Retrying is the engine's job. While handling a transient failure, the
            // coordinator must not re-queue the change itself, or there would be two
            // competing retry mechanisms.
            #expect(batch.engine.coordinatorAddedIDs.count == addsBefore)
            #expect(batch.engine.pending == [note.id])  // Kept by the (fake) engine.
        }
        #expect(try await device.store.pendingChanges().count == 1)
        #expect(await cloud.recordCount == 0)

        try await device.send()
        #expect(try await device.store.pendingChanges().isEmpty)
        #expect(await cloud.recordCount == 1)

        let other = try await SimulatedDevice("B", cloud: cloud)
        await other.start()
        try await other.sync()
        #expect(try await other.liveNotes.map(\.id) == [note.id])
    }

    @Test func nonRetryableFailureKeepsWorkWithoutRequeueing() async throws {
        let device = try await SimulatedDevice("A", cloud: cloud)
        await device.start()
        try await device.store.createNote(title: "t")
        await cloud.failNextSaves(with: .invalid(code: 12))

        try await device.send()

        // Still saved locally and still pending in the database. It isn't pushed back to
        // the engine, because resending the same data would fail the same way.
        #expect(try await device.store.pendingChanges().count == 1)
        #expect(try device.engine.pending.isEmpty)
    }

    // MARK: Applying remote changes

    @Test func remoteChangesAreNotUploadedAgain() async throws {
        let a = try await SimulatedDevice("A", cloud: cloud)
        let b = try await SimulatedDevice("B", cloud: cloud)
        await a.start()
        await b.start()
        let note = try await a.store.createNote(title: "From A", body: "x")
        try await a.sync()

        try await b.fetch()

        #expect(try await b.liveNotes.map(\.title) == ["From A"])
        #expect(try await b.store.pendingChanges().isEmpty)
        #expect(try b.engine.pending.isEmpty)
        try await b.send()
        #expect(await cloud.record(note.id)?.changeTag == "tag-1")  // B wrote nothing.
    }

    @Test func applyingTheSameFetchedChangeTwiceIsANoOp() async throws {
        let a = try await SimulatedDevice("A", cloud: cloud)
        await a.start()
        try await a.store.createNote(title: "once")
        try await a.sync()
        let (changes, _) = await cloud.changes(since: 0)

        let b = try await SimulatedDevice("B", cloud: cloud)
        await b.start()
        await b.coordinator.handleFetchedChanges(changes, from: try b.engine.eventSourceID)
        await b.coordinator.handleFetchedChanges(changes, from: try b.engine.eventSourceID)  // e.g. refetch

        #expect(try await b.liveNotes.count == 1)
        #expect(try await b.store.pendingChanges().isEmpty)
    }

    @Test func echoOfOwnUploadDoesNotConflictWithNewerLocalEdit() async throws {
        let a = try await SimulatedDevice("A", cloud: cloud)
        await a.start()
        let note = try await a.store.createNote(title: "v1")
        try await a.send()
        try await a.store.updateNote(id: note.id, title: "v2", body: "")

        try await a.fetch()  // Delivers A's own v1 save back to A.

        #expect(try await a.liveNotes.map(\.title) == ["v2"])  // No conflict copy.
        try await a.send()
        #expect(await cloud.record(note.id)?.title == "v2")
    }

    @Test func fetchedChangeForInFlightNoteIsLeftToTheSendResult() async throws {
        let a = try await SimulatedDevice("A", cloud: cloud)
        let b = try await SimulatedDevice("B", cloud: cloud)
        await a.start()
        await b.start()
        let note = try await a.store.createNote(title: "base")
        try await a.sync()
        try await b.sync()

        try await b.store.updateNote(id: note.id, title: "B edit", body: "")
        try await b.sync()
        try await a.store.updateNote(id: note.id, title: "A edit", body: "")
        let inFlight = try await a.beginSend()
        try await a.fetch()  // Sees B's edit while A's upload is in flight: deferred.
        #expect(try await a.liveNotes.map(\.title) == ["A edit"])

        await a.finishSend(inFlight)  // Fails with a conflict and resolves exactly once.
        #expect(contents(try await a.liveNotes) == ["A edit (Conflict copy)|", "B edit|"])
    }

    // MARK: Conflicts

    @Test func concurrentEditsPreserveBothVersionsOnBothDevices() async throws {
        let a = try await SimulatedDevice("A", cloud: cloud)
        let b = try await SimulatedDevice("B", cloud: cloud)
        await a.start()
        await b.start()
        let note = try await a.store.createNote(title: "Plan", body: "original")
        try await a.sync()
        try await b.sync()

        // Both edit "offline".
        try await a.store.updateNote(id: note.id, title: "Plan", body: "A's version")
        try await b.store.updateNote(id: note.id, title: "Plan", body: "B's version")
        try await a.sync()  // A reaches the server first, so A's version becomes primary.
        try await b.sync()  // B conflicts; B's version is kept as a copy and uploaded.
        try await a.sync()

        let expected = ["Plan (Conflict copy)|B's version", "Plan|A's version"]
        #expect(contents(try await a.liveNotes) == expected)
        #expect(contents(try await b.liveNotes) == expected)
        let copy = try #require(try await b.liveNotes.first { $0.conflictOf == note.id })
        #expect(try await a.liveNotes.contains { $0.id == copy.id && $0.conflictOf == note.id })
        #expect(try await a.store.pendingChanges().isEmpty)
        #expect(try await b.store.pendingChanges().isEmpty)
    }

    @Test func identicalConcurrentEditsDoNotCreateACopy() async throws {
        let a = try await SimulatedDevice("A", cloud: cloud)
        let b = try await SimulatedDevice("B", cloud: cloud)
        await a.start()
        await b.start()
        let note = try await a.store.createNote(title: "x", body: "")
        try await a.sync()
        try await b.sync()
        try await a.store.updateNote(id: note.id, title: "same", body: "same")
        try await b.store.updateNote(id: note.id, title: "same", body: "same")
        try await a.sync()
        try await b.sync()
        #expect(try await b.liveNotes.count == 1)
    }

    @Test func repeatedConflictHandlingDoesNotMultiplyCopies() async throws {
        let a = try await SimulatedDevice("A", cloud: cloud)
        let b = try await SimulatedDevice("B", cloud: cloud)
        await a.start()
        await b.start()
        let note = try await a.store.createNote(title: "n", body: "base")
        try await a.sync()
        try await b.sync()
        try await a.store.updateNote(id: note.id, title: "n", body: "A")
        try await a.sync()
        let server = try #require(await cloud.record(note.id))

        try await b.store.updateNote(id: note.id, title: "n", body: "B")
        // The same conflict result delivered repeatedly (retries, duplicate events).
        // The base is reset each time, as if the earlier handling had been lost in a crash.
        for _ in 0..<3 {
            try await b.store.executeForTesting("UPDATE notes SET body = 'B', local_version = local_version + 1, server_change_tag = 'tag-1' WHERE id = '\(note.id.uuidString)'")
            await b.coordinator.handleSendResults([.failed(id: note.id, .conflict(server: server))], from: try b.engine.eventSourceID)
        }
        try await b.sync()
        try await b.sync()

        #expect(try await b.liveNotes.filter { $0.conflictOf == note.id }.count == 1)
        #expect(await cloud.liveRecords.filter { $0.conflictOf == note.id }.count == 1)
    }

    @Test func identicalContentConflictingInUnrelatedNotesGetsDistinctCopies() async throws {
        let a = try await SimulatedDevice("A", cloud: cloud)
        let b = try await SimulatedDevice("B", cloud: cloud)
        await a.start()
        await b.start()
        let first = try await a.store.createNote(title: "one", body: "")
        let second = try await a.store.createNote(title: "two", body: "")
        try await a.sync()
        try await b.sync()

        // Both notes conflict, and B's losing content is identical in both.
        for note in [first, second] {
            try await a.store.updateNote(id: note.id, title: "A wins", body: "")
            try await b.store.updateNote(id: note.id, title: "TODO", body: "same text")
        }
        try await a.sync()
        try await b.sync()

        let copies = try await b.liveNotes.filter { $0.conflictOf != nil }
        #expect(copies.count == 2)
        #expect(Set(copies.compactMap(\.conflictOf)) == [first.id, second.id])
        #expect(Set(copies.map(\.id)).count == 2)
    }

    @Test func draftBasedOnStaleContentKeepsTheNewerVersionAsCopy() async throws {
        let directory = try TemporaryDirectory()
        let store = try NoteStore(url: directory.storeURL, now: steppingClock())
        let note = try await store.createNote(title: "t", body: "old")
        // A sync replaces the content while an editor still holds "old" as its base.
        try await store.executeForTesting("UPDATE notes SET body = 'synced from elsewhere' WHERE id = '\(note.id.uuidString)'")

        try await store.updateNote(id: note.id, title: "t", body: "my draft", base: ("t", "old"))
        try await store.updateNote(id: note.id, title: "t", body: "my draft 2", base: ("t", "my draft"))

        #expect(contents(try await store.allNotes()) == ["t (Conflict copy)|synced from elsewhere", "t|my draft 2"])
    }

    // MARK: Deletions

    @Test func remoteDeletionRemovesNoteAndLocalTombstoneIsPurgedAfterConfirmation() async throws {
        let a = try await SimulatedDevice("A", cloud: cloud)
        let b = try await SimulatedDevice("B", cloud: cloud)
        await a.start()
        await b.start()
        let note = try await a.store.createNote(title: "doomed")
        try await a.sync()
        try await b.sync()

        try await a.store.deleteNote(id: note.id)
        try await a.sync()

        // The server keeps a content-free tombstone. A's local tombstone is gone.
        #expect(await cloud.record(note.id)?.isDeleted == true)
        #expect(await cloud.record(note.id)?.body == "")
        #expect(try await a.store.queryIntForTesting("SELECT count(*) FROM notes") == 0)

        try await b.sync()
        #expect(try await b.liveNotes.isEmpty)
        #expect(try await b.store.queryIntForTesting("SELECT count(*) FROM notes") == 0)
    }

    @Test func editWinsWhenDeleteReachesServerSecond() async throws {
        let a = try await SimulatedDevice("A", cloud: cloud)
        let b = try await SimulatedDevice("B", cloud: cloud)
        await a.start()
        await b.start()
        let note = try await a.store.createNote(title: "keep?", body: "v1")
        try await a.sync()
        try await b.sync()

        try await a.store.deleteNote(id: note.id)  // A deletes offline.
        try await b.store.updateNote(id: note.id, title: "keep?", body: "B edited")
        try await b.sync()
        try await a.send()  // A's tombstone conflicts with B's edit, so the edit wins.

        #expect(try await a.liveNotes.map(\.body) == ["B edited"])
        #expect(try await a.store.pendingChanges().isEmpty)
        #expect(await cloud.record(note.id)?.isDeleted == false)
    }

    @Test(arguments: [true, false])
    func editWinsWhenDeleteReachesServerFirst(editorFetchesFirst: Bool) async throws {
        let a = try await SimulatedDevice("A", cloud: cloud)
        let b = try await SimulatedDevice("B", cloud: cloud)
        await a.start()
        await b.start()
        let note = try await a.store.createNote(title: "keep?", body: "v1")
        try await a.sync()
        try await b.sync()

        try await b.store.updateNote(id: note.id, title: "keep?", body: "B edited offline")
        try await a.store.deleteNote(id: note.id)
        try await a.sync()  // Tombstone is on the server.

        if editorFetchesFirst {
            try await b.sync()  // Sees the tombstone, keeps the edit, re-uploads over it.
        } else {
            try await b.send()  // Conflict with the tombstone, keeps the edit, retries.
            try await b.sync()
        }
        try await a.sync()

        #expect(try await a.liveNotes.map(\.body) == ["B edited offline"])
        #expect(try await b.liveNotes.map(\.body) == ["B edited offline"])
        #expect(await cloud.record(note.id)?.isDeleted == false)
    }

    @Test func hardDeletedRecordWithLocalEditIsRecreated() async throws {
        let a = try await SimulatedDevice("A", cloud: cloud)
        await a.start()
        let note = try await a.store.createNote(title: "t", body: "v1")
        try await a.sync()
        try await a.store.updateNote(id: note.id, title: "t", body: "v2")
        await cloud.hardDelete(note.id)

        try await a.send()  // Base refers to a missing record (unknownItem), so recreate it.
        try await a.send()

        #expect(await cloud.record(note.id)?.body == "v2")
        #expect(try await a.store.pendingChanges().isEmpty)
    }

    // MARK: Zone resets

    @Test func purgedZoneRemovesSyncedNotesButKeepsUnsyncedEdits() async throws {
        let a = try await SimulatedDevice("A", cloud: cloud)
        await a.start()
        try await a.store.createNote(title: "synced")
        try await a.sync()
        let unsynced = try await a.store.createNote(title: "unsynced")

        await a.coordinator.handleZoneDeleted(.deletedOrPurged, from: try a.engine.eventSourceID)

        #expect(try await a.liveNotes.map(\.title) == ["unsynced"])
        #expect(try a.engine.pending.contains(unsynced.id))
        #expect(try a.engine.zoneSaveCount >= 2)
    }

    @Test func encryptedDataResetQueuesEverythingForReupload() async throws {
        let a = try await SimulatedDevice("A", cloud: cloud)
        await a.start()
        try await a.store.createNote(title: "one")
        try await a.store.createNote(title: "two")
        try await a.sync()

        await a.coordinator.handleZoneDeleted(.encryptedDataReset, from: try a.engine.eventSourceID)

        #expect(try await a.store.pendingChanges().count == 2)
        #expect(try a.engine.pending.count == 2)
    }

    // MARK: Restart

    @Test func pendingWorkAndEngineStateSurviveRestart() async throws {
        let a = try await SimulatedDevice("A", cloud: cloud)
        await a.start()
        try await a.store.createNote(title: "synced")
        try await a.sync()
        let unsent = try await a.store.createNote(title: "unsent")
        let token = try a.engine.fetchToken

        try await a.relaunch()  // Process ended before "unsent" was sent.

        #expect(a.engineCount == 2)
        #expect(a.restoredState(ofEngine: 1) == Data(String(token).utf8))
        #expect(await a.coordinator.accountState == .active(user: "user-A"))
        #expect(try a.engine.pending == [unsent.id])
    }

    @Test(.timeLimit(.minutes(1)))
    func localEditsReachTheEngineThroughTheChangeStream() async throws {
        let device = try await SimulatedDevice("A", cloud: cloud)
        await device.start(observeLocalChanges: true)
        let engine = try device.engine
        var adds = engine.adds.makeAsyncIterator()
        _ = await adds.next()  // Drain the queue-at-start announcement.

        let note = try await device.store.createNote(title: "streamed")

        // Awaits the engine call itself, with no sleep and no polling.
        while let ids = await adds.next() {
            if ids.contains(note.id) { break }
        }
        #expect(engine.pending.contains(note.id))
    }
}
