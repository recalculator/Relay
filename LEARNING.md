# Swift concepts in Relay

Each concept points to the place in this codebase where it solves a real problem.
Paths are relative to `Packages/RelayCore/Sources/RelayCore/` unless noted otherwise.

## Value vs. reference semantics

- `Note` is a **struct** (`Note.swift`). Assigning or passing it copies it, so the UI's
  copy and the store's copy can never alias each other. In `NoteStore.updateNote`,
  `guard var note = …` makes a local copy, mutates it, and returns it. Nothing else
  changes.
- `NotesModel` and `NoteEditorModel` are **classes** because many SwiftUI views need to
  share *one* instance and observe its changes. That's identity, which only reference
  types have.

## Optionals

An `Optional<T>` (`T?`) is either a value or `nil`, and the compiler makes you handle
both. Examples:
- `NoteStore.note(id:) -> Note?`: nil means "not found or deleted". It isn't an error.
- `SQLiteRow.string(_:) -> String?`: SQL NULL maps to nil. `decodeNote` turns an
  unexpected nil into `StoreError.corruptRow` instead of hiding it.
- `editor?.save()` (optional chaining) does nothing if there's no editor.
- `id.flatMap { … }.map(makeEditor(for:))` in `NotesModel.select` chains two optional
  steps without nested `if let`s.
- There are **no force unwraps (`!`)**. The one "can't happen" case
  (`storeOrPreconditionFailure`) is an explicit `preconditionFailure` with a message.

## Error propagation and typed throws

- `throws(StoreError)` (Swift 6 typed throws) is used throughout the store. Callers know
  every possible failure at compile time.
- `do throws(StoreError) { … } catch { … }` (`NotesModel.open`) makes `error` a
  `StoreError` in the `catch`, not `any Error`.
- `SQLiteConnection.transaction` shows rethrow-with-cleanup: catch, roll back, rethrow.
- `try?` is used only where failure is truly irrelevant (test cleanup). Real failures are
  logged and surfaced.

## async/await

An `async` function can **suspend** at each `await`, freeing its thread for other work
until the result is ready. `await store.updateNote(…)` from the main actor suspends the
UI code while the actor does the database work elsewhere, so the UI keeps responding.

## Actors and isolation

`NoteStore` is an `actor` (`NoteStore.swift`). Its state can only be touched from
inside it, one task at a time, so data races on the SQLite connection are impossible,
and the compiler enforces that. `SQLiteConnection` is deliberately non-`Sendable` with no
locks. Its safety comes entirely from being owned by the actor.

### Reentrancy

Actors are **reentrant**: when an actor method hits an `await`, other calls may run on
that actor before it resumes. State you read before the `await` may have changed after
it. Relay handles this in two ways:
- Store methods contain **no** `await`, so a transaction can't be interleaved.
- `NoteEditorModel.performSave` snapshots `title` and `body` *before* awaiting the store.
  The user can keep typing during the save, and those keystrokes are handled by the
  next save.

## @MainActor

`@MainActor` (on `NotesModel` and `NoteEditorModel`) isolates a type to the main thread,
where SwiftUI runs. A `Task { … }` created inside them inherits that isolation, so the
autosave task can touch `self.title` safely.

## @concurrent

`NoteStore.open(at:)` is `@concurrent`, so it always runs on the background executor
even though the app calls it from the main actor. Opening and migrating the database
therefore never blocks the UI.

## Sendable

`Sendable` marks types that are safe to share across concurrency domains. `Note`,
`PendingChange`, and `StoreError` are `Sendable` structs and enums, so they can be
returned from the actor to the main actor. The clock parameter is
`@Sendable () -> Date` because the actor calls it. In tests, the clock's mutable counter
is protected by `OSAllocatedUnfairLock`, which is what makes that closure `Sendable`.

## Closures

- `NoteEditorModel(onSaved:)` takes an `@escaping @MainActor (Note) -> Void`. It's
  *escaping* because it's stored, and *main-actor* because it updates UI state.
  `NotesModel` passes `[weak self] saved in self?.noteDidSave(saved)`. The weak capture
  prevents a retain cycle (model → editor → closure → model).
- `Task { [weak self, autosaveDelay] in … }` in `scheduleAutosave` uses a capture list to
  copy the delay and capture `self` weakly. A pending timer then doesn't keep a
  discarded editor alive.
- `SQLiteConnection.query(_:_:_:)` takes a decoding closure `(SQLiteRow) throws(StoreError) -> T`,
  which makes the wrapper generic over the row type.

