import Foundation
import Testing
@testable import RelayCore

// SIMULATED: FakeAccountProvider / FakeSyncEngine / FakeCloud. These tests check Relay's
// account-gating logic against a model of CKSyncEngine's documented lifecycle, not
// against iCloud itself.

private func remoteNote(_ title: String, tag: String) -> RemoteNote {
    RemoteNote(id: UUID(), title: title, body: "", createdAt: .now, modifiedAt: .now,
               changeTag: tag, systemFields: Data(tag.utf8))
}

@Suite("Account lifecycle: startup ownership validation")
struct StartupOwnershipTests {
    let cloud = FakeCloud()

    @Test func noEngineExistsUntilTheAccountIsKnown() async throws {
        let device = try await SimulatedDevice("A", cloud: cloud, account: .couldNotDetermine(reason: "offline"))
        try await device.store.createNote(title: "offline note")

        await device.start()

        #expect(device.engineCount == 0)
        #expect(await device.coordinator.accountState == .waitingForAccount)
        #expect(try await device.store.boundAccount() == nil)
    }

    @Test func firstAccountAdoptsLocalNotesWithFreshEngine() async throws {
        let device = try await SimulatedDevice("A", cloud: cloud)
        let note = try await device.store.createNote(title: "made before sign-in")

        await device.start()

        #expect(try await device.store.boundAccount() == "user-A")
        #expect(device.restoredState(ofEngine: 0) == nil)
        try await device.send()
        #expect(await cloud.record(note.id) != nil)
    }

    @Test func ownerAccountGetsEngineFromItsPersistedState() async throws {
        let device = try await SimulatedDevice("A", cloud: cloud)
        await device.start()
        try await device.store.createNote(title: "x")
        try await device.sync()
        let token = try device.engine.fetchToken

        try await device.relaunch()

        #expect(device.restoredState(ofEngine: 1) == Data(String(token).utf8))
    }

    @Test func differentAccountAtLaunchIsAMismatchWithoutAnyEngine() async throws {
        let device = try await SimulatedDevice("A", cloud: cloud)
        await device.start()
        try await device.store.createNote(title: "A's note")
        try await device.sync()

        device.accounts.account = .available(user: "user-B")  // Changed while the app was quit.
        try await device.relaunch()

        #expect(await device.coordinator.accountState == .mismatch(bound: "user-A", current: "user-B"))
        #expect(device.engineCount == 1)  // Only the engine from the first launch.
        #expect(try await device.store.boundAccount() == "user-A")
    }

    @Test func benignSignInFromFreshEngineDoesNotRestartIt() async throws {
        // A fresh engine (nil state) may announce the current user. It must not be
        // mistaken for an account change, or every start would loop.
        let device = try await SimulatedDevice("A", cloud: cloud)
        await device.start()
        let engine = try device.engine
        let note = try await device.store.createNote(title: "pending")

        await device.coordinator.handleAccountChange(.signIn(user: "user-A"), from: engine.eventSourceID)

        #expect(device.engineCount == 1)
        #expect(!engine.wasCancelled)
        #expect(engine.pending.contains(note.id))  // Re-queued after the engine's reset.
    }

    @Test func temporarilyUnavailableWaitsForAccountChangedWithoutRetrying() async throws {
        let device = try await SimulatedDevice("A", cloud: cloud, account: .temporarilyUnavailable)
        await device.start()
        #expect(await device.coordinator.accountState == .waitingForAccount)
        #expect(await device.coordinator.pendingAccountRetry == nil)  // Apple: wait for CKAccountChanged.

        device.accounts.account = .available(user: "user-A")
        await device.coordinator.accountMayHaveChanged()  // CKAccountChanged posted.
        #expect(await device.coordinator.accountState == .active(user: "user-A"))
        #expect(device.engineCount == 1)
    }

