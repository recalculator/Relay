# Benchmarks

Local performance measurements of Relay's real storage and sync-application code. They
come from `RelayBench`, a Swift command-line target in the RelayCore package. It is
separate from the correctness tests and runs without signing, an Apple account, or
CloudKit.

> **Scope.** These are local measurements on one Mac. Nothing here measures iCloud
> network latency or real CloudKit behavior. The incoming-changes workload uses a
> **simulated** transport. See "Real CloudKit measurements" for the manual plan, which
> hasn't been carried out yet.

## Run it

```sh
Scripts/benchmark.sh                   # release build, all workloads, about 1 minute
Scripts/benchmark.sh --quick           # small smoke run (results ignored by git)
Scripts/benchmark.sh --only save,search
Scripts/fsync-probe.sh                 # which flush calls the save path makes (see Durability)
```

`Scripts/benchmark.sh` builds with `swift build -c release`. It records the Swift and
Xcode versions, the git revision and dirty-file count (read-only `git` commands), and
the power source. Then it runs `Packages/RelayCore/.build/release/RelayBench`. Each run
writes a JSON file to `benchmark-results/` with the environment, per-repetition
summaries, and every raw sample, and prints a summary table.

**Safety.** Every database is created under a new
`$TMPDIR/RelayBench-<UUID>/` directory. The harness refuses paths outside it (and the
app's own `Application Support/Relay` directory), deletes only that directory, and
never creates a CloudKit object. The notes are synthetic.

## Environment of the 2026-10-02 runs

| | |
|---|---|
| Machine | Mac17,2, Apple M5 (10 cores), 16 GB |
| OS | macOS 26.5 (25F71) |
| Toolchain | Xcode 26.6 (17F113), Swift 6.3.3 |
| SQLite | system library 3.51.0 |
| Build | release (`-c release`) |
| Code | `023c369` plus uncommitted working-tree changes (the reentrancy fixes, then the v3 index) |
| Power | AC power, **Low Power Mode ON** (`pmset lowpowermode 1`), thermal state nominal throughout |
| Durability | Relay's own settings, applied by `NoteStore` itself: `journal_mode=WAL`, `synchronous=FULL`, `fullfsync=ON`, `checkpoint_fullfsync=ON` |

**Low Power Mode was on for all four 2026-10-02 runs.** Their before/after comparison
(the v3 index) is valid, since they share conditions. Their absolute numbers are slower
than with Low Power Mode off; see the 2026-10-03 run for numbers with it off.

## Methodology

- **Real code paths.** Only RelayCore's public API, called as the app calls it:
  `NoteStore.updateNote(…, base:)` as the editor's autosave does, `NoteStore.open` +
  `allNotes()` as `NotesModel.open` does, `NotesModel.visibleNotes` for search, and
  `SyncCoordinator.handleFetchedChanges` as the CloudKit adapter does.
- **Durability unchanged.** `NoteStore` applies its pragmas on every connection. The
  harness can't weaken them.
- **Commit mode as in the app.** Saves: one transaction per edit. Incoming changes: one
  transaction per change, as the coordinator applies them. **No batching the app
  doesn't do.**
- **Clock.** `ContinuousClock` (monotonic). Each timed region starts immediately before
  the awaited call and stops when it returns.
- **Setup is untimed.** Each size's template database is built once through
  `NoteStore.applyRemote` (each note inserted as a synced note "downloaded from
  iCloud"). Each repetition gets a **fresh copy** of the closed template file, so
  repetitions start from identical state.
- **Warm-up.** Saves: 50 untimed edits per repetition. Reopen and recovery: 2 untimed
  opens. Search: 3 untimed queries.
- **Repetitions.** 3 independent repetitions per workload and size. The tables report
  pooled statistics, every repetition's median, and a second full run, to show
  variation. **No run or repetition was discarded or selected.**
- **Percentiles: nearest rank.** For n sorted samples, the p-th percentile is the sample
  at 1-based rank ⌈p/100 × n⌉. It's always an observed value, with no interpolation.
  Save latency has 6,000 samples per size (2,000 × 3), so p99 has 60 samples above it.
  Workloads with 30 samples report p95/p99, but with n = 30, p99 is simply the
  maximum.
- **Validation after timing, outside the timed region.** Every workload checks its
  result (see each table). A failed check aborts the run.
- **Determinism.** The data comes from SplitMix64 with a fixed seed (`0x52454C4159`).
  The same seed produces the same notes, edit sequence, and change batch on any
  machine.

### Synthetic notes

Body length bands (an assumption, not measured from real users), uniform within each
band. Text is English words from a fixed vocabulary, with a paragraph break about every
40 words. Titles are 2–7 words. The text is ASCII.

| Share | Body length (characters) | Stands for |
|---|---|---|
| 50% | 50–300 | quick notes |
| 35% | 300–2,000 | typical notes |
| 13% | 2,000–10,000 | long notes, minutes |
| 2% | 10,000–50,000 | very long documents |

Actual generated datasets:

| Notes | Total text | Body median / mean / p95 / max | Mean title |
|---:|---:|---|---:|
| 1,000 | 1.9 MB | 301 / 1,833 / 8,170 / 47,767 chars | 23 chars |
| 10,000 | 19.1 MB | 339 / 1,889 / 8,215 / 49,648 chars | 23 chars |

## Latest run: 2026-10-03, schema v4, Low Power Mode off, battery power

`relaybench-2026-10-03T055853Z-e79d7c1.json`. One full run, made after entry kinds and
revision history were added.

| | |
|---|---|
| Code | `e79d7c1` plus uncommitted v4 changes: the `kind` column, the `note_revisions` table and triggers, and `updateNote(…, kind:, base: NoteContent)` |
| Power | **Battery power, Low Power Mode off**, thermal state nominal throughout |
| Machine, OS, toolchain, SQLite, durability | Same as the 2026-10-02 runs below |

Same harness, seed, dataset (synthetic prose notes, all snippets), and workloads as
before. The template and history features add no workload: neither is on the save,
load, search, sync, or recovery paths measured here, apart from the `kind` column.

| Workload | Variant | Notes | Samples | Median | p95 | p99 | Max | Per-rep medians |
|---|---|---:|---:|---:|---:|---:|---:|---|
| save-latency | updateNote (one transaction per edit) | 1,000 | 2,000 × 3 | 0.166 | 0.992 | 2.68 | 7.19 | 0.155, 0.152, 0.189 |
| reopened-store | NoteStore.open | 1,000 | 10 × 3 | 0.196 | 0.271 | 0.319 | 0.319 | 0.205, 0.179, 0.204 |
| reopened-store | NoteStore.open + allNotes() | 1,000 | 10 × 3 | 1.14 | 1.38 | 1.39 | 1.39 | 1.17, 1.09, 1.15 |
| search | many matches “meeting” | 1,000 | 30 × 3 | 3.77 | 3.89 | 3.99 | 3.99 | 3.80, 3.77, 3.72 |
| search | few matches “zephyrquill” | 1,000 | 30 × 3 | 5.52 | 5.68 | 5.71 | 5.71 | 5.52, 5.51, 5.53 |
| search | no matches | 1,000 | 30 × 3 | 5.51 | 5.65 | 5.69 | 5.69 | 5.49, 5.51, 5.51 |
| incoming-changes | SyncCoordinator.handleFetchedChanges, simulated transport | 1,000 | 1,000 × 3 | 168 | 393 | 393 | 393 | 393, 168, 167 |
| pending-recovery | NoteStore.open + pendingChanges() after close | 1,000 | 10 × 3 | 0.696 | 0.894 | 0.904 | 0.904 | 0.788, 0.672, 0.669 |
| save-latency | updateNote (one transaction per edit) | 10,000 | 2,000 × 3 | 0.406 | 2.65 | 4.22 | 23.21 | 0.490, 0.365, 0.342 |
| reopened-store | NoteStore.open | 10,000 | 10 × 3 | 0.281 | 0.523 | 0.550 | 0.550 | 0.297, 0.278, 0.279 |
| reopened-store | NoteStore.open + allNotes() | 10,000 | 10 × 3 | 9.93 | 10.34 | 10.44 | 10.44 | 9.93, 9.77, 9.99 |
| search | many matches “meeting” | 10,000 | 30 × 3 | 37.54 | 38.56 | 40.88 | 40.88 | 37.31, 37.48, 37.57 |
| search | few matches “zephyrquill” | 10,000 | 30 × 3 | 57.11 | 57.57 | 58.24 | 58.24 | 57.03, 57.05, 57.17 |
| search | no matches | 10,000 | 30 × 3 | 56.89 | 57.46 | 59.81 | 59.81 | 56.99, 56.88, 56.81 |
| incoming-changes | SyncCoordinator.handleFetchedChanges, simulated transport | 10,000 | 1,000 × 3 | 407 | 533 | 533 | 533 | 533, 407, 387 |
| pending-recovery | NoteStore.open + pendingChanges() after close | 10,000 | 10 × 3 | 2.47 | 2.72 | 2.81 | 2.81 | 2.39, 2.51, 2.46 |

Incoming-change throughput: 1,000-entry database, about 6,000 changes/s in two
repetitions and about 2,500 in the first (393 ms). 10,000-entry database, about
1,900–2,600 changes/s.

**This is not a before/after comparison.** Three things changed at once since the
2026-10-02 runs: Low Power Mode (on → off), the power source (AC → battery), and the
code (schema v3 → v4). Medians are roughly half the earlier ones for CPU-bound work
(search at 10,000 entries: 113 → 57 ms; list load: 21.5 → 9.9 ms), which is consistent
with Low Power Mode being off, but this run can't separate the three causes. Save
latency **tails** were worse than in the earlier runs (p95 0.99 ms at 1,000 entries,
against about 0.45 ms). The first incoming-changes repetition at 1,000 entries took
2.3× the other two. Neither was investigated. Treat them as run-to-run variation on
battery power.

## Earlier results: 2026-10-02, schema v3, Low Power Mode ON, AC power

Times in milliseconds. These come from `relaybench-2026-10-02T042039Z` (run 1), with
`…042134Z` (run 2) in the last column.

| Workload | Variant | Notes | Samples | Median | p95 | p99 | Max | Per-rep medians | Run 2 median / p99 |
|---|---|---:|---:|---:|---:|---:|---:|---|---:|
| save latency | `updateNote` | 1,000 | 2,000 × 3 | 0.257 | 0.445 | 1.20 | 5.62 | 0.256, 0.257, 0.258 | 0.262 / 0.955 |
| save latency | `updateNote` | 10,000 | 2,000 × 3 | 0.475 | 1.14 | 2.11 | 29.29 | 0.475, 0.466, 0.484 | 0.457 / 2.44 |
| reopened store | `NoteStore.open` | 1,000 | 10 × 3 | 0.398 | 0.464 | 0.498 | 0.498 | 0.382, 0.390, 0.407 | 0.378 / 0.494 |
| reopened store | `open` + `allNotes()` | 1,000 | 10 × 3 | 2.31 | 2.45 | 2.50 | 2.50 | 2.31, 2.25, 2.36 | 2.21 / 2.53 |
| reopened store | `NoteStore.open` | 10,000 | 10 × 3 | 0.618 | 0.703 | 0.708 | 0.708 | 0.641, 0.603, 0.630 | 0.603 / 0.898 |
| reopened store | `open` + `allNotes()` | 10,000 | 10 × 3 | 21.53 | 22.41 | 22.50 | 22.50 | 21.58, 21.31, 21.60 | 21.09 / 22.95 |
| search | many matches (297) | 1,000 | 30 × 3 | 7.71 | 7.79 | 7.85 | 7.85 | 7.72, 7.71, 7.71 | 7.68 / 8.13 |
| search | few matches (10) | 1,000 | 30 × 3 | 11.00 | 11.09 | 11.11 | 11.11 | 10.98, 11.00, 11.00 | 11.06 / 11.52 |
| search | no matches | 1,000 | 30 × 3 | 10.97 | 11.08 | 11.11 | 11.11 | 10.97, 10.98, 10.96 | 11.06 / 11.96 |
| search | many matches (2,908) | 10,000 | 30 × 3 | 73.73 | 76.16 | 77.21 | 77.21 | 74.95, 73.59, 73.20 | 73.26 / 90.26 |
| search | few matches (10) | 10,000 | 30 × 3 | 113.4 | 116.3 | 116.5 | 116.5 | 116.0, 113.3, 113.1 | 113.6 / 115.9 |
| search | no matches | 10,000 | 30 × 3 | 112.2 | 113.5 | 114.0 | 114.0 | 111.8, 112.0, 113.1 | 114.3 / 153.8 |
| incoming changes (batch of 1,000) | simulated transport | 1,000 | 1 batch × 3 | 306 | — | — | 318 | 318, 306, 304 | 314 |
| incoming changes (batch of 1,000) | simulated transport | 10,000 | 1 batch × 3 | 536 | — | — | 597 | 597, 396, 536 | 489 |
| pending recovery (600 pending) | `open` + `pendingChanges()` | 1,000 | 10 × 3 | 1.33 | 1.48 | 1.54 | 1.54 | 1.32, 1.26, 1.42 | 1.42 / 1.70 |
| pending recovery (600 pending) | `open` + `pendingChanges()` | 10,000 | 10 × 3 | 5.27 | 5.87 | 5.90 | 5.90 | 5.37, 5.13, 5.26 | 5.99 / 8.44 |

**Incoming-change throughput** (batch size ÷ batch time): 1,000-note database: about
3,150–3,300 changes/s across both runs. 10,000-note database: about 1,700–2,600
changes/s. At 10,000 notes, one repetition per run was markedly faster (396 and 382 ms,
against 489–597 ms for the others). The cause wasn't investigated. Treat that workload's
spread as real.

### What each workload measures, and what it doesn't

**1. Save latency.** The time for `updateNote` to return. That covers the actor hop, a
transaction that reads the row, writes the new content, and bumps `local_version` (the
pending-sync marker), and `COMMIT` with Relay's durability settings. Each edit appends
1–3 words to a random existing note. It **excludes** the editor's 0.75 s debounce, the
UI, and the app's reload of the notes list after the save (that's workload 2's
`allNotes()`, which the app runs after every committed change). Validation: the
pending set equals the set of edited notes, and every edited note's stored body equals
the last text saved.

Tail: the maximum (up to 29–37 ms at 10,000 notes across runs) is far above p99
(about 2–3 ms). A plausible cause is WAL checkpoints, which SQLite runs automatically
about every 1,000 WAL pages. **Not verified.**

**2. Reopened-store open and load.** `NoteStore.open` (connect, durability pragmas,
schema check) and then `allNotes()`, as at app launch. The file was written moments
earlier and the OS cache wasn't flushed, so this is **warm-cache reopen time, not
cold-disk launch time**. It doesn't include SwiftUI rendering. Validation: the loaded
count equals the notes in the database.

**3. Search.** `NotesModel.visibleNotes` with `searchText` set: the in-memory
`localizedStandardContains` filter the list runs on every render, timed alone on the
main actor after loading. It's the **filter computation only, not end-to-end UI
latency.** Validation: the result ids equal the notes whose lowercased title or body
contains the query (equivalent on this ASCII dataset).

**4. Incoming changes.** One batch of 1,000 fetched changes, delivered to
`SyncCoordinator.handleFetchedChanges` by a **simulated** engine with a fake signed-in
account. **This is local processing time, not CloudKit network throughput.** The batch,
in shuffled order:

| Changes | What they are |
|---|---|
| 400 | new notes |
| 300 | edits to notes with no local changes |
| 200 | tombstones |
| 100 | edits to notes with unsynced local edits, which become conflicts |

It includes conflict resolution, conflict-copy creation, one transaction per change,
the session-fence check, and re-queuing pending work. Validation:

- the live-note count
- created, edited, and deleted content
- the server version is primary for each conflict
- exactly 100 conflict copies containing the local text
- the pending set and the engine's queue both equal the copies

**5. Pending recovery.** 500 edits, 50 deletes, and 50 creates are committed offline
and the store is closed. Then the timed part: reopening and running `pendingChanges()`,
the query the coordinator uses to re-queue all unsynced rows whenever an engine starts.
Validation: the recovered set and the kinds (save or delete) match all 600 changes.

## Optimization: notes-list index (schema v3)

**Bottleneck.** At 10,000 notes, `open` + `allNotes()` took about 58 ms, 24× the
1,000-note time for 10× the notes. `EXPLAIN QUERY PLAN` for
`SELECT … FROM notes WHERE is_deleted = 0 ORDER BY modified_at DESC, id` showed
`SCAN notes` + `USE TEMP B-TREE FOR ORDER BY`: every live row, bodies included, was
copied into a temporary B-tree and sorted. **The app reloads the list after every
committed change**, so this ran after every save, not only at launch.

**Change.** Migration v3 adds
`CREATE INDEX notes_live_by_modified ON notes(is_deleted, modified_at DESC, id)`. The
query is identical, and its results and order are the same (the index matches the
`ORDER BY` exactly). A test asserts that the plan of the exact query `allNotes()` runs
uses the index and has no temp B-tree. Removing the index makes that test fail.

**Equivalent comparison.** Same harness, seed, data, durability settings, and machine
conditions. Two full runs before (`…041650Z`, `…041839Z`) and two after (`…042039Z`,
`…042134Z`), back to back:

| Metric | Notes | Before median (run 1 / 2) | After median (run 1 / 2) | Before p99 | After p99 |
|---|---:|---:|---:|---:|---:|
| `open` + `allNotes()` | 1,000 | 2.44 / 2.33 | 2.31 / 2.21 | 2.83 / 2.65 | 2.50 / 2.53 |
| **`open` + `allNotes()`** | **10,000** | **57.80 / 57.66** | **21.53 / 21.09** | 61.64 / 62.84 | 22.50 / 22.95 |
| save latency | 1,000 | 0.242 / 0.238 | 0.257 / 0.262 | 0.799 / 0.827 | 1.20 / 0.955 |
| save latency | 10,000 | 0.414 / 0.446 | 0.475 / 0.457 | 1.90 / 2.87 | 2.11 / 2.44 |
| incoming batch of 1,000 | 1,000 | 284 / 284 | 306 / 314 | | |
| incoming batch of 1,000 | 10,000 | 448 / 441 | 536 / 489 | | |
| pending recovery | 10,000 | 5.33 / 5.38 | 5.27 / 5.99 | 6.45 / 6.13 | 5.90 / 8.44 |

**Result.** Loading 10,000 notes is about **2.7× faster** (58 → 21 ms). At 1,000 notes
the difference is within noise. **Tradeoff:** every write now also maintains the index.
Save medians rose about 3–15% (0.24 → 0.26 ms at 1,000 notes), and incoming-batch
times rose about 8–22%. Search and recovery are unchanged, as expected. In the app,
each save is followed by a list reload, so at 10,000 notes the total per-save work fell
from about 58 ms to about 22 ms.

## Findings not acted on

**Search scales with total text.** It takes about 11 ms at 1,000 notes and about
113 ms at 10,000 notes (19 MB) per evaluation, on the main actor, on every keystroke.
Profiling in a scratch program (not committed), at 10,000 notes, no-match query:

| Variant | Median | Notes |
|---|---:|---|
| current filter | 112 ms | |
| same call with the locale hoisted | 111 ms | no gain: the cost is the matching itself, about 170 MB/s |
| pre-converted UTF-16 `NSString`s, same method | 93 ms | +38 MB memory, and the cache would need rebuilding after every save, because the list reloads |
| same predicate over all cores (`concurrentPerform`) | 52 ms | 2.2× using 10 cores, still well over a 16 ms frame |

None of these is a clean win with identical semantics. Real fixes would change
behavior: an FTS5 index (token-based, not substring matching), or running the search
off the main actor with debouncing. That's a product decision, so it's left open.

**Per-change commits dominate incoming-change cost.** Applying all of a fetched batch
in one transaction would mean far fewer flushes, but it changes failure behavior: one
bad change would roll back the whole batch. Not done. The app doesn't batch, so the
benchmark doesn't either.

## Durability: what a "durable save" is on this Mac

`Scripts/fsync-probe.sh` runs the quick save workload with a library that counts flush
system calls. Result: **`F_FULLFSYNC = 0`, `F_BARRIERFSYNC = 1,440`, `fsync = 7`** for
about 1,440 commits. On this macOS version, the system SQLite turns
`fullfsync = ON` into one `F_BARRIERFSYNC` per WAL commit, not a full drive-cache
flush. A raw `F_FULLFSYNC` costs about 4 ms on this Mac (barrier: about 0.2 ms), so
the sub-millisecond save latency above **is the cost of a barrier sync, not of a full
flush**. ARCHITECTURE.md → Durability has what that means for power loss.

## Limitations

- One machine, one OS version, warm OS file cache. The 2026-10-02 runs had Low Power
  Mode on; the 2026-10-03 run was on battery power. No run so far has had both AC power
  and Low Power Mode off. iOS not measured.
- Synthetic, ASCII, English-word notes. Real notes (non-ASCII text, other scripts) may
  search at a different speed. The size distribution is an assumption.
- Reopen numbers are warm-cache. True cold-disk launch time wasn't measured, because
  the OS file cache can't be reliably flushed without privileges.
- The incoming-changes transport is simulated. It doesn't measure CloudKit,
  networking, CKSyncEngine scheduling, or push delivery.
- Three repetitions per configuration, and two full runs. Enough to see stable medians
  and the incoming-changes spread, not to characterize rare tail events.
- The cause of the save-latency maximum (checkpoints?) and of the incoming-changes
  spread wasn't verified.

## Real CloudKit measurements (planned, not yet performed)

These need two real devices on one iCloud account (README → "Enabling iCloud sync").
**Don't subtract timestamps taken on two different devices.** Their clocks aren't
synchronized closely enough. Use one clock for both ends:

**Method: one video, both screens.** Film both devices in the same frame (a third
phone at 60 fps, or the Mac's screen recording with the iPhone mirrored via iPhone
Mirroring). Read both events off the same video timeline. The resolution is one frame
(about 17 ms), well below expected sync latencies.

| Measurement | Start (on video) | End (on video) | Trials |
|---|---|---|---|
| Edit propagation, automatic | A's editor shows "Saved on this device" | text appears on B (app in foreground) | ≥ 10 |
| Edit propagation, user-requested | tap Diagnostics → Sync Now on B after A shows "All changes uploaded" | text appears on B | ≥ 10 |
| Offline edit delivery | Wi-Fi turned back on for A (A's edit was saved offline earlier) | text appears on B | ≥ 5 |
| Conflict outcome | both devices edited offline, then reconnected | record: both versions present, exactly one conflict copy, no duplicates after a further sync | ≥ 3 |
| Deletion outcome | delete on A | record: gone on B; Console shows tombstone (`isDeleted = 1`, empty fields) | ≥ 3 |

For each trial, record:

- date and time, devices, OS versions
- network (same Wi-Fi?) and Low Power Mode
- whether B was in the foreground or background, and whether it used automatic sync or
  Sync Now
- the outcome

Report the median and the full range per condition. Keep automatic sync and
user-requested sync separate. CKSyncEngine schedules automatic syncs at its own
discretion ("indeterminate" per Apple's documentation), so a handful of trials
describes this setup on that day, **not a latency guarantee**.

## Files

- `Packages/RelayCore/Benchmarks/RelayBench/`: the harness (`Dataset.swift`,
  `Workloads.swift`, `Measure.swift`, `Workspace.swift`, `main.swift`).
- `Scripts/benchmark.sh`, `Scripts/fsync-probe.sh`, `Scripts/fsync-probe/interpose.c`
- `benchmark-results/*.json`: raw results, never overwritten (one timestamped file per
  run):
  - `…2026-10-02T041650Z`, `…041839Z`: schema v2, Low Power Mode **on**, AC power
    (before the v3 index)
  - `…2026-10-02T042039Z`, `…042134Z`: schema v3, Low Power Mode **on**, AC power
  - `…2026-10-03T055853Z`: schema v4, Low Power Mode **off**, **battery** power
