# Architecture

Status markers: **[built]** means implemented and covered by automated tests (local
SQLite plus a *simulated* server). **[unverified on iCloud]** means the code exists but
hasn't yet run against real CloudKit. See TESTING.md.

## Overview

```
┌──────────────────────────── App target (Relay) ──────────────────────────────┐
│ SwiftUI views · lifecycle flush · RELAY_CLOUDKIT-gated sync startup          │
└───────────────┬───────────────────────────────────────┬──────────────────────┘
                │ main actor                            │ main actor
┌───────────────▼────────────── RelayCore package ──────▼──────────────────────┐
│ NotesModel ─owns─▶ NoteEditorModel          SyncStatusModel (UI status/log)  │
│      │ await                                       ▲                         │
│      ▼                                             │                         │
│ actor NoteStore (SQLite) ◀──── await ──── actor SyncCoordinator              │
│   · notes, tombstones, sync metadata         · account gate, in-flight map   │
│   · ConflictResolver (pure) applied          · SyncEngineControl protocol ───┼─▶ FakeSyncEngine (tests)
│     inside transactions                      · CloudKitSync.swift adapter ───┼─▶ CKSyncEngine ─▶ iCloud
└──────────────────────────────────────────────────────────────────────────────┘
```

| Component | Responsibility |
|---|---|
| `NoteStore` (actor) | All reads and writes. The local source of truth. Applies sync decisions transactionally. |
| `ConflictResolver` | Pure function: (local row, server version) → decision. No I/O. |
| `SyncCoordinator` (actor) | CloudKit-free sync logic: account gate, which version is in flight, routing send results and fetched changes. |
| `CloudKitSync.swift` | The only CloudKit code: `CKRecord` mapping, `CKError` classification, `CKSyncEngineDelegate`. |
| `SyncEngineControl` | Seam between the coordinator and the engine: add/remove pending saves, zone save, manual sync. |
| `NotesModel`, `NoteEditorModel` | UI state on the main actor. Draft, autosave, reaction to remote changes. |
| `SyncStatusModel` | What the UI says about sync, built only from observed engine events and results. |

## Local persistence  [built]

### Why SQLite

