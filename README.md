# Relay

An offline-first, plain-text notes app for iOS and macOS, written in Swift and SwiftUI.
The goal is a small app with solid non-UI engineering: durable local persistence,
explicit iCloud sync with `CKSyncEngine`, clear concurrency, and tests aimed at data
integrity.

> **Status: Phase 2 of 4.** Local persistence works. CloudKit sync is implemented and
> passes tests against a **simulated** server, but **it has not yet been run against
> real iCloud.** Builds have sync compiled out until the iCloud entitlement is
> configured (below).

## Features

Working and tested locally:
- Create, edit, delete, list, and search notes. Works fully offline.
- SQLite storage. Every edit and its "needs upload" marker commit in one transaction.
- Autosave 0.75 s after typing stops, plus immediate saves on note switch,
  backgrounding, and Quit.
- Save failures keep your text on screen with the error and Retry.

Implemented, verified only against a simulated server:
- iCloud sync of a private-database zone with `CKSyncEngine`. Pending work and engine
  state survive restarts.
- Concurrent edits keep both versions: the server version plus a labeled
  "(Conflict copy)".
- Deletions sync as tombstones. A concurrent edit always beats a delete.
- Account separation: the iCloud account is confirmed, and checked against the account
  that owns the database, before sync starts. One account's notes are never uploaded
  to another.
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
```

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
├── Relay/                    SwiftUI views and app lifecycle
└── Packages/RelayCore/
    ├── Sources/RelayCore/    model, SQLite store, conflict policy, sync coordinator,
    │                         CloudKit adapter (CloudKitSync.swift), UI state
    └── Tests/RelayCoreTests/ local, simulated-sync, and pure tests
```

## Demo script (to run once sync is verified)

1. Disconnect device 1 from the network. Create and edit a note. The status shows
   "1 change not uploaded yet".
2. Quit and relaunch. The note and the pending count are still there.
3. Reconnect. The status becomes "All changes uploaded", and the note appears on
   device 2.
4. Take both devices offline and edit the same note differently on each. Reconnect
   both. Both devices show the note plus a "(Conflict copy)" with the other text.
5. Delete a note on one device. It disappears on the other.

## Limitations

- **Not yet verified against real iCloud.** All sync tests use a simulated server.
  ARCHITECTURE.md → "Remaining uncertainties" lists the CloudKit behaviors Relay
  assumes but hasn't observed.
- iOS hasn't been built or run in this environment.
- The Simulator can't receive the push notifications CKSyncEngine relies on. Use a
  real device or Mac.
- Typing within the 0.75 s autosave window can be lost on an abrupt kill.
  Power-loss durability depends on the OS and hardware honoring flush requests (see
  ARCHITECTURE.md → Durability). It hasn't been tested.
- The conflict policy keeps both versions. It doesn't merge text.
- Deleted notes leave small content-free tombstone records in iCloud indefinitely.
- After an account switch, the previous account's database is archived on the device.
  There's no restore UI.

See [ARCHITECTURE.md](ARCHITECTURE.md), [TESTING.md](TESTING.md),
[LEARNING.md](LEARNING.md).