    @Test func undeterminedAccountIsRetriedWithBackoff() async throws {
        let device = try await SimulatedDevice("A", cloud: cloud, account: .couldNotDetermine(reason: "offline"))
        var requests = device.sleeper.requests.makeAsyncIterator()
        await device.start()
        #expect(await requests.next() == .seconds(15))

        let firstRetry = await device.coordinator.pendingAccountRetry
        device.sleeper.release()  // First retry: still offline.
        await firstRetry?.value
        #expect(await requests.next() == .seconds(30))  // Backoff doubled.
        #expect(device.engineCount == 0)

        device.accounts.account = .available(user: "user-A")
        let secondRetry = await device.coordinator.pendingAccountRetry
        device.sleeper.release()  // Second retry succeeds.
        await secondRetry?.value
        #expect(await device.coordinator.accountState == .active(user: "user-A"))
        #expect(device.engineCount == 1)
    }
}

extension StartupOwnershipTests {
    @Test func overlappingResolutionsCreateExactlyOneEngine() async throws {
        // Launch, the foreground re-check, and CKAccountChanged can all resolve the
        // account at once. Force two resolutions to be suspended at the same time.
        let device = try await SimulatedDevice("A", cloud: cloud)
        await device.start()  // Binds the database to user A (engine 1).
        device.accounts.account = .temporarilyUnavailable
        try await device.relaunch()  // Owned by A, waiting for the account. No engine.
        #expect(device.engineCount == 1)
        device.accounts.account = .available(user: "user-A")
        let gate = ManualSleeper()
        device.accounts.gate.withLock { $0 = gate }
        var waiting = gate.requests.makeAsyncIterator()

        let coordinator = device.coordinator  // An actor: safe to share between tasks.
        async let first: Void = coordinator.accountMayHaveChanged()
        async let second: Void = coordinator.accountMayHaveChanged()
        _ = await waiting.next()
        _ = await waiting.next()  // Both are now suspended mid-resolution.
        gate.release()
        gate.release()
        _ = await (first, second)

        await device.coordinator.waitForEngineTeardowns()
        #expect(await device.coordinator.accountState == .active(user: "user-A"))
        #expect(device.engineCount == 2)  // Exactly one new engine for this launch.
        #expect(try !device.engine.wasCancelled)
    }

    @Test func accountChecksBeforeStartAreIgnored() async throws {
        let device = try await SimulatedDevice("A", cloud: cloud)
        await device.coordinator.revalidateAccount()  // e.g. foreground before launch finished
        #expect(device.accounts.queryCount == 0)
        #expect(try await device.store.boundAccount() == nil)
    }
}

@Suite("Account lifecycle: events before initialization")
struct EarlyEventTests {
    let cloud = FakeCloud()

    @Test func eventsArrivingBeforeAnEngineExistsChangeNothing() async throws {
        let device = try await SimulatedDevice("A", cloud: cloud, account: .couldNotDetermine(reason: "offline"))
        let local = try await device.store.createNote(title: "local")
        await device.start()
        // Something delivers events while no engine exists: a stray engine, or a late
        // callback. They must not be applied, persisted, or answered with uploads.
        let stray = FakeSyncEngine()
        let foreign = remoteNote("from somewhere", tag: "x1")

        await device.coordinator.handleFetchedChanges([.modified(foreign)], from: stray.eventSourceID)
        await device.coordinator.handleEngineStateUpdate(Data("99".utf8), from: stray.eventSourceID)
        await device.coordinator.handleAccountChange(.signIn(user: "user-B"), from: stray.eventSourceID)
        #expect(await device.coordinator.snapshotForUpload(local.id, from: stray.eventSourceID) == nil)
        await device.coordinator.handleSendResults([.saved(foreign)], from: stray.eventSourceID)

        #expect(try await device.liveNotes.map(\.title) == ["local"])
        #expect(try await device.store.engineState() == nil)
        #expect(try await device.store.boundAccount() == nil)
        #expect(await device.coordinator.accountState == .waitingForAccount)
    }

    @Test func changesFromBeforeInitializationAreFetchedOnceTheAccountIsKnown() async throws {
        // Another device already uploaded a note.
        let other = try await SimulatedDevice("B", cloud: cloud)
        await other.start()
        try await other.store.createNote(title: "already in iCloud")
        try await other.sync()

        let device = try await SimulatedDevice("A", cloud: cloud, account: .couldNotDetermine(reason: "offline"))
        await device.start()
        #expect(device.engineCount == 0)

        device.accounts.account = .available(user: "user-A")
        let retry = await device.coordinator.pendingAccountRetry
        device.sleeper.release()
        await retry?.value
        try await device.fetch()

        #expect(try await device.liveNotes.map(\.title) == ["already in iCloud"])
    }
}

