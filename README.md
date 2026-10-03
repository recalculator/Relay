# Relay

Relay is an offline-first Swift library of reusable developer commands and snippets,
with parameterized templates, recoverable revisions, and conflict-aware syncing. It's a
native macOS app (an iOS target exists) written in Swift and SwiftUI. The engineering
focus is on what you can't see: durable SQLite persistence, explicit iCloud sync with
`CKSyncEngine`, clear concurrency, and tests aimed at data integrity.

> **Status.** Templates, revision history, and local persistence work and are tested.
> CloudKit sync is implemented and passes tests against a **simulated** server, but
> **it hasn't been run against real iCloud yet.** Builds have sync compiled out until
> the iCloud entitlement is configured (below).

## Features

Working and tested locally:
- **Snippets and command templates.** Each entry is a Snippet or a Template, chosen
  with a picker. Bodies are monospaced, with smart quotes and dashes off.
- **Fill Template** (⇧⌘C on a template). Every `{{placeholder}}` gets one field, in
  order of first appearance; a repeated placeholder shares its value. A live preview is
  shown, and Copy is enabled once every value is filled. Malformed placeholders are
  pointed out by line. Substitution is literal and single-pass: **Relay never runs
  commands and doesn't shell-escape values**, and the sheet reminds you to review the
  command. Filled-in values aren't saved.
- **Copy** (⇧⌘C on a snippet) copies the text as is.
- **Revision history.** Save Version (⌘S) keeps a checkpoint. History (⌘Y) lists
  them, previews one, and shows a line diff against the current version (−/+ markers,
  not just color). **Restore** first saves the current version as a checkpoint, then
  makes the old one current as a normal edit that syncs. The last 50 versions per entry
  are kept, **on this device only**.
- Create, edit, delete, list, and search. Works fully offline.
- SQLite storage. Every edit and its "needs upload" marker commit in one transaction.
- Autosave 0.75 s after typing stops, plus immediate saves on entry switch,
  backgrounding, and Quit. Save failures keep your text on screen with Retry.

Manually verified on macOS (2026-10-03, by the developer): create and edit, reaching
"Saved on this device", content surviving Quit and relaunch, and characters typed
right before ⌘Q surviving relaunch. Not yet manually verified: switching entries,
deletion, search, templates, history. See TESTING.md.

Implemented, verified only against a simulated server:
- iCloud sync of a private-database zone with `CKSyncEngine`, including each entry's
  type. Pending work and engine state survive restarts.
- Concurrent edits keep both versions: the server version plus a labeled
  "(Conflict copy)". A type change counts as an edit.
- Deletions sync as tombstones. A concurrent edit always beats a delete.
- Account separation: the iCloud account is confirmed, and checked against the account
  that owns the database, before sync starts and before each fetch and send. Once Relay
  stops syncing a database, no sync write can reach it (checked inside each write's
  transaction). Isolation still assumes CKSyncEngine reports an account change before
  delivering the new account's records. Apple doesn't document that ordering
  (ARCHITECTURE.md → "Remaining uncertainties").
- A status area based on observed sync outcomes, and debug-only diagnostics
  (double-click the status area in a Debug build).

## Screenshots

_Placeholders: to be captured after real-device verification._

| Notes list | Editor | Conflict copy | Diagnostics |
|---|---|---|---|
| _todo_ | _todo_ | _todo_ | _todo_ |

## Prerequisites

- Xcode 26.6 or newer (developed with Xcode 26.6, Swift 6.3.3, macOS 26.5).
- Deployment targets: iOS 17.0 and macOS 14.0. Only macOS 26.5 has actually been run.
- iOS builds need the iOS platform: Xcode → Settings → Components, or
  `xcodebuild -downloadPlatform iOS`.
- iCloud sync needs a **paid Apple Developer Program membership**. Free Personal Team
  signing can't use CloudKit.

## Build and test

```sh
swift test --package-path Packages/RelayCore                                         # core tests
xcodebuild test  -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' # same, via Xcode
xcodebuild build -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS'
xcodebuild build -project Relay.xcodeproj -scheme Relay -destination 'generic/platform=iOS Simulator'  # needs iOS platform
Scripts/benchmark.sh                                                                 # local benchmarks (BENCHMARKS.md)
```

## Performance

Local processing only: these are **not CloudKit or network numbers**, and real iCloud
sync is unverified. Measured with `RelayBench` on an Apple M5 MacBook (macOS 26.5,
release build, `95b3a91`, **AC power, Low Power Mode off**, 2026-10-03), using
synthetic notes and Relay's real storage and sync code. Medians of 3 repetitions in one
run:

| | 1,000 entries | 10,000 entries |
|---|---:|---:|
| Save an edit (commit + pending marker) | 0.20 ms (p95 1.8, p99 3.2) | 0.27 ms (p95 2.0, p99 3.9) |
| Reopen the store and load the list | 1.2 ms | 10.0 ms |
| Search (in-memory filter, no matches) | 5.4 ms | 56 ms |
| Apply 1,000 incoming changes (simulated transport) | 177–598 ms (high variance) | 372–405 ms |
| Reopen and recover 600 pending changes | 0.8 ms | 2.5 ms |