| Option | Fit with explicit `CKSyncEngine` |
|---|---|
| JSON file (Apple's sample) | Rewrites the whole file per save. No transactions. Ruled out. |
| SwiftData | Its own CloudKit sync must be kept off. Transaction boundaries are less explicit. |
| Core Data | Mature and workable. `NSManagedObject` isn't `Sendable`, so Swift 6 needs care. A reasonable alternative. |
| **SQLite (system `SQLite3`)** | Explicit transactions make "content + sync metadata commit together" visible and testable. No dependency. |

Never combine this with `NSPersistentCloudKitContainer` or SwiftData's CloudKit option
for the same records.

### Schema (v2)

```sql
notes(
  id TEXT PRIMARY KEY,         -- UUID; also the CKRecord name
  title, body TEXT,
  created_at, modified_at REAL,
  is_deleted INTEGER,          -- local tombstone
  local_version INTEGER,       -- +1 on every *user* edit/delete
  synced_version INTEGER,      -- highest local_version the server confirmed
  conflict_of TEXT,            -- v2: original note id for conflict copies
  server_change_tag TEXT,      -- v2: change tag of the server version this row is based on
  server_system_fields BLOB    -- v2: encoded CKRecord system fields of that version
) STRICT
sync_state(key TEXT PRIMARY KEY, value BLOB) STRICT   -- v2: engine state, bound account
```

**Pending work** is `local_version > synced_version`. It's written by the same SQL
statement as the edit, so a note can't be saved without its pending marker.
**Sync metadata and engine state live in the same database file** as the notes they
describe.

**Versioning:** `PRAGMA user_version` with numbered migrations. Each runs in one
transaction with its version bump. v1→v2 is tested against a hand-built v1 file, and was
also observed on a real Phase 1 database on this Mac. A database newer than the app is
refused, not opened.

### Durability: actual settings and guarantees

Applied to every connection (`SQLiteConnection.configureForDurability`). A test reads
them back:

| Setting | Effect |
|---|---|
| `journal_mode = WAL` | Commits append to a write-ahead log. Readers don't block the writer. |
| `synchronous = FULL` | SQLite syncs the WAL to storage at **every** commit, before COMMIT returns. |
| `fullfsync = ON`, `checkpoint_fullfsync = ON` | On Apple platforms, plain `fsync()` doesn't ask the drive to flush its write cache. These make SQLite use `F_FULLFSYNC`, which does. It adds per-commit latency (not measured). |

What a returned save therefore means:

- **Atomic:** a transaction is all-or-nothing, including after a crash mid-write.
- **Survives the app crashing or being killed:** the committed data has reached the OS
  and the file.
- **OS crash or power loss:** SQLite has requested a full flush to storage before
  reporting the commit. Whether the data survives depends on the OS and hardware
  honoring that request. **This is not guaranteed unconditionally, and power loss has
  not been tested.** `fullfsync` is confirmed set on macOS. Its effect on iOS hasn't
  been verified.
- **Not covered:** text typed within the ~0.75 s autosave window before an abrupt
  kill, disk failure, or storage that ignores flush requests.

### When is an edit "saved"?

When `NoteStore.updateNote` returns (transaction committed). The editor autosaves 0.75 s
after the last keystroke. It also saves immediately on selection change, on leaving the
foreground (iOS: inside a background-task assertion), and before Quit on macOS. Saves
are chained, so an older snapshot is never written after a newer one.

### Failure handling

A failed save rolls back, keeps the draft on screen, shows the error with Retry, and
logs it. There's no automatic retry loop. A failed open shows an error, and the file is
never deleted or recreated.

## Concurrency model  [built]

- `NoteStore` and `SyncCoordinator` are **actors**. The store exclusively owns the
  non-`Sendable` SQLite connection. Store methods contain no `await`, so a transaction
  can't be interleaved by actor reentrancy.
- `SyncCoordinator` methods do `await` the store, so engine callbacks can interleave at
  those points. Correctness doesn't depend on that ordering: whether a server version is
  new is decided by comparing **change tags stored in the database**, inside the
  transaction that applies it.
- UI models are `@MainActor`. Only `Sendable` values (`Note`, `RemoteNote`,
  `StoreChange`, …) cross actors.
- Store changes are published as an `AsyncStream`, only after commit. Subscribers
  subscribe *before* spawning their consuming task, so no change slips through (a race
  found and fixed in Phase 2).

## CloudKit sync  [built; unverified on iCloud]

### Setup
- Container `iCloud.com.ayaanchawla.Relay`, **private database**, custom zone `Notes`
  (created through a pending database change, which is idempotent).
- Record type `Note`, **record name = note UUID**. Fields: `title`, `body`, `createdAt`,
  `modifiedAt`, `conflictOf` (String?), `isDeleted` (Int64 0/1).
- Sync is compiled in only with `RELAY_CLOUDKIT`, because creating a `CKContainer`
  without the entitlement crashes.

### Upload path
1. A user edit commits locally (no network involved), and the store's change stream
   tells the coordinator, which adds `.saveRecord(id)` to the engine. If the app dies
   before that, **every** unsynced row is re-added from the database whenever an engine
   is created (each launch, and after account changes). The engine deduplicates.
2. The engine calls `nextRecordZoneChangeBatch`. Relay builds the batch with
   `RecordZoneChangeBatch(pendingChanges:recordProvider:)`, so the engine's per-request
   limit and scope rules are respected. For each record, the coordinator reads the row,
   **remembers the `local_version` it is sending** (`inFlight`), and builds the
   `CKRecord` from the stored system fields so CloudKit can detect conflicts.
3. On success, `markUploaded` sets `synced_version` to **the sent version**, not the
   current one, and stores the new system fields and tag.

**Older upload finishing after a newer edit:** if the user edited during the upload,
`local_version` is still higher than the sent version. The row stays pending and is
re-queued, then uploaded on top of the server version just confirmed. Tested, and
mutation-checked (the test fails if the store marks the current version instead).

**No duplicates on retry:** the record name is the UUID, so a retried save targets the
same record. Applying a fetched or saved version twice is a no-op because the change
tag matches.

### Fetch path
- `fetchedRecordZoneChanges` → `RemoteNote` → `store.applyRemote` → `ConflictResolver`,
  in one transaction.
- **Remote changes are never re-uploaded as local edits:** applying a server version
  never touches `local_version`. A new row from the server starts at version 0/0, which
  means not pending. Tested and mutation-checked.
- **A fetched change for a note whose upload is in flight is skipped.** That upload's
  result covers it: success means the fetched change was our own echo, and
  `serverRecordChanged` carries the newest server version, which is then resolved
  once. Resolving both would create a spurious conflict copy against our own upload.
- Changes are applied before the engine emits the matching `stateUpdate`, and events
  are delivered serially. The persisted state therefore never claims more than the
  database contains. A crash between the two causes a refetch, which is idempotent.

### Errors (`NoteRecord.classify`)
| CKError | Handling |
|---|---|
| networkFailure, networkUnavailable, requestRateLimited, serviceUnavailable, zoneBusy, notAuthenticated, accountTemporarilyUnavailable, operationCancelled | **Transient.** CKSyncEngine retries these itself, respecting server retry-after. Relay doesn't re-queue (test asserts this, mutation-checked). Status: "Will retry automatically." |
| serverRecordChanged | Conflict. Resolve against `error.serverRecord`. |
| unknownItem | Base record is gone. Treated as a hard deletion (an edit recreates it). |
| zoneNotFound, userDeletedZone | Re-add zone save, clear the row's metadata, re-upload. |
| quotaExceeded | Problem shown. Not re-queued, since retrying can't help until the user acts. |
| anything else | "Invalid" problem shown and fault logged. Not re-queued (the same data would fail again). The row stays pending in the database and is re-queued at next launch. |

### Engine state
`stateUpdate` → JSON-encoded `CKSyncEngine.State.Serialization` → `sync_state`. It's
restored at launch. Undecodable state is discarded with a fault log, which is safe:
the engine refetches, and re-applying is idempotent.

## Conflicts  [built]

`ConflictResolver.resolve` (pure, table-tested):

| Local row | Server version | Decision |
|---|---|---|
| any | change tag == our base tag | **ignore** (echo of a version we already have) |
| none | live / tombstone | insert / ignore |
| clean | live / tombstone / gone | apply / delete / delete |
| unsynced edit | live, same content | adopt server metadata, mark synced |
| unsynced edit | live, different content | **server version stays primary; local content saved as a conflict copy** |
| unsynced edit | tombstone or gone | **keep local edit** (edit wins), re-based to overwrite the tombstone |
| unsynced delete | live | **apply server edit** (edit wins; note restored) |
| unsynced delete | tombstone or gone | delete locally |

- The **server version is primary** because every other device already has it.
  Choosing it avoids ping-pong, and the decision is deterministic.
- **Conflict copy** title: "<title> (Conflict copy)", with `conflictOf` = original id.
  Its **id is derived from SHA-256(original id, content)**, so repeated handling of the
  same conflict upserts the same row instead of multiplying copies (tested and
  mutation-checked).
- **Stale editor drafts:** the editor passes the content its draft was based on. If a
  sync replaced the note underneath an unsaved draft, `updateNote` keeps the newer
  stored version as a conflict copy in the same transaction, then writes the draft.
- This is "keep both versions". It isn't a merge, a CRDT, or collaborative editing.

## Deletions  [built]

- **Representation:** a deletion is uploaded as a **tombstone record**: the same record
  with `isDeleted = 1` and title and body cleared. CloudKit record *deletions* don't
  check change tags, so they would silently erase a concurrent edit. A tombstone is an
  ordinary save, so conflicts are detected and **the edit wins in both orders**
  (tested).
- **Local tombstones** (`is_deleted = 1`, content cleared) exist only until the server
  confirms the tombstone save, then they are purged. There is no timer.
- **Server tombstones are retained indefinitely.** They let a long-offline device
  learn about the deletion, and they keep stale edits from resurrecting notes silently.
  The cost is a small content-free record per deleted note. Relay never
  garbage-collects them. Doing that safely would require knowing every device has
  synced, which CloudKit doesn't tell us.
- **Remote deletion of a note open in the editor:** with no unsaved draft, the editor
  closes. With an unsaved draft, the text stays on screen and **Keep as New Note** saves
  it.
- **Zone removed on the server:** `deleted`/`purged` remove synced notes locally,
  keep unsynced edits, and recreate the zone. `encryptedDataReset` re-uploads
  everything.

## Accounts and engine lifecycle  [built; unverified on iCloud]

### Invariants (`SyncCoordinator`)

1. **An engine exists only while the iCloud account is confirmed and owns this
   database.** At launch, the coordinator asks `CKContainer.accountStatus()` and
   `userRecordID()` (through `AccountProvider`) *before* creating `CKSyncEngine`. With no
   account, a mismatched account, or an undetermined account, no engine exists. Nothing
   can deliver changes that would have to be dropped.
2. **Every event is matched to its source engine** (`ObjectIdentifier` of the
   `CKSyncEngine` passed to the delegate). When an account change stops an engine, all of
   its later events are ignored, including fetched changes, send results, batch
   requests, and **state updates**.
3. **Engine state is saved only for the current engine, and only while every fetched
   change it delivered has been applied.** If applying one fails (for example a disk
   error), state saving stops for that engine. The saved state therefore never claims a
   change the database doesn't have.

### Startup decision

| Account (from `AccountProvider`) | Database owner | Result |
|---|---|---|
| available(U) | none | Bind to U (local notes are adopted), fresh engine |
| available(U) | U | Engine from U's saved state |
| available(U) | V ≠ U | **Mismatch, no engine.** UI offers "Use This Account's Notes…" |
| no account / restricted | any | No engine. Notes stay local and editable. |
| temporarily unavailable | any | No engine. Wait for `CKAccountChanged` (Apple's guidance for this status) |
| couldn't determine (e.g. offline) | any | No engine. Retry with backoff (15 s doubling, up to 5 min). No engine exists, so this isn't a retry around CKSyncEngine. |

Re-checks happen on `CKAccountChanged` (cached identity dropped), on returning to the
foreground, and **before every engine fetch and send** (`willFetchChanges` /
`willSendChanges`). Events are delivered serially, so that check finishes before the
operation's results are delivered. A different account at any of these points stops
the engine first, then re-resolves.

The engine's own `accountChange` events are handled the same way. One exception: a
report of the *same* account that is already active (for example a fresh engine
announcing the current user) only re-queues pending work. Treating it as a change
would restart the engine in a loop.

Overlapping resolutions (launch, foreground, and notification at once) are serialized
by a resolution id: one suspended at an `await` gives up if a newer one started. A test
holds two resolutions in flight at once and checks that exactly one engine is created.

### Recovery behavior

| Situation | What happens | How the data comes back |
|---|---|---|
| Account changes during a **fetch** | The engine is stopped. Its remaining fetched changes **and its state update** are ignored. | The saved state predates those changes. When the owner account is active again (now, or after relaunch), a new engine starts from it and refetches. |
| Account changes during an **upload** | The engine is stopped. Its send results are ignored. Rows stay pending. | The next upload carries the old base, so the server replies `serverRecordChanged` with identical content, which resolves to "adopt metadata". No duplicate, no copy (tested). |
| Applying a fetched change **fails** | State saving pauses for that engine. A problem is shown. | At relaunch, or **Sync Now** (which recreates the engine from the saved state), the change is delivered again (tested). |
| Fetched change for a note with an **upload in flight** | Skipped; not counted as a failure. | That upload's result covers it. If the app dies first, the row is still pending, and the re-upload gets `serverRecordChanged` carrying the change (tested). |
| Late events from a stopped engine **after the same account is active again** | Ignored, including its state update. | Tested: a late state update from engine 1 doesn't overwrite engine 2's saved position. |
| Late results from the previous account's engine **after "Use This Account's Notes"** | Ignored. | Tested: nothing from the old account is written into the new database. |

### How this matches CKSyncEngine's documented lifecycle

| Apple documentation says | Relay relies on it as follows |
|---|---|
| Call `accountStatus` "before accessing the private database"; use `CKAccountChanged` and "call this method again" | Account established before the engine exists; re-checked on the notification |
| `temporarilyUnavailable`: "don't enqueue any CloudKit operations… listen for `CKAccountChanged`" | No engine and no timer retry in that state |
| On account change the engine "resets its internal state… clears any pending… changes" | Pending work is re-queued from the database whenever an engine is created or reports the same account |
| Persist state "alongside any changes fetched prior to receiving this state" | State is saved in the same database file, only after the changes before it were applied (invariant 3) |
| "Your delegate won't receive the subsequent event until it finishes processing the current one" | The pre-operation account check and change application finish before later events |
| Initialize the engine with "the most recently persisted state" | Engine created from the last state saved under invariant 3, so it resumes from a position whose changes are all in the database |

### Remaining uncertainties (to check on real devices)

- **Ordering around account switches is inferred, not documented.** Relay assumes an
  engine doesn't deliver records fetched under a *new* account before reporting the
  account change. Re-checking before each fetch narrows the window: the cached identity
  is dropped on `CKAccountChanged`. But if the notification arrives late *and* the
  engine fetches before reporting, records from the new account could reach this
  database. The docs don't say either way.
- **`userRecordID()` offline:** whether it answers from a local cache isn't
  documented. If it doesn't, an offline launch syncs only after the backoff retry,
  foreground, or `CKAccountChanged` succeeds.
- **Does a fresh engine (nil state) emit `signIn` for the current user?** Relay handles
  either way (the same-account report is benign), but it hasn't been observed.
- **`cancelOperations()` is not awaited** when an engine is stopped from inside its own
  callback (awaiting could deadlock). Its later events are ignored by identity, but
  whether a stopped engine keeps making network requests briefly hasn't been observed.
- **A stopped engine's ignored successful save** can cost a spurious conflict copy if
  the user edits the same note again before the next upload. The new engine then sees
  the server ahead of its base with different content. Both versions are kept; nothing
  is lost.

### Account switch and archives

During a mismatch, **Use This Account's Notes…** moves the old database to
`Application Support/Relay/Archived/` (kept, not uploaded, not deleted), opens an empty
database bound to the current account, and creates a fresh engine with no saved state.
There's no UI to restore an archive. If the old account returns, its synced notes
download again, and unsynced edits remain only in the archive file.

## Logging

`os.Logger`, subsystem `com.ayaanchawla.Relay`, categories `Storage`, `Editor`, `Sync`.
Logs contain UUIDs, counts, and error codes, never note content. Unexpected states log
at `fault` level.

## Known limitations

- Real CloudKit behavior (push delivery, the account-change event sequence, the
  `stateUpdate` cadence) is **not yet verified on devices**.
- See "Remaining uncertainties" under Accounts.
- Records over CloudKit's size limit fail as "invalid". There's no pre-validation.
- Archived databases have no restore UI.
- Search is in memory. That suits a personal notes list.

## Attribution

The overall approach to `CKSyncEngine` events and zone/unknown-item recovery was
informed by Apple's sample
[sample-cloudkit-sync-engine](https://github.com/apple/sample-cloudkit-sync-engine)
(MIT License, © 2023 Apple Inc.). No code was copied. Relay's storage, tombstone
deletes, conflict copies, in-flight version tracking, and account binding are its own.