@Suite("Account lifecycle: account changes during operations")
struct MidOperationAccountChangeTests {
    let cloud = FakeCloud()

    @Test func accountSwitchDuringUploadIgnoresLateResultsAndRecoversWithoutDuplicates() async throws {
        let device = try await SimulatedDevice("A", cloud: cloud)
        await device.start()
        let note = try await device.store.createNote(title: "uploading", body: "v1")

        let batch = try await device.beginSend()          // Upload in flight on engine 1…
        try await device.switchAccount(to: "user-B")       // …the account changes…
        await device.coordinator.waitForEngineTeardowns()
        #expect(batch.engine.wasCancelled)
        #expect(await device.coordinator.accountState == .mismatch(bound: "user-A", current: "user-B"))
        await device.finishSend(batch)                     // …then the result arrives.

        // The save reached user A's server, but the result came from a stopped engine.
        // It is ignored; the row stays pending; nothing is persisted.
        #expect(await cloud.record(note.id)?.body == "v1")
        #expect(try await device.store.pendingChanges().count == 1)

        // User A signs back in. A new engine re-sends, gets serverRecordChanged with
        // identical content, adopts it: no duplicate, no conflict copy.
        try await device.switchAccountBack(to: "user-A")
        try await device.sync()
        #expect(try await device.liveNotes.map(\.title) == ["uploading"])
        #expect(try await device.store.pendingChanges().isEmpty)
        #expect(await cloud.recordCount == 1)
    }

    @Test func accountSwitchDuringFetchNeverAppliesOrPersistsTheLaterChanges() async throws {
        let device = try await SimulatedDevice("A", cloud: cloud)
        await device.start()
        try await device.fetch()
        let tokenBefore = try #require(try await device.persistedFetchToken)
        let oldEngine = try device.engine

        // Another device of user A uploads, then this device's account switches while
        // its engine is part-way through fetching.
        let other = try await SimulatedDevice("B", cloud: cloud)
        await other.start()
        try await other.store.createNote(title: "fetched late")
        try await other.sync()
        try await device.switchAccount(to: "user-B")
        try await device.fetch(using: oldEngine)  // Changes + state update from engine 1.

        #expect(try await device.liveNotes.isEmpty)
        #expect(try await device.persistedFetchToken == tokenBefore)

        // When user A is back, the new engine starts from the persisted state, so the
        // change is redelivered.
        try await device.switchAccountBack(to: "user-A")
        try await device.fetch()
        #expect(try await device.liveNotes.map(\.title) == ["fetched late"])
    }

    @Test func revalidationBeforeAFetchCatchesAnAccountChangeTheEngineHasNotReported() async throws {
        let device = try await SimulatedDevice("A", cloud: cloud)
        await device.start()
        let engine = try device.engine

        device.accounts.account = .available(user: "user-B")
        await device.coordinator.operationWillStart(isFetch: true, from: engine.eventSourceID)

        await device.coordinator.waitForEngineTeardowns()
        #expect(engine.wasCancelled)
        #expect(await device.coordinator.accountState == .mismatch(bound: "user-A", current: "user-B"))
        await device.coordinator.handleFetchedChanges([.modified(remoteNote("B's", tag: "b1"))], from: engine.eventSourceID)
        #expect(try await device.liveNotes.isEmpty)
    }

    @Test func signOutDuringSyncKeepsNotesAndResumesForTheSameAccount() async throws {
        let device = try await SimulatedDevice("A", cloud: cloud)
        await device.start()
        device.accounts.account = .noAccount
        await device.coordinator.handleAccountChange(.signOut(previousUser: "user-A"), from: try device.engine.eventSourceID)
        #expect(await device.coordinator.accountState == .noAccount)

        let note = try await device.store.createNote(title: "written while signed out")
        device.accounts.account = .available(user: "user-A")
        await device.coordinator.accountMayHaveChanged()

        #expect(await device.coordinator.accountState == .active(user: "user-A"))
        try await device.send()
        #expect(await cloud.record(note.id) != nil)
    }

