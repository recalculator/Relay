# Testing

There are three different kinds of evidence. Don't confuse them:

1. **Automated tests with local storage.** Real SQLite files.
2. **Automated tests with a SIMULATED server.** `FakeCloud` and `FakeSyncEngine`
   (`Tests/RelayCoreTests/SyncTestSupport.swift`) stand in for iCloud and CKSyncEngine.
   They show that Relay's *logic* handles the simulated situations. **They aren't
   evidence that iCloud sync works.**
3. **Manual verification against real CloudKit** on two devices. This is the only
   evidence of working sync. Status: **not yet performed.** It's blocked on developer
   account setup (see below).

## Running

```sh
swift test --package-path Packages/RelayCore
xcodebuild test -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS'
```

Last recorded results (2026-10-03, macOS 26.5, Xcode 26.6, Swift 6.3.3, working tree on
top of `e79d7c1`):
- `swift test`: **123 tests in 22 suites passed** (after both features).
- The macOS app builds with and without `RELAY_CLOUDKIT`. Not signed, not run with
  CloudKit. The iOS target isn't built: the iOS platform isn't installed.

2026-10-02: 94 tests in 16 suites under `swift test` and `xcodebuild test`. The 29
account-lifecycle and reentrancy tests passed 25 of 25 consecutive runs.
Earlier (2026-10-01): 87 tests in 14 suites, repeated 25 times.

Benchmarks are separate from these tests: see BENCHMARKS.md.

## How the simulation works

- `FakeCloud` enforces CloudKit's save rule: a save must be based on the server's
  current change tag, otherwise it fails with a conflict carrying the server's version.
  A save of an unknown base fails with `recordMissing`. Failures can be injected
  (`failNextSaves`).
