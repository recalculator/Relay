import RelayCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

enum AppConfiguration {
    /// Must match the container enabled under Signing & Capabilities → iCloud.
    static let cloudKitContainer = "iCloud.com.ayaanchawla.Relay"

    /// Real sync is compiled in only when the `RELAY_CLOUDKIT` compilation condition is
    /// set. That flag should be added together with the iCloud entitlement (see
    /// README). Without the entitlement, touching CloudKit would crash the app, so
    /// unsigned/local builds keep sync off.
    static var cloudKitEnabled: Bool {
        #if RELAY_CLOUDKIT
        true
        #else
        false
        #endif
    }
}

@main
struct RelayApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        #if os(macOS)
        // Relay stores commands. macOS text views would otherwise turn " into curly
        // quotes and -- into an em dash (when "Use smart quotes and dashes" is on), which
        // breaks a pasted command. These keys apply to this app only.
        for key in ["NSAutomaticQuoteSubstitutionEnabled", "NSAutomaticDashSubstitutionEnabled",
                    "NSAutomaticTextReplacementEnabled"] {
            UserDefaults.standard.set(false, forKey: key)
        }
        #endif
    }

    /// `@State` makes SwiftUI create these once and keep them for the app's lifetime.
    @State private var model = NotesModel()
    @State private var syncStatus = SyncStatusModel(
        availability: AppConfiguration.cloudKitEnabled ? .starting : .notConfigured
    )
    @State private var sync: SyncCoordinator?
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, syncStatus: syncStatus, sync: sync)
                .task {
                    #if os(macOS)
                    appDelegate.model = model
                    #endif
                    await launch()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Snippet") { Task { await model.createNote(kind: .snippet) } }
                    .keyboardShortcut("n")
                Button("New Template") { Task { await model.createNote(kind: .template) } }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // The account may have changed while the app was in the background.
                Task { await sync?.revalidateAccount() }
                return
            }
            // Leaving the foreground commits the current draft right away rather than
            // waiting for the autosave debounce.
            flushInBackground()
        }
    }

    /// Opens local storage first, so the app is usable offline immediately, then starts
    /// sync. CKSyncEngine should be created early in launch.
    private func launch() async {
        await model.open(at: NoteStore.defaultURL)
        #if RELAY_CLOUDKIT
        guard sync == nil, let store = model.store else { return }
        let coordinator = await SyncCoordinator.cloudKit(
            store: store, status: syncStatus, containerIdentifier: AppConfiguration.cloudKitContainer)
        sync = coordinator
        model.connect(sync: coordinator)
        // Confirms the iCloud account and that it owns this database before any engine
        // exists. The app is fully usable offline meanwhile.
        await coordinator.startCloudKit(containerIdentifier: AppConfiguration.cloudKitContainer)
        #endif
    }

    private func flushInBackground() {
        #if os(iOS)
        // Ask iOS for extra execution time so the save can finish after the app moves
        // to the background. The handler ends the assertion if time runs out.
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "Save note") {}
        Task {
            await model.flushPendingEdits()
            UIApplication.shared.endBackgroundTask(taskID)
        }
        #else
        Task { await model.flushPendingEdits() }
        #endif
    }
}

#if os(macOS)
import AppKit

/// On macOS, Quit doesn't reliably pass through a background scene phase, so the app
/// delegate delays termination until the current draft is committed.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: NotesModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasWorkInProgress else { return .terminateNow }
        Task {
            await model.flushPendingEdits()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#endif
