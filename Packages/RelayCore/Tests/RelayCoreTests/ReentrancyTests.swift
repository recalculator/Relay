import Foundation
import os
import Testing
@testable import RelayCore

// SIMULATED: FakeCloud / FakeSyncEngine / FakeAccountProvider.
//
// `SyncCoordinator` is an actor, and actors are reentrant: while one call is suspended
// at an `await`, another call can run on the same actor. These tests stop the
// coordinator at a known `await` (a `Checkpoint`), run an account change or database
// replacement there, then let the first call continue. No sleeps or timing: the pause
// and its release are explicit.
//
// They show that Relay's logic holds up under these interleavings. They don't show
// what order real CKSyncEngine delivers events in (see ARCHITECTURE.md).

/// Suspends the coordinator the first time it reaches `target`, until `release()`.
final class CheckpointPause: Sendable {
    private let target: SyncCoordinator.Checkpoint
    private let armed = OSAllocatedUnfairLock(initialState: true)
    private let sleeper = ManualSleeper()
    private let reachedStream: AsyncStream<Void>
    private let reachedContinuation: AsyncStream<Void>.Continuation

    init(at target: SyncCoordinator.Checkpoint) {
        self.target = target
        (reachedStream, reachedContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    var hook: @Sendable (SyncCoordinator.Checkpoint) async -> Void {
        { [self] checkpoint in
            guard checkpoint == target else { return }
            let first = armed.withLock { armed in
                defer { armed = false }
                return armed
            }
            guard first else { return }
            reachedContinuation.yield()
            try? await sleeper.sleep(.zero)
        }
    }

    /// Returns once the coordinator is suspended at the checkpoint.
    func waitUntilReached() async {
        var iterator = reachedStream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release() { sleeper.release() }
}

@Suite("Reentrancy: changes while a sync operation is suspended")
struct ReentrancyTests {
    let cloud = FakeCloud()

    /// Another device of user A uploads `titles`, so `cloud` holds them as changes.
    private func uploadFromAnotherDevice(_ titles: [String]) async throws {
        let other = try await SimulatedDevice("other", cloud: cloud)
        await other.start()
        for title in titles { try await other.store.createNote(title: title) }
        try await other.sync()
    }

    @Test func fetchedBatchStopsWhenTheDatabaseIsReplacedPartWay() async throws {
        try await uploadFromAnotherDevice(["first", "second", "third"])
        let device = try await SimulatedDevice("A", cloud: cloud)
        await device.start()
        let engine = try device.engine
        let (changes, _) = await cloud.changes(since: 0)
        #expect(changes.count == 3)

        let pause = CheckpointPause(at: .appliedFetchedChange)
        await device.coordinator.setCheckpointForTesting(pause.hook)
        let coordinator = device.coordinator, source = engine.eventSourceID
        let fetch = Task { await coordinator.handleFetchedChanges(changes, from: source) }
        await pause.waitUntilReached()  // One change applied; the batch is suspended.

        // The account switches to B, and the user starts B's fresh database.
        try await device.switchAccount(to: "user-B")
        let freshDirectory = try TemporaryDirectory()
        let fresh = try NoteStore(url: freshDirectory.storeURL)
        try await device.coordinator.startFresh(with: fresh)
        #expect(await device.coordinator.accountState == .active(user: "user-B"))

        pause.release()
        await fetch.value

        // None of user A's remaining changes reached user B's database…
        #expect(try await fresh.allNotes().isEmpty)
        // …and none were applied to A's database after its engine stopped either.
        #expect(try await device.store.allNotes().count == 1)
    }

    @Test func sendResultsStopApplyingWhenTheAccountChangesPartWay() async throws {
        let device = try await SimulatedDevice("A", cloud: cloud)
        await device.start()
        try await device.store.createNote(title: "one")
        try await device.store.createNote(title: "two")
        let batch = try await device.beginSend()
        #expect(batch.snapshots.count == 2)
        var results: [SendResult] = []
        for snapshot in batch.snapshots { results.append(await cloud.save(snapshot)) }

        let pause = CheckpointPause(at: .appliedSendResult)
        await device.coordinator.setCheckpointForTesting(pause.hook)
        let coordinator = device.coordinator, source = batch.engine.eventSourceID, sent = results
        let delivery = Task { await coordinator.handleSendResults(sent, from: source) }
        await pause.waitUntilReached()  // First result recorded; the rest are suspended.

        try await device.switchAccount(to: "user-B")
        pause.release()
        await delivery.value

        // The second result arrived after the engine stopped, so it wasn't recorded:
        // the row is still pending and has no server metadata.
        #expect(try await device.store.pendingChanges().count == 1)
        #expect(try await device.store.queryIntForTesting(
            "SELECT COUNT(*) FROM notes WHERE server_change_tag IS NOT NULL") == 1)

        // Back on user A, the pending note reconciles without a duplicate or a copy.
        try await device.switchAccountBack(to: "user-A")
        try await device.sync()
        #expect(try await device.store.pendingChanges().isEmpty)
        #expect(contents(try await device.liveNotes) == ["one|", "two|"])
        #expect(await cloud.recordCount == 2)
    }

    @Test func lateResultsFromAStoppedEngineLeaveTheNewEnginesUploadAlone() async throws {
        let device = try await SimulatedDevice("A", cloud: cloud)
        await device.start()
        try await device.store.createNote(title: "one")
        try await device.store.createNote(title: "two")
        let batch = try await device.beginSend()
        var results: [SendResult] = []
        for snapshot in batch.snapshots { results.append(await cloud.save(snapshot)) }
        #expect(results.count == 2)
        // Batch order is arbitrary. `late` is the note whose result is delivered second.
        guard case .saved(let lateRecord) = results[1] else { Issue.record("save failed"); return }
        let late = lateRecord.id

        let pause = CheckpointPause(at: .appliedSendResult)
        await device.coordinator.setCheckpointForTesting(pause.hook)
        let coordinator = device.coordinator, source = batch.engine.eventSourceID, sent = results
        let delivery = Task { await coordinator.handleSendResults(sent, from: source) }
        await pause.waitUntilReached()

        // The account changes and changes back: engine 2 starts uploading `late`.
        try await device.switchAccount(to: "user-B")
        try await device.switchAccountBack(to: "user-A")
        let secondBatch = try await device.beginSend()
        #expect(secondBatch.snapshots.map(\.id) == [late])
        let sentVersion = await coordinator.inFlightVersion(for: late)
        #expect(sentVersion != nil)

        pause.release()
        await delivery.value

        // Engine 1's late result for `late` must not consume engine 2's in-flight entry.
        #expect(await coordinator.inFlightVersion(for: late) == sentVersion)
        await device.finishSend(secondBatch)
        #expect(try await device.store.pendingChanges().isEmpty)
        #expect(contents(try await device.liveNotes) == ["one|", "two|"])
        #expect(await cloud.recordCount == 2)
    }

    @Test func syncNowDoesNotRestartSyncAfterTheAccountChangedWhileItWaited() async throws {
        try await uploadFromAnotherDevice(["redeliver me"])
        let device = try await SimulatedDevice("A", cloud: cloud)
        await device.start()
        // Make one fetched change fail to apply, so Sync Now recreates the engine.
        try await device.store.executeForTesting("""
            CREATE TRIGGER fail_inserts BEFORE INSERT ON notes
            BEGIN SELECT RAISE(ABORT, 'injected test failure'); END;
            """)
        try await device.fetch()
        try await device.store.executeForTesting("DROP TRIGGER fail_inserts;")

        let pause = CheckpointPause(at: .readSavedStateForSyncNow)
        await device.coordinator.setCheckpointForTesting(pause.hook)
        let coordinator = device.coordinator
        let syncNow = Task { await coordinator.syncNow() }
        await pause.waitUntilReached()

        // CKAccountChanged: the device is now signed in to user B.
        device.accounts.account = .available(user: "user-B")
        await device.coordinator.accountMayHaveChanged()
        #expect(await device.coordinator.accountState == .mismatch(bound: "user-A", current: "user-B"))

        pause.release()
        await syncNow.value

        // Sync Now must not start an engine for user A's database while B is signed in.
        #expect(await device.coordinator.accountState == .mismatch(bound: "user-A", current: "user-B"))
        #expect(device.engineCount == 1)
    }

    @Test func accountResolutionInFlightIsAbandonedWhenADatabaseIsStartedFresh() async throws {
        let device = try await SimulatedDevice("A", cloud: cloud)
        await device.start()
        try await device.switchAccount(to: "user-B")
        #expect(device.engineCount == 1)

        // A CKAccountChanged check is suspended waiting for the account…
        let gate = ManualSleeper()
        device.accounts.gate.withLock { $0 = gate }
        let coordinator = device.coordinator
        let check = Task { await coordinator.accountMayHaveChanged() }
        var requests = gate.requests.makeAsyncIterator()
        _ = await requests.next()
        device.accounts.gate.withLock { $0 = nil }

        // …while the user starts B's fresh database.
        let freshDirectory = try TemporaryDirectory()
        try await device.coordinator.startFresh(with: try NoteStore(url: freshDirectory.storeURL))
        #expect(device.engineCount == 2)

        gate.release()
        await check.value

        // The stale check doesn't replace the fresh database's engine.
        #expect(device.engineCount == 2)
        #expect(await device.coordinator.accountState == .active(user: "user-B"))
    }
}

@Suite("Reentrancy: the store's sync-session fence")
struct SyncFenceTests {
    /// The coordinator's own checks can't cover a write that was already queued on the
    /// store when its engine stopped. The store checks the fence inside the write's
    /// transaction, so such a write changes nothing.
    @Test func writesFromAnEndedSessionOrAnotherOwnerChangeNothing() async throws {
        let directory = try TemporaryDirectory()
        let store = try NoteStore(url: directory.storeURL, now: steppingClock())
        try await store.bindAccount("user-A")
        let note = try await store.createNote(title: "local", body: "pending")
        let server = RemoteNote(id: note.id, title: "server", body: "", createdAt: .now, modifiedAt: .now,
                                changeTag: "t1", systemFields: Data("t1".utf8))
        let newNote = RemoteNote(id: UUID(), title: "new", body: "", createdAt: .now, modifiedAt: .now,
                                 changeTag: "t2", systemFields: Data("t2".utf8))

        let session = store.beginSyncSession(owner: "user-A")
        try await store.saveEngineState(Data("state-1".utf8), fence: session)
        store.endSyncSession()  // The engine stops.

        await #expect(throws: StoreError.staleSyncOperation) { try await store.applyRemote(.modified(newNote), fence: session) }
        await #expect(throws: StoreError.staleSyncOperation) { try await store.markUploaded(server, sentVersion: 1, fence: session) }
        await #expect(throws: StoreError.staleSyncOperation) { try await store.clearServerMetadata(id: note.id, fence: session) }
        await #expect(throws: StoreError.staleSyncOperation) { try await store.handleZoneDeleted(.deletedOrPurged, fence: session) }
        await #expect(throws: StoreError.staleSyncOperation) { try await store.saveEngineState(Data("state-2".utf8), fence: session) }

        // A current session for an account that doesn't own the database is refused too.
        let otherOwner = store.beginSyncSession(owner: "user-B")
        await #expect(throws: StoreError.staleSyncOperation) { try await store.applyRemote(.modified(newNote), fence: otherOwner) }

        #expect(try await store.allNotes().map(\.title) == ["local"])
        #expect(try await store.pendingChanges().map(\.noteID) == [note.id])
        #expect(try await store.engineState() == Data("state-1".utf8))

        // The owner's current session still writes normally.
        let current = store.beginSyncSession(owner: "user-A")
        try await store.applyRemote(.modified(newNote), fence: current)
        #expect(try await store.note(id: newNote.id)?.title == "new")
    }
}