    @Test func mismatchBlocksUploadsFetchesAndStatePersistence() async throws {
        let device = try await SimulatedDevice("A", cloud: cloud)
        await device.start()
        try await device.store.createNote(title: "A's note")
        try await device.sync()
        let persisted = try await device.store.engineState()
        let oldEngine = try device.engine
        try await device.switchAccount(to: "user-B")

        let edit = try await device.store.createNote(title: "A's unsynced note")
        await device.coordinator.localNotesChanged([edit.id])
        #expect(await device.coordinator.snapshotForUpload(edit.id, from: oldEngine.eventSourceID) == nil)
        await device.coordinator.handleFetchedChanges([.modified(remoteNote("B's note", tag: "b-1"))], from: oldEngine.eventSourceID)
        await device.coordinator.handleEngineStateUpdate(Data("12345".utf8), from: oldEngine.eventSourceID)

        #expect(device.engineCount == 1)
        #expect(!oldEngine.pending.contains(edit.id))
        #expect(try await device.liveNotes.allSatisfy { $0.title != "B's note" })
        #expect(try await device.store.engineState() == persisted)
        #expect(try await device.store.boundAccount() == "user-A")
    }
}

extension MidOperationAccountChangeTests {
    @Test func lateStateUpdateFromStoppedEngineIsIgnoredEvenAfterReactivation() async throws {
        let device = try await SimulatedDevice("A", cloud: cloud)
        await device.start()
        try await device.fetch()
        let oldEngine = try device.engine
        let other = try await SimulatedDevice("B", cloud: cloud)
        await other.start()
        try await other.store.createNote(title: "must arrive")
        try await other.sync()

        // A → B → A quickly; engine 1 is stopped, engine 2 is now current for user A.
        try await device.switchAccount(to: "user-B")
        try await device.switchAccountBack(to: "user-A")
        let tokenBefore = try await device.persistedFetchToken

        // Engine 1 delivers its (ignored) fetch and a state update past those changes.
        try await device.fetch(using: oldEngine)
        #expect(try await device.persistedFetchToken == tokenBefore)

        try await device.relaunch()
        try await device.fetch()
        #expect(try await device.liveNotes.map(\.title) == ["must arrive"])
    }

    @MainActor
    @Test func resultsFromThePreviousAccountsEngineNeverTouchTheFreshDatabase() async throws {
        let device = try await SimulatedDevice("A", cloud: cloud)
        await device.start()
        let note = try await device.store.createNote(title: "A's note", body: "v1")
        try await device.sync()
        try await device.store.updateNote(id: note.id, title: "A's note", body: "v2")
        let batch = try await device.beginSend()       // Engine 1 uploading A's note…
        try await device.switchAccount(to: "user-B")    // …account changes…

        let model = NotesModel(autosaveDelay: .seconds(3600))
        model.connect(sync: device.coordinator)
        await model.attach(device.store, at: device.directory.storeURL)
        await model.startFreshForCurrentAccount()        // …user switches to B's notes.
        let fresh = try #require(model.store)

        // Engine 1's result (a conflict carrying A's server record) arrives late.
        let server = try #require(await cloud.record(note.id))
        await device.coordinator.handleSendResults(
            [.failed(id: note.id, .conflict(server: server))], from: batch.engine.eventSourceID)

        #expect(try await fresh.allNotes().isEmpty)  // Nothing of A's leaked into B's database.
    }
}

@Suite("Account lifecycle: restart after deferred or rejected events")
struct RestartRecoveryTests {
    let cloud = FakeCloud()

    @Test func changeThatFailedToApplyIsRedeliveredAfterRelaunch() async throws {
        let other = try await SimulatedDevice("B", cloud: cloud)
        await other.start()
        try await other.store.createNote(title: "must not be lost")
        try await other.sync()

        let device = try await SimulatedDevice("A", cloud: cloud)
        await device.start()
        let tokenBefore = try await device.persistedFetchToken
        // Applying the fetched change fails (simulated disk error on insert).
        try await device.store.executeForTesting("""
            CREATE TRIGGER fail_inserts BEFORE INSERT ON notes
            BEGIN SELECT RAISE(ABORT, 'injected test failure'); END;
            """)
        try await device.fetch()

        #expect(try await device.liveNotes.isEmpty)
        // The engine's state moved past the change, but it was NOT persisted.
        #expect(try await device.persistedFetchToken == tokenBefore)

        try await device.store.executeForTesting("DROP TRIGGER fail_inserts;")
        try await device.relaunch()
        try await device.fetch()
        #expect(try await device.liveNotes.map(\.title) == ["must not be lost"])
    }