A notes-list index (schema v3) cut the 10,000-entry load by about 2.7× in a controlled
before/after comparison. Search scales linearly with total text and is the main limit
at large sizes. A save's flush is a barrier sync, not a full drive-cache flush (see
Limitations). BENCHMARKS.md has the method, every repetition, all earlier runs, and
caveats.

## Enabling iCloud sync

Do these once, in order. Each one is a manual step in Xcode or the developer portal.

1. **Xcode → Settings → Accounts:** add the Apple ID with the paid membership.
2. **Bundle identifier (optional):** target **Relay** → General. If you change it from
   `com.ayaanchawla.Relay`, also change `AppConfiguration.cloudKitContainer` in
   `Relay/RelayApp.swift` to `iCloud.<your bundle id>`.
3. **Signing & Capabilities** (target Relay, *All* configurations):
   - Team: your paid team. Leave "Automatically manage signing" on.
   - **+ Capability → iCloud.** Tick **CloudKit**. Under Containers, click **+** and
     create `iCloud.com.ayaanchawla.Relay` (or the one matching step 2). Make sure it's
     ticked.
   - **+ Capability → Push Notifications.** CKSyncEngine needs this entitlement.
   - **+ Capability → Background Modes** (iOS): tick **Remote notifications**.
4. **Build Settings → Swift Compiler – Custom Flags → Active Compilation Conditions:**
   add `RELAY_CLOUDKIT` to Debug and Release, keeping `DEBUG` in Debug. This switches
   the sync code on. Without the entitlement from step 3, it would crash at launch.
5. Run on **My Mac**. The status area should change from "isn’t enabled in this build"
   to "Connecting to iCloud…" and then a sync state.
6. **CloudKit Console** (icloud.developer.apple.com): select the container and the
   **Development** environment. After the first upload, a `Note` record type exists in
   the zone `Notes`. Development builds use the Development environment. Shipping
   would require deploying the schema to Production.

Steps 3–4 change `Relay.xcodeproj`, and Xcode will create a `Relay.entitlements` file.
Both belong in the commit.

## Project layout

```
Relay/
├── Relay.xcodeproj
├── Relay/                    SwiftUI views (list, editor, Fill Template, History) and app lifecycle
└── Packages/RelayCore/
    ├── Sources/RelayCore/    model, templates, line diff, SQLite store + history, conflict policy, sync coordinator,
    │                         CloudKit adapter (CloudKitSync.swift), UI state
    └── Tests/RelayCoreTests/ local, simulated-sync, and pure tests
```

## Demo script (about two minutes)

1. **Template.** ⇧⌘N, title "Tail logs", body
   `kubectl -n {{namespace}} logs deploy/{{app}} --since={{window}}`. The summary lists
   the three placeholders. Press ⇧⌘C, fill `prod`, `api`, `1h`, watch the preview, and
   Copy. Paste into a terminal **without running it**. Point out the review reminder,
   and that values aren't saved.
2. **History.** Press ⌘S (Save Version). Change the body (add `--previous`, rename
   `window`), then press ⌘Y. Show the − / + line diff, Restore, and the "Saved before a
   restore" entry that makes the restore reversible.
3. **Persistence.** Press ⌘Q right after typing, relaunch: the text, the template type,
   and the history are all there.
4. **Sync (only once verified on two real devices).** Edit on one device, appears on
   the other; offline edit then reconnect; a concurrent edit produces a conflict copy;
   delete propagates. Until then, say plainly that sync is verified only against a
   simulated server.

## Limitations

- **Not yet verified against real iCloud.** All sync tests use a simulated server.
  ARCHITECTURE.md → "Remaining uncertainties" lists the CloudKit behaviors Relay
  assumes but hasn't observed.
- iOS hasn't been built or run in this environment.
- The Simulator can't receive the push notifications CKSyncEngine relies on. Use a
  real device or Mac.
- Typing within the 0.75 s autosave window can be lost on an abrupt kill.
- A returned save survives the app crashing. On this Mac, the system SQLite flushes each
  commit with `F_BARRIERFSYNC`, not `F_FULLFSYNC` (measured with
  `Scripts/fsync-probe.sh`), so **the latest saves may be lost on power loss**. Write
  ordering should keep the database consistent. Power loss hasn't been tested
  (ARCHITECTURE.md → Durability).
- The conflict policy keeps both versions. It doesn't merge text.
- Templates are literal text substitution. Values aren't shell-escaped and commands are
  never run. Review generated commands before running them.
- Revision history is local. It doesn't sync, so another device's history isn't
  visible here. It's capped at 50 versions per entry and deleted with the entry.
- An entry type unknown to this build (from a future version) is read as Snippet, and
  saving it would upload it as a snippet.
- Deleted notes leave small content-free tombstone records in iCloud indefinitely.
- After an account switch, the previous account's database is archived on the device.
  There's no restore UI.

See [ARCHITECTURE.md](ARCHITECTURE.md), [TESTING.md](TESTING.md),
[LEARNING.md](LEARNING.md).