## Observation (`@Observable`, `@Bindable`)

`@Observable` classes track which properties each view reads, and re-render only those
views when the properties change. `@ObservationIgnored` excludes bookkeeping (tasks, the
store reference) from tracking. `@Bindable` in views (`NoteEditorView`) creates
`$editor.title` bindings into an observable object the view doesn't own.

## C interop (SQLite)

`SQLiteConnection.swift` calls the SQLite C API directly. Things to notice:
`OpaquePointer` for C handles, `&db` to pass an out-parameter, `defer { sqlite3_finalize }`
to guarantee cleanup on every exit path, and rebuilding the `SQLITE_TRANSIENT` macro,
which Swift can't import.

---

# Added in Phase 2 (sync)

## Protocols as a test seam, not an abstraction layer

`SyncEngineControl` (`SyncCoordinator.swift`) has six methods: exactly what the
coordinator asks of CKSyncEngine. Production wraps the real engine
(`CloudKitEngineControl`). Tests use `FakeSyncEngine`. There's one protocol, because
there's one real boundary that tests need to replace. Everything else is concrete.

## Value types for messages between layers

`RemoteNote`, `RemoteChange`, `SendResult`, and `SendFailure` (`SyncModels.swift`) are
`Sendable` structs and enums that carry no CloudKit types. The CloudKit adapter
translates `CKRecord`/`CKError` into them once. The store, resolver, and coordinator
therefore can't depend on CloudKit, and tests can construct any situation, including
values a real server would produce that can't be created locally (`CKRecord`'s change
tag is read-only).

## Enums with associated values and exhaustive `switch`

`ConflictResolver.resolve` returns a `Resolution` enum. `NoteStore.applyRemote` switches
over `(resolution, change)` pairs. The compiler insists every combination is handled,
which is how the "impossible" pairs got an explicit, logged no-op instead of a crash.
`@unknown default` in `CloudKitSync.swift` handles cases Apple might add to
`CKSyncEngine.Event` in future SDKs.

## Pure functions for policy

`ConflictResolver` does no I/O and has no state. Its test is a table of
(input → expected decision) rows. Keeping the policy pure is what lets the whole
edit-vs-edit / edit-vs-delete matrix be checked in one place.

## Actor reentrancy, for real

`SyncCoordinator` awaits the store inside its methods. At each `await`, another engine
callback may run on the coordinator. Rather than trying to prevent that, Relay makes
each decision depend on data checked *inside one store transaction* (the stored change
tag), so an interleaving can't produce a wrong decision. Compare `NoteStore`, which
avoids `await` inside methods altogether.

## `AsyncStream` and a subscription race

`NoteStore.changes()` returns an `AsyncStream<StoreChange>`. A first version subscribed
inside `Task { for await … in await store.changes() }`, so any change committed before
the Task started was missed. A test that awaited the engine call exposed it by hanging.
The fix is to subscribe first and *then* start the Task (`observeLocalChanges`).

## `@Sendable` async closures

`CKSyncEngine.RecordZoneChangeBatch(pendingChanges:recordProvider:)` takes an
`@Sendable (CKRecord.ID) async -> CKRecord?`. In `nextRecordZoneChangeBatch`, the
closure captures the actor (`[self]`) and `await`s `snapshotForUpload`, hopping back
onto the actor for each record. That's also where the in-flight version is recorded.

## Typed throws and closures

Closure literals don't infer a typed `throws`. In `SyncCoordinator`, closures passed to
`perform(_:_:)` must say so: `{ store throws(StoreError) in … }`. The compiler error was
"invalid conversion of thrown error type 'any Error' to 'StoreError'".

## Codable for opaque state

`CKSyncEngine.State.Serialization` is `Codable` but opaque. Relay JSON-encodes it into a
BLOB in `sync_state`, in the same database as the data it describes. That's how it is
persisted "alongside" the notes, as Apple's documentation asks.

## Deterministic identifiers with CryptoKit

`ConflictCopy.id` hashes (original id, title, body) with SHA-256 and shapes the result
into a UUID (version/variant bits set). The same conflict always yields the same copy
id, so `INSERT … ON CONFLICT DO NOTHING` makes repeated handling idempotent.

---

# Added in the account-gating revision

## Object identity to reject stale callbacks

`CKSyncEngine` passes itself to every delegate callback. `SyncCoordinator` keeps the
`ObjectIdentifier` of its current engine and ignores events from any other instance
(`isCurrent(_:)`). Once an engine is replaced, everything it still delivers is
harmless, without trying to cancel or drain it first. `ObjectIdentifier` compares
reference identity, which is why `SyncEngineControl` is constrained to `AnyObject`.