    @Test func syncNowRecreatesTheEngineToRedeliverAnUnappliedChange() async throws {
        let other = try await SimulatedDevice("B", cloud: cloud)
        await other.start()
        try await other.store.createNote(title: "redeliver me")
        try await other.sync()

        let device = try await SimulatedDevice("A", cloud: cloud)
        await device.start()
        try await device.store.executeForTesting("""
            CREATE TRIGGER fail_inserts BEFORE INSERT ON notes
            BEGIN SELECT RAISE(ABORT, 'injected test failure'); END;
            """)
        try await device.fetch()
        try await device.store.executeForTesting("DROP TRIGGER fail_inserts;")

        await device.coordinator.syncNow()  // In-session recovery, no relaunch.
        #expect(device.engineCount == 2)
        try await device.fetch()
        #expect(try await device.liveNotes.map(\.title) == ["redeliver me"])
    }

    @Test func changesIgnoredFromAStoppedEngineAreRedeliveredAfterRelaunch() async throws {
        let device = try await SimulatedDevice("A", cloud: cloud)
        await device.start()
        let oldEngine = try device.engine
        let other = try await SimulatedDevice("B", cloud: cloud)
        await other.start()
        try await other.store.createNote(title: "arrived during switch")
        try await other.sync()

        try await device.switchAccount(to: "user-B")
        try await device.fetch(using: oldEngine)  // Ignored, and so is its state update.

        device.accounts.account = .available(user: "user-A")
        try await device.relaunch()
        try await device.fetch()
        #expect(try await device.liveNotes.map(\.title) == ["arrived during switch"])
    }

    @Test func deferredInFlightChangeIsRecoveredAfterRelaunch() async throws {
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
        _ = try await a.beginSend()   // In flight: A's upload never gets a result…
        try await a.fetch()           // …B's edit is deferred to that result; state persisted…
        try await a.relaunch()        // …and the app dies.

        // The persisted state is past B's edit, but A's row is still pending. The
        // re-upload hits serverRecordChanged carrying B's edit, which is resolved.
        try await a.sync()
        #expect(contents(try await a.liveNotes) == ["A edit (Conflict copy)|", "B edit|"])
        #expect(try await a.store.pendingChanges().isEmpty)
    }
}

@Suite("Account lifecycle: switching to a fresh database")
struct StartFreshTests {
    @MainActor
    @Test func startingFreshArchivesTheOtherAccountsDatabase() async throws {
        let cloud = FakeCloud()
        let device = try await SimulatedDevice("A", cloud: cloud)
        await device.start()
        try await device.store.createNote(title: "A's private note")
        try await device.switchAccount(to: "user-B")

        let model = NotesModel(autosaveDelay: .seconds(3600))
        model.connect(sync: device.coordinator)
        // The app shares one store instance between the UI and sync; so does this test.
        await model.attach(device.store, at: device.directory.storeURL)
        #expect(model.notes.map(\.title) == ["A's private note"])

        await model.startFreshForCurrentAccount()

        #expect(model.notes.isEmpty)
        #expect(await device.coordinator.accountState == .active(user: "user-B"))
        #expect(try await model.store?.boundAccount() == "user-B")
        #expect(device.engineCount == 2)
        #expect(device.restoredState(ofEngine: 1) == nil)  // Fresh engine for user B.
        let archived = try FileManager.default.contentsOfDirectory(
            at: device.directory.url.appending(path: "Archived"), includingPropertiesForKeys: nil)
        let archive = try #require(archived.first { $0.pathExtension == "sqlite" })
        let old = try NoteStore(url: archive)
        #expect(try await old.allNotes().map(\.title) == ["A's private note"])
        #expect(try await old.boundAccount() == "user-A")
    }
}

extension SimulatedDevice {
    /// The device signs back in to the database's own account. No engine exists during
    /// a mismatch, so the change arrives as `CKAccountChanged`.
    func switchAccountBack(to user: String) async throws {
        accounts.account = .available(user: user)
        await coordinator.accountMayHaveChanged()
    }
}