- `FakeSyncEngine` models one engine instance's documented lifecycle: it's created
  from a saved state (here, its fetch position in `FakeCloud`'s change log), and it
  delivers fetched changes *then* a state update. It deduplicates pending saves,
  removes them when they're taken for sending, and *retains* them after transient
  failures. It records every call the coordinator makes, so tests can assert what Relay
  did *not* do. Each instance has its own identity, so tests can deliver events from a
  stopped engine.
- `FakeAccountProvider` controls what iCloud reports (available user, no account,
  temporarily unavailable, couldn't determine). It can also hold queries so overlapping
  resolutions happen deterministically.
- `SyncCoordinator.Checkpoint` (a test-only hook, `nil` in the app) lets
  `CheckpointPause` suspend the coordinator at a chosen `await`. The test changes
  accounts or replaces the database there, then resumes it. This is how reentrancy is
  tested without timing.
- `ManualSleeper` replaces the account-retry delay. A retry happens only when the test
  releases it.
- `SimulatedDevice` = a real `NoteStore` file + a real `SyncCoordinator` + the fakes.
  `beginSend` / `finishSend` split an upload so a test can edit while it is in flight.
- Determinism: no sleeps. Clocks are injected. Background change-stream observers are
  turned off in multi-device tests, which announce changes explicitly. The stream path
  has its own test that awaits the engine call. One test has a time limit, so a
  regression fails instead of hanging.

## Coverage

| Requirement | Test(s) | Kind |
|---|---|---|
| CRUD, ordering, exact text round-trip | `NoteStore/*` | local |
| Persistence across reopen; pending changes survive restart | `notesPersistAcrossReopen`, `pendingChangesSurviveReopen` | local |
| Local save failure: data unchanged, store recovers; draft kept in UI | `failedWriteLeaves…`, `failedSaveKeepsDraft…` | local |
| Migration v1→v2 keeps data and pending work | `v1DatabaseMigratesToCurrent…` | local |
| Durability pragmas actually applied | `durabilityPragmasAreApplied` | local |
| Upload marks synced, stores metadata | `uploadMarksNoteSynced…` | simulated |
| **Older upload completing after a newer edit** | `olderUploadCompletingAfterNewerEdit…` | simulated |
| Transient failure: work kept, engine retries, coordinator does **not** re-queue, no duplicate record | `retryAfterTransientFailure…` | simulated |
| Non-retryable failure: kept locally, not re-queued | `nonRetryableFailure…` | simulated |
| **Remote changes not re-uploaded as local edits** | `remoteChangesAreNotUploadedAgain`, `cleanEditorAdoptsRemoteEdit` | simulated |
| Re-applying a fetched change is a no-op | `applyingTheSameFetchedChangeTwice…` | simulated |
| Echo of own upload ≠ conflict | `echoOfOwnUpload…` | simulated |
| Fetched change for in-flight note deferred to send result | `fetchedChangeForInFlightNote…` | simulated |
| **Concurrent edits preserve both versions, both devices converge** | `concurrentEditsPreserveBothVersions…` | simulated |
| Identical concurrent edits → no copy | `identicalConcurrentEdits…` | simulated |
| **Repeated conflict handling doesn't multiply copies** | `repeatedConflictHandling…` | simulated |
| Stale editor draft keeps newer stored version as a copy | `draftBasedOnStaleContent…` | local |
| **Remote deletion; local tombstone purged after confirmation** | `remoteDeletionRemovesNote…` | simulated |
| **Edit vs delete: edit wins, both orders** | `editWinsWhenDeleteReachesServerSecond`, `editWinsWhenDeleteReachesServerFirst(×2)` | simulated |
| Hard-deleted record with local edit recreated | `hardDeletedRecordWithLocalEdit…` | simulated |
| Zone purged / encrypted data reset | `purgedZone…`, `encryptedDataReset…` | simulated |
| Pending work + engine state restored at launch | `pendingWorkAndEngineStateSurviveRestart` | simulated |
| **No engine until the account is established**; first account adopts; owner gets saved state; different account at launch → mismatch with no engine | `Account lifecycle: startup ownership validation` | simulated |
| `temporarilyUnavailable` waits for `CKAccountChanged` (no timer); undetermined account retried with backoff | `temporarilyUnavailable…`, `undeterminedAccountIsRetried…` | simulated |
| Overlapping resolutions create exactly one engine; checks before start are ignored | `overlappingResolutions…`, `accountChecksBeforeStart…` | simulated |
| Benign same-account report from a fresh engine doesn't restart it | `benignSignInFromFreshEngine…` | simulated |
| **Events before account initialization** change nothing; changes from that period are fetched once the account is known | `Account lifecycle: events before initialization` | simulated |
| **Account change during upload**: late results ignored, recovered without duplicates | `accountSwitchDuringUpload…` | simulated |
| **Account change during fetch**: later changes neither applied nor persisted, redelivered later | `accountSwitchDuringFetch…`, `lateStateUpdateFromStoppedEngine…` | simulated |
| Pre-fetch revalidation catches an unreported account change | `revalidationBeforeAFetch…` | simulated |
| Old account's late results never touch the fresh database | `resultsFromThePreviousAccountsEngine…` | simulated |
| Sign-out keeps notes; same account resumes | `signOutDuringSync…` | simulated |
| Mismatch blocks upload, fetch, state persistence | `mismatchBlocksUploads…` | simulated |
| **Restart after a rejected event** (apply failed) redelivers it; Sync Now recovers in-session | `changeThatFailedToApply…`, `syncNowRecreatesTheEngine…` | simulated |
| **Restart after a deferred/ignored event** redelivers or recovers it | `changesIgnoredFromAStoppedEngine…`, `deferredInFlightChange…` | simulated |
| Account switch archives old database intact | `startingFreshArchives…` | simulated |
| **Fetched batch stops when the database is replaced part-way**; nothing reaches the new account's database | `fetchedBatchStopsWhenTheDatabaseIsReplacedPartWay` | simulated |
| **Upload results stop when the account changes part-way**; recovers without duplicates | `sendResultsStopApplyingWhenTheAccountChangesPartWay` | simulated |
| A stopped engine's late results don't consume a newer engine's in-flight entry | `lateResultsFromAStoppedEngine…` | simulated |
| **Sync Now doesn't restart sync after the account changed while it waited** | `syncNowDoesNotRestart…` | simulated |
| A stale account check doesn't replace the fresh database's engine | `accountResolutionInFlightIsAbandoned…` | simulated |
| Store rejects sync writes from an ended session or another owner, inside the transaction | `writesFromAnEndedSessionOrAnotherOwnerChangeNothing` | local |
| Notes-list query uses the v3 index (no temp B-tree sort) | `loadingTheNotesListUsesTheIndexInsteadOfSorting` | local |
| Template grammar, repeated placeholders, malformed syntax and line, empty values, literal non-recursive substitution, Unicode and multiline | `Command templates (pure)` | pure |
| Unknown or missing stored kind reads as snippet | `entryKindDecodesUnknownValuesAsSnippet`, `recordsFromOlderBuilds…` | pure / local CloudKit types |
| v1 → current migration keeps content; existing rows become snippets | `v1DatabaseMigratesToCurrent…` | local |
| CloudKit record carries `kind` and exactly the synced fields (no history) | `recordRoundTrips…`, `recordContainsExactlyTheSyncedFields` | local CloudKit types |
| A kind change is a content change in conflicts; snippet copy ids unchanged | `aKindChangeIsAContentChange`, `conflictCopyIdentity…` | pure |
| Kind and multiline template body sync; concurrent kind change keeps both versions | `Entry kinds through storage and simulated sync` | simulated |
| Editor kind change saved via `updateNote`, pending with a bumped version | `changingTheKindIsSavedAndQueuedForUpload` | local |
| Checkpoints survive restart; identical consecutive checkpoints are no-ops; 50-per-entry retention | `checkpointsSurviveRestart`, `identicalConsecutiveCheckpoints…`, `historyKeepsOnlyTheNewest…` | local |
| **Restore keeps the current version, is a new pending edit (version never reset), uploads without a conflict** | `restoreKeepsTheCurrentVersionAndUploadsTheRestoredOne` | simulated |
| **Injected failure during restore rolls back checkpoint, content, and pending marker** | `restoreFailureRollsBackEverything` | local |
| Restore of a deleted entry or another entry's revision is rejected; history deleted with the entry | `restoringADeletedEntryOrAForeignRevision…` | local |
| Save Version / History model: draft saved first, then preserved by restore | `restoreSavesTheDraftFirstAndUpdatesTheEditor` | local |
| Line diff: identical, insertion, deletion, changed line, empty texts, trailing newline | `Line diff (pure)` | pure |
| Conflict copies of identical content in unrelated notes stay distinct | `identicalContentConflictingInUnrelatedNotes…`, `conflictCopyIdentity…` | simulated / pure |
| Remote deletion with unsaved draft → Keep as New Note | `draftOfNoteDeletedElsewhere…`, `cleanEditorCloses…` | local |
| Conflict decision table; deterministic copy ids | `ConflictResolver (pure)` | pure |
| CKRecord mapping, system-fields round trip, CKError classification | `CloudKit record mapping` | local CloudKit types, no network |
| Status text never claims "uploaded" with pending work | `Sync status summary` | pure |

### Mutation checks (2026-10-01)

To confirm the key tests can fail, each safeguard below was deliberately broken, the
suite was run, and the code was restored. All of the following were caught:

| Mutation | Caught by |
|---|---|
| Mark synced to current (not sent) version | `olderUploadCompletingAfterNewerEdit…` |
| Apply fetched change to an in-flight note | `fetchedChangeForInFlightNote…` |
| Count a remote write as a local edit | `editWinsWhenDeleteReachesServerSecond`, `cleanEditorAdoptsRemoteEdit` |
| Remove the upload account gate (both checks) | `eventsArrivingBeforeAnEngineExists…`, `mismatchBlocksUploads…` |
| Random (non-deterministic) conflict-copy id | `repeatedConflictHandling…` |
| Conflict-copy id ignores the original note | `identicalContentConflictingInUnrelatedNotes…`, `conflictCopyIdentity…` |
| Drop the change-tag echo check | several, including `echoOfOwnUpload…` and the decision table |
| Delete wins over edit | decision table, `editWinsWhenDeleteReachesServerFirst` |
| Coordinator re-queues transient failures | `retryAfterTransientFailure…` |
| Apply fetched changes from a stopped engine | `accountSwitchDuringFetch…` and three others |
| Persist state from a stopped engine | `lateStateUpdateFromStoppedEngine…`. Initially **missed**; that test was added. |
| Persist state after an unapplied change | `changeThatFailedToApply…`, `syncNowRecreates…` |
| Apply send results from a stopped engine | `resultsFromThePreviousAccountsEngine…`. Initially **missed**; that test was added. |
| Create the engine before resolving the account | eleven tests, including `noEngineExistsUntilTheAccountIsKnown` |
| Treat a same-account report as an account change | `benignSignInFromFreshEngine…` |
| Skip the pre-operation account check | `revalidationBeforeAFetch…` |
| Activate on mismatch at launch | `differentAccountAtLaunchIsAMismatch…` and others |
| Retry on `temporarilyUnavailable` | `temporarilyUnavailableWaits…` |
| Resolve before `start` | `accountChecksBeforeStartAreIgnored` |
| Drop the superseded-resolution check | `overlappingResolutions…`. Initially **missed** because the test didn't really overlap; the test was fixed. |

### Mutation checks (2026-10-02): reentrancy and index

All five reentrancy tests **failed against the code before the fix** (the
send-results test only after it was strengthened to check server metadata). Then each
new safeguard was removed:

| Mutation | Result |
|---|---|
| Drop the per-iteration lease check in the upload-results loop | Caught: `lateResultsFromAStoppedEngine…` |
| Drop the lease re-check in Sync Now | Caught: `syncNowDoesNotRestart…` |
| Disable the store's fence check | Caught: `writesFromAnEndedSession…` |
| Drop the fence check **and** the fetch-loop lease check | Caught: `fetchedBatchStops…` |
| Drop only the fetch-loop lease check | **Not caught.** The store fence still rejects the stale writes. |
| Drop the fetch-loop lease check and write to `self.store` instead of `lease.store` | **Not caught.** The fence's owner check rejects the write into the other account's database. |
| Remove the v3 index | Caught: `loadingTheNotesList…`, `v1DatabaseMigrates…` |

The two "not caught" rows are expected: each layer alone prevents that bug, so
removing one of them is masked by the other.

Not covered by a failing test: the `tearDownEngine()` at the start of `activate`. With
the superseded-resolution check in place, no second activation can happen, so removing
it changes no observable behavior. It's kept as a one-line local guarantee.

## Manual verification

### Local app (macOS)

Run the **Relay** scheme on **My Mac** (`open Relay.xcodeproj`, then ⌘R). The status
area says "iCloud sync isn't enabled in this build". Use throwaway entries: they upload
once iCloud is enabled.

**Verified manually by the developer (reported 2026-10-03, on the schema v3 build
`e79d7c1`):**
- [x] Create an entry and edit it. The bar reaches "Saved on this device".
- [x] Quit (⌘Q) and relaunch: the content is still there.
- [x] Type, press ⌘Q immediately, relaunch: the last characters survived.

**Not yet verified manually:**
- [ ] Switch between two entries while typing; both keep their text.
- [ ] Delete an entry (right-click → Delete), relaunch; it stays gone.
- [ ] Search filters by title and body; no matches shows the empty state.
- [ ] First launch of the v4 build migrates the existing database; earlier entries
      appear as Snippets with their text intact.

**Templates (v4 build), not yet verified:**
- [ ] ⇧⌘N creates a Template; the picker shows Template; the body is monospaced.
- [ ] Typing `"` and `--` in the body keeps straight quotes and two hyphens.
- [ ] Body `ssh {{user}}@{{host}} -p {{port}}`: the summary lists user, host, port.
- [ ] ⇧⌘C opens Fill Template with three fields in that order; Copy is disabled until
      all three are filled; the preview updates as you type.
- [ ] Use `{{host}}` twice: one field fills both.
- [ ] Add `{{bad name}}`: the warning names its line; the preview keeps it literally.
- [ ] Enter `{{port}}` as a value: the copied text contains `{{port}}` literally.
- [ ] Copy, paste into TextEdit: it matches the preview. Close and reopen the sheet:
      the fields are empty (values aren't kept).
- [ ] Switch a snippet to Snippet type; ⇧⌘C copies its text directly ("Copied").
- [ ] The template icon shows in the list; VoiceOver reads it as "Template".

**History (v4 build), not yet verified:**
- [ ] ⌘Y on a new entry shows "No Saved Versions".
- [ ] Type, then ⌘S *without pausing*: "Version saved", and History shows the text just
      typed. ⌘S again: "No changes since the last saved version".
- [ ] Edit, ⌘Y: the Changes view shows − and + lines; Version shows the old text.
- [ ] Restore → confirm: the editor shows the old text. Reopen History: the newest
      entry says "Saved before a restore" and holds the text you replaced.
- [ ] Quit and relaunch: history and restored content are still there.
- [ ] Delete the entry: its history goes with it (no orphans:
      `SELECT COUNT(*) FROM note_revisions WHERE note_id NOT IN (SELECT id FROM notes)`
      returns 0).

Optional database inspection:
```sh
sqlite3 ~/Library/Containers/com.ayaanchawla.Relay/Data/Library/Application\ Support/Relay/Notes.sqlite \
  "PRAGMA user_version; SELECT id, kind, is_deleted, local_version, synced_version FROM notes;"
```

### Real CloudKit sync (Phase 3), not yet performed

Prerequisites: README → "Enabling iCloud sync". Two devices on the **same** iCloud
account. CKSyncEngine relies on push notifications, and **Simulators can't receive
them**, so use this Mac plus an iPhone (or a second Mac). A Simulator syncs only on
launch or via Diagnostics → Sync Now.

Record the result of each step (pass/fail, date, OS versions). Also confirm that an
entry's **type** (Snippet or Template) arrives on the other device, and that its
History does **not** (history is local by design):

1. **First sync:** on device 1, create "Note A". Within a short time, it appears on
   device 2. In CloudKit Console (Development) → Private DB → zone `Notes`, the record
   name is the note's UUID.
2. **Offline edit:** turn off Wi-Fi on device 1 and edit Note A. The status shows
   "1 change not uploaded yet". Quit and relaunch: the edit and the pending count remain.
   Reconnect: the status changes to "All changes uploaded", and device 2 shows the edit.
3. **In-flight edit:** on a slow network, type continuously in Note A. The final text
   on device 2 matches device 1 once both are idle.
4. **Conflict:** take both devices offline and edit Note A differently on each.
   Reconnect device 1, then device 2. Both devices show Note A (device 1's text) and
   "Note A (Conflict copy)" (device 2's text). Sync again: no further copies appear.
5. **Delete:** delete Note A on device 1. It disappears from device 2. In the Console,
   the record remains with `isDeleted = 1` and empty title and body.
6. **Edit vs delete:** with both offline, delete Note B on device 1 and edit it on
   device 2. Reconnect both: Note B exists on both with device 2's text.
7. **Account separation (optional, needs a second Apple ID):** sign the Mac into
   another account. Relay shows "These notes belong to a different iCloud account. Sync
   is paused." Confirm that no records appear in the second account's Console.
8. **Diagnostics:** in a Debug build, double-click the status area. Check that pending
   count, last send/fetch, and recent events match what happened.

Also watch Console.app with the filter `subsystem:com.ayaanchawla.Relay` for `fault`
messages during these steps.