## Guarding actor reentrancy with a generation counter

Account resolution awaits the account provider and the store, so two resolutions can
overlap (launch, foreground, and `CKAccountChanged`). Each resolution takes
`resolutionID += 1` and, after its awaits, checks it still holds the latest id before
acting. It's the actor-world version of "compare-and-swap": state captured before a
suspension point isn't trusted after it. A test holds two resolutions suspended at once
to prove exactly one engine results.

## Not awaiting inside a callback you're being called from

`tearDownEngine()` starts `cancelOperations()` in a `Task` instead of awaiting it. It may
run *inside* that engine's own `handleEvent`, and awaiting the engine's cancellation
from its own callback could wait forever. Correctness doesn't depend on the
cancellation finishing, thanks to the identity check above.

## Test doubles that suspend on purpose

`ManualSleeper` and `FakeAccountProvider.gate` use `withCheckedContinuation` to park a
task until the test calls `release()`. Combined with an `AsyncStream` that announces
"a task is now waiting", tests control interleavings exactly, with no `Task.sleep` and
no timing assumptions. A first version created a new `AsyncStream` iterator per sleep,
which `AsyncStream` doesn't support across concurrent consumers. Continuations are the
right tool here.

## `Sendable` checking catching a real mistake

`async let first = device.coordinator.…` failed to compile: "sending 'device' risks
causing data races", because `SimulatedDevice` is a non-`Sendable` class. Capturing the
coordinator (an actor, so `Sendable`) into a local first fixed it. Swift 6 refused to
let two child tasks share a mutable class.

# Added in the reentrancy and benchmarking revision

## Capture what you operate on; don't re-read it after an `await`

The bug: `handleFetchedChanges` checked "is this still the current engine?" once, then
looped over changes with `await store.applyRemote(…)` inside. Each `await` lets other
calls run on the actor. "Use This Account's Notes" could swap `self.store` mid-loop,
and the next iteration read the *new* `store` and wrote the old account's data into the
new account's database. The fix (`SyncCoordinator.swift`) is an `EngineLease` captured
when the operation starts. Writes go to `lease.store`, and `isValid(lease)` is checked
again after every suspension. The rule is the same one behind `resolutionID`: anything
read before an `await` is a snapshot, not a fact.

## Enforcing an invariant where the write happens

A coordinator check right before `await store.write(…)` still leaves a gap. The call is
queued on the store actor and may run after the coordinator has moved on. So every
sync write carries a `SyncFence` (`NoteStore+Sync.swift`), and the store re-checks it as
the first statement *inside* the write's SQL transaction. The session counter is an
`OSAllocatedUnfairLock` rather than actor state, so `endSyncSession()` is `nonisolated`
and synchronous. `tearDownEngine()` can call it without an `await`, including from
inside the engine's own callback.

## Test checkpoints for exact interleavings

`SyncCoordinator.Checkpoint` is a test-only hook (`nil` in the app) awaited at chosen
points. `CheckpointPause` (`ReentrancyTests.swift`) parks the coordinator there, the
test switches accounts or replaces the database, then releases it. Each new test was
run against the old code first and failed. Each safeguard was then removed one at a
time to check that some test notices (TESTING.md → Mutation checks).

## Measuring what the OS actually does

`PRAGMA fullfsync = ON` reads back as 1, which proves the setting, not the system
call. `Scripts/fsync-probe.sh` loads a small C library with `DYLD_INSERT_LIBRARIES`.
Through the `__DATA,__interpose` section, it wraps `fcntl` and `fsync` to count
`F_FULLFSYNC` and `F_BARRIERFSYNC`. It showed the system SQLite issuing barrier syncs,
not full syncs, so the durability docs were corrected. An earlier attempt used
SQLite's own `xSetSystemCall("fcntl")` hook and counted zero calls even where a sync
had to happen. A probe that can't detect a known-positive case isn't evidence.

## Reading a query plan

`EXPLAIN QUERY PLAN` for the notes-list query printed `USE TEMP B-TREE FOR ORDER BY`:
SQLite was sorting all rows, bodies included, on every load. An index whose column
order matches `WHERE is_deleted = 0 ORDER BY modified_at DESC, id` lets SQLite walk the
index in order instead. A test checks the plan of the exact SQL `allNotes()` runs
(`NoteStore.allNotesQuery`), so a future edit to the query or the index can't silently
bring the sort back.
