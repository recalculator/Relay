import Foundation
import os
import RelayCore

struct Configuration {
    var sizes = [1_000, 10_000]
    var repetitions = 3
    var saveOperations = 2_000
    var saveWarmup = 50
    var reopenIterations = 10
    var reopenWarmup = 2
    var searchIterations = 30
    var searchWarmup = 3
    var seed: UInt64 = 0x5245_4C41_59  // "RELAY"

    static let quick = Configuration(
        sizes: [1_000], repetitions: 2, saveOperations: 200, saveWarmup: 10,
        reopenIterations: 3, reopenWarmup: 1, searchIterations: 5, searchWarmup: 1)
}

/// The workloads. Each uses RelayCore's public API exactly as the app does. Setup is
/// outside the timed region, and every result is validated after timing stops.
@MainActor
struct Workloads {
    let config: Configuration
    let workspace: Workspace
    let created = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func dataset(_ size: Int) -> [Dataset.GeneratedNote] {
        Dataset.notes(count: size, seed: config.seed &+ UInt64(size))
    }

    // MARK: 1. Durable local save latency

    /// Edits existing notes through `NoteStore.updateNote`, the call the editor's
    /// autosave makes (with the same `base` argument). Each call is one SQLite
    /// transaction: content update and `local_version` bump (the pending-sync marker),
    /// committed with the app's durability settings. The UI's 0.75 s debounce isn't
    /// included: timing starts when the save is issued.
    func saveLatency(size: Int) async throws -> WorkloadResult {
        let notes = dataset(size)
        let template = try await workspace.template(for: notes, created: created)
        var repetitions: [Summary] = []
        var raw: [[Double]] = []

        for repetition in 0..<config.repetitions {
            let url = try workspace.copy(template: template, name: "save-\(size)-\(repetition)")
            let store = try await NoteStore.open(at: url)
            var current = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, (title: $0.title, body: $0.body)) })
            var rng = SplitMix64(seed: config.seed ^ 0x5A5E ^ UInt64(repetition))
            var edited: Set<UUID> = []
            var samples: [Double] = []
            samples.reserveCapacity(config.saveOperations)

            for operation in 0..<(config.saveWarmup + config.saveOperations) {
                let note = notes[Int.random(in: 0..<notes.count, using: &rng)]
                let before = current[note.id]!
                // A typing burst: one to three words added at the end.
                let words = (0..<Int.random(in: 1...3, using: &rng)).map { _ in
                    Dataset.vocabulary[Int.random(in: 0..<Dataset.vocabulary.count, using: &rng)]
                }
                let body = before.body + " " + words.joined(separator: " ")

                let (_, ns) = try await Measure.time {
                    try await store.updateNote(
                        id: note.id, title: before.title, body: body, kind: .snippet,
                        base: NoteContent(title: before.title, body: before.body))
                }
                current[note.id] = (before.title, body)
                edited.insert(note.id)
                if operation >= config.saveWarmup { samples.append(ns) }
            }

            // Validation, after timing: every edit is stored and marked pending.
            let pending = Set(try await store.pendingChanges().map(\.noteID))
            try require(pending == edited, "pending set (\(pending.count)) != edited notes (\(edited.count))")
            for id in edited {
                let stored = try await store.note(id: id)
                try require(stored?.body == current[id]?.body, "note \(id) content mismatch")
            }
            await store.close()
            try workspace.remove(directoryOf: url)
            repetitions.append(Summary(nanoseconds: samples))
            raw.append(samples)
        }
        return WorkloadResult(
            workload: "save-latency", variant: "updateNote (one transaction per edit)",
            notesInDatabase: size, operationsPerRepetition: config.saveOperations,
            commitMode: "one durable transaction per edit, as the app's autosave",
            repetitions: repetitions, pooled: Summary(nanoseconds: raw.flatMap { $0 }),
            derived: [:],
            validation: "pending set == edited notes; every edited note's stored body == last saved text",
            rawSamplesNs: raw)
    }

    // MARK: 2. Reopened-store open and load

    /// What the app does at launch before showing the list: `NoteStore.open` (connect,
    /// apply durability pragmas, check/migrate schema), then `allNotes()`. The file was
    /// written moments earlier and isn't evicted from the OS cache, so this is
    /// **reopened-store, warm-cache** time, not cold-disk time.
    func reopen(size: Int) async throws -> [WorkloadResult] {
        let notes = dataset(size)
        let template = try await workspace.template(for: notes, created: created)
        var openRuns: [[Double]] = []
        var totalRuns: [[Double]] = []

        for repetition in 0..<config.repetitions {
            let url = try workspace.copy(template: template, name: "reopen-\(size)-\(repetition)")
            var openSamples: [Double] = []
            var totalSamples: [Double] = []
            for iteration in 0..<(config.reopenWarmup + config.reopenIterations) {
                let start = Measure.clock.now
                let store = try await NoteStore.open(at: url)
                let opened = Measure.clock.now
                let loaded = try await store.allNotes()
                let end = Measure.clock.now
                blackHole(loaded)
                try require(loaded.count == size, "loaded \(loaded.count) notes, expected \(size)")
                await store.close()
                if iteration >= config.reopenWarmup {
                    openSamples.append(Measure.nanoseconds(start.duration(to: opened)))
                    totalSamples.append(Measure.nanoseconds(start.duration(to: end)))
                }
            }
            try workspace.remove(directoryOf: url)
            openRuns.append(openSamples)
            totalRuns.append(totalSamples)
        }
        func result(_ variant: String, _ runs: [[Double]]) -> WorkloadResult {
            WorkloadResult(
                workload: "reopened-store", variant: variant, notesInDatabase: size,
                operationsPerRepetition: config.reopenIterations, commitMode: "read only",
                repetitions: runs.map { Summary(nanoseconds: $0) }, pooled: Summary(nanoseconds: runs.flatMap { $0 }),
                derived: [:], validation: "allNotes().count == notes in database", rawSamplesNs: runs)
        }
        return [result("NoteStore.open", openRuns), result("NoteStore.open + allNotes()", totalRuns)]
    }

    // MARK: 3. Search

    /// The app's search: `NotesModel.visibleNotes` with `searchText` set, which filters
    /// the loaded notes in memory with `localizedStandardContains`. Loading is done
    /// before timing. This is the filter computation only, not SwiftUI rendering.
    func search(size: Int) async throws -> [WorkloadResult] {
        let notes = dataset(size)
        let template = try await workspace.template(for: notes, created: created)
        let url = try workspace.copy(template: template, name: "search-\(size)")
        let store = try await NoteStore.open(at: url)
        defer { try? workspace.remove(directoryOf: url) }

        let queries: [(variant: String, query: String)] = [
            ("many matches “\(Dataset.manyMatchQuery)”", Dataset.manyMatchQuery),
            ("few matches “\(Dataset.fewMatchToken)”", Dataset.fewMatchToken),
            ("no matches", Dataset.noMatchQuery),
        ]
        var results: [WorkloadResult] = []
        for (variant, query) in queries {
            // Independent expectation: plain lowercase substring matching. The dataset
            // is ASCII, where this agrees with `localizedStandardContains`.
            let expected = Set(notes.filter {
                $0.title.lowercased().contains(query) || $0.body.lowercased().contains(query)
            }.map(\.id))
            var runs: [[Double]] = []
            for _ in 0..<config.repetitions {
                let model = NotesModel()
                await model.attach(store)
                try require(model.notes.count == size, "model loaded \(model.notes.count) notes")
                var samples: [Double] = []
                for iteration in 0..<(config.searchWarmup + config.searchIterations) {
                    model.searchText = query
                    let start = Measure.clock.now
                    let visible = model.visibleNotes
                    let ns = Measure.nanoseconds(start.duration(to: Measure.clock.now))
                    try require(Set(visible.map(\.id)) == expected,
                                "“\(query)”: \(visible.count) results, expected \(expected.count)")
                    if iteration >= config.searchWarmup { samples.append(ns) }
                }
                runs.append(samples)
            }
            results.append(WorkloadResult(
                workload: "search", variant: variant, notesInDatabase: size,
                operationsPerRepetition: config.searchIterations, commitMode: "in memory, no database access",
                repetitions: runs.map { Summary(nanoseconds: $0) }, pooled: Summary(nanoseconds: runs.flatMap { $0 }),
                derived: ["matches": Double(expected.count)],
                validation: "result ids == notes whose lowercased title or body contains the query (\(expected.count))",
                rawSamplesNs: runs))
        }
        await store.close()
        return results
    }

    // MARK: 4. Incoming-change application

    static let incomingCreates = 400
    static let incomingEdits = 300
    static let incomingTombstones = 200
    static let incomingConflicts = 100

    /// One fetched batch delivered to `SyncCoordinator.handleFetchedChanges`, the
    /// method the CloudKit adapter calls, with a simulated engine and account (no
    /// CloudKit). The coordinator applies each change with `NoteStore.applyRemote`, one
    /// transaction per change, as in the app. The batch mixes creates, edits,
    /// tombstones, and conflicts with local unsynced edits.
    func incoming(size: Int) async throws -> WorkloadResult {
        let notes = dataset(size)
        let template = try await workspace.template(for: notes, created: created)
        let batchSize = Self.incomingCreates + Self.incomingEdits + Self.incomingTombstones + Self.incomingConflicts
        var samples: [Double] = []

        for repetition in 0..<config.repetitions {
            let url = try workspace.copy(template: template, name: "incoming-\(size)-\(repetition)")
            let store = try await NoteStore.open(at: url)
            var rng = SplitMix64(seed: config.seed ^ 0x1C0E ^ UInt64(repetition))
            var existing = notes
            existing.shuffle(using: &rng)
            let conflicted = Array(existing[0..<Self.incomingConflicts])
            let edited = Array(existing[Self.incomingConflicts..<(Self.incomingConflicts + Self.incomingEdits)])
            let tombstoned = Array(existing[(Self.incomingConflicts + Self.incomingEdits)..<(Self.incomingConflicts + Self.incomingEdits + Self.incomingTombstones)])
            let fresh = Dataset.notes(count: Self.incomingCreates, seed: config.seed ^ 0xF4E5 ^ UInt64(repetition))

            // Setup: unsynced local edits on the notes that will conflict.
            for note in conflicted {
                try await store.updateNote(id: note.id, title: note.title, body: note.body + " local edit")
            }

            // Setup: a sync coordinator with a simulated engine, bound to a fake account.
            let coordinator = SyncCoordinator(store: store, status: nil, accountProvider: BenchAccount())
            let engineBox = OSAllocatedUnfairLock<BenchEngine?>(initialState: nil)
            await coordinator.start { _, _ in
                let engine = BenchEngine()
                engineBox.withLock { $0 = engine }
                return engine
            }
            guard let engine = engineBox.withLock({ $0 }) else { throw BenchmarkFailure("no engine was created") }

            let later = created.addingTimeInterval(1_000_000)
            var batch: [RemoteChange] = []
            batch += fresh.enumerated().map { .modified(Dataset.remote($1, tag: "c-\($0)", created: later)) }
            batch += edited.enumerated().map { index, note in
                .modified(Dataset.remote(.init(id: note.id, title: note.title, body: note.body + " remote edit"),
                                         tag: "e-\(index)", created: later))
            }
            batch += tombstoned.enumerated().map { .modified(Dataset.remote($1, tag: "d-\($0)", created: later, isDeleted: true)) }
            batch += conflicted.enumerated().map { index, note in
                .modified(Dataset.remote(.init(id: note.id, title: note.title, body: note.body + " server edit"),
                                         tag: "x-\(index)", created: later))
            }
            batch.shuffle(using: &rng)
            try require(batch.count == batchSize, "batch has \(batch.count) changes")

            let (_, ns) = await Measure.time {
                await coordinator.handleFetchedChanges(batch, from: engine.eventSourceID)
            }
            samples.append(ns)

            // Validation, after timing.
            let live = try await store.allNotes()
            let byID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
            let copies = live.filter { $0.conflictOf != nil }
            let expectedLive = size + Self.incomingCreates - Self.incomingTombstones + Self.incomingConflicts
            try require(live.count == expectedLive, "\(live.count) live notes, expected \(expectedLive)")
            try require(copies.count == Self.incomingConflicts, "\(copies.count) conflict copies")
            try require(fresh.allSatisfy { byID[$0.id]?.body == $0.body }, "created notes missing")
            try require(edited.allSatisfy { byID[$0.id]?.body == $0.body + " remote edit" }, "edits not applied")
            try require(tombstoned.allSatisfy { byID[$0.id] == nil }, "tombstoned notes still present")
            try require(conflicted.allSatisfy { byID[$0.id]?.body == $0.body + " server edit" }, "server version not primary")
            try require(Set(copies.map(\.body)) == Set(conflicted.map { $0.body + " local edit" }), "local versions not kept as copies")
            let pending = Set(try await store.pendingChanges().map(\.noteID))
            try require(pending == Set(copies.map(\.id)), "pending (\(pending.count)) != conflict copies")
            try require(Set(engine.pendingSaves) == pending, "engine wasn't told about exactly the pending copies")

            await store.close()
            try workspace.remove(directoryOf: url)
        }
        let throughputs = samples.map { Double(batchSize) / ($0 / 1e9) }
        return WorkloadResult(
            workload: "incoming-changes", variant: "SyncCoordinator.handleFetchedChanges, simulated transport",
            notesInDatabase: size, operationsPerRepetition: batchSize,
            commitMode: "one durable transaction per change, as the coordinator applies them",
            repetitions: samples.map { Summary(nanoseconds: [$0]) }, pooled: Summary(nanoseconds: samples),
            derived: [
                "changesPerSecondMedian": throughputs.sorted()[throughputs.count / 2],
                "changesPerSecondMin": throughputs.min()!,
                "changesPerSecondMax": throughputs.max()!,
            ],
            validation: "live/tombstoned/edited/created contents, \(Self.incomingConflicts) conflict copies with the local text, pending == copies, engine queue == pending",
            rawSamplesNs: [samples])
    }

    // MARK: 5. Pending-change recovery

    static let recoveryEdits = 500
    static let recoveryDeletes = 50
    static let recoveryCreates = 50

    /// Offline edits, deletes, and creates are committed, the store is closed, then
    /// timed: reopening it and enumerating `pendingChanges()`, the query the
    /// coordinator uses to re-queue every unsynced row whenever an engine starts.
    func recovery(size: Int) async throws -> WorkloadResult {
        let notes = dataset(size)
        let template = try await workspace.template(for: notes, created: created)
        var runs: [[Double]] = []

        for repetition in 0..<config.repetitions {
            let url = try workspace.copy(template: template, name: "recovery-\(size)-\(repetition)")
            var rng = SplitMix64(seed: config.seed ^ 0x2EC0 ^ UInt64(repetition))
            var shuffled = notes
            shuffled.shuffle(using: &rng)
            var expected: [UUID: PendingChange.Kind] = [:]

            let store = try await NoteStore.open(at: url)
            for note in shuffled.prefix(Self.recoveryEdits) {
                try await store.updateNote(id: note.id, title: note.title, body: note.body + " offline edit")
                expected[note.id] = .save
            }
            for note in shuffled.dropFirst(Self.recoveryEdits).prefix(Self.recoveryDeletes) {
                try await store.deleteNote(id: note.id)
                expected[note.id] = .delete
            }
            for index in 0..<Self.recoveryCreates {
                let note = try await store.createNote(title: "Offline \(index)", body: "created offline")
                expected[note.id] = .save
            }
            await store.close()

            var samples: [Double] = []
            for iteration in 0..<(config.reopenWarmup + config.reopenIterations) {
                let start = Measure.clock.now
                let reopened = try await NoteStore.open(at: url)
                let pending = try await reopened.pendingChanges()
                let ns = Measure.nanoseconds(start.duration(to: Measure.clock.now))
                await reopened.close()
                let found = Dictionary(uniqueKeysWithValues: pending.map { ($0.noteID, $0.kind) })
                try require(found == expected, "recovered \(found.count) pending changes, expected \(expected.count)")
                if iteration >= config.reopenWarmup { samples.append(ns) }
            }
            try workspace.remove(directoryOf: url)
            runs.append(samples)
        }
        let total = Self.recoveryEdits + Self.recoveryDeletes + Self.recoveryCreates
        return WorkloadResult(
            workload: "pending-recovery", variant: "NoteStore.open + pendingChanges() after close",
            notesInDatabase: size, operationsPerRepetition: config.reopenIterations,
            commitMode: "read only (the \(total) offline changes were committed one per transaction during setup)",
            repetitions: runs.map { Summary(nanoseconds: $0) }, pooled: Summary(nanoseconds: runs.flatMap { $0 }),
            derived: ["pendingChanges": Double(total)],
            validation: "recovered pending set and kinds == the \(Self.recoveryEdits) edits, \(Self.recoveryDeletes) deletes, \(Self.recoveryCreates) creates",
            rawSamplesNs: runs)
    }
}

// MARK: Simulated sync collaborators (no CloudKit)

/// Always reports one signed-in account.
struct BenchAccount: AccountProvider {
    func currentAccount() async -> ICloudAccount { .available(user: "benchmark-user") }
    func invalidate() {}
}

/// Records what the coordinator queues. Never sends anything anywhere.
final class BenchEngine: SyncEngineControl {
    private let pending = OSAllocatedUnfairLock<Set<UUID>>(initialState: [])
    var eventSourceID: ObjectIdentifier { ObjectIdentifier(self) }
    var pendingSaves: Set<UUID> { pending.withLock { $0 } }
    func addPendingSaves(_ ids: [UUID]) { pending.withLock { $0.formUnion(ids) } }
    func removePendingSaves(_ ids: [UUID]) { pending.withLock { $0.subtract(ids) } }
    func addPendingZoneSave() {}
    func fetchChanges() async throws {}
    func sendChanges() async throws {}
    func cancelOperations() async {}
}
