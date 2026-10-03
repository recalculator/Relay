import Foundation
import Observation

/// App-level UI state: the notes list, search, selection, and the active editor.
///
/// It's a class, not a struct, because SwiftUI views must share one long-lived instance
/// and observe its changes (reference semantics). It is `@MainActor` because all of its
/// state is UI state.
@MainActor
@Observable
public final class NotesModel {
    public enum State: Sendable {
        case loading
        case ready
        case failed(StoreError)
    }

    public private(set) var state: State = .loading
    public private(set) var notes: [Note] = []
    public var searchText = ""
    public private(set) var selectedNoteID: UUID?
    public private(set) var editor: NoteEditorModel?

    /// The most recent error from a user action, for the UI to present. The view clears
    /// it after showing it.
    public var presentedError: StoreError?

    /// `notes` filtered by `searchText`. Filtering runs in memory with
    /// `localizedStandardContains`, which, unlike SQLite's `LIKE`, ignores case and
    /// diacritics for all scripts. It is fine for a personal notes list. A very large
    /// corpus would want a full-text index instead.
    public var visibleNotes: [Note] {
        notes.filter { $0.matches(searchText: searchText) }
    }

    @ObservationIgnored public private(set) var store: NoteStore?
    @ObservationIgnored private var storeURL: URL?
    @ObservationIgnored private var sync: SyncCoordinator?
    @ObservationIgnored private var isOpening = false
    @ObservationIgnored private let autosaveDelay: Duration
    @ObservationIgnored private var changesTask: Task<Void, Never>?
    /// Saves that are still finishing for editors the user has navigated away from.
    @ObservationIgnored private var detachedSaves: [Task<Void, Never>] = []

    public init(autosaveDelay: Duration = .milliseconds(750)) {
        self.autosaveDelay = autosaveDelay
    }

    // MARK: Lifecycle

    /// Opens the store at `url` and loads notes. Safe to call more than once; for
    /// example, each macOS window's `.task` may call it.
    public func open(at url: URL) async {
        guard store == nil, !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        storeURL = url
        do throws(StoreError) {
            let store = try await NoteStore.open(at: url)
            await attach(store)
        } catch {
            Log.storage.error("Failed to open store: \(String(describing: error), privacy: .public)")
            state = .failed(error)
        }
    }

    /// Uses an already-open store. `url` is needed only for the account-switch action,
    /// which archives the file.
    ///
    /// Tests that call `handleStoreChange` themselves pass `observeChanges: false`, so a
    /// background observer can't process the same change concurrently.
    public func attach(_ store: NoteStore, at url: URL? = nil) async {
        await attach(store, at: url, observeChanges: true)
    }

    func attach(_ store: NoteStore, at url: URL?, observeChanges: Bool) async {
        self.store = store
        if let url { storeURL = url }
        if observeChanges { await self.observeChanges(of: store) }
        do throws(StoreError) {
            notes = try await store.allNotes()
            state = .ready
        } catch {
            Log.storage.error("Failed to load notes: \(String(describing: error), privacy: .public)")
            state = .failed(error)
        }
    }

    /// Connects the sync coordinator, which is needed for the account-switch action.
    public func connect(sync: SyncCoordinator) {
        self.sync = sync
    }

    /// True if the current editor has an unsaved draft or any save is still running.
    public var hasWorkInProgress: Bool {
        (editor?.hasUnsavedChanges ?? false) || !detachedSaves.isEmpty || editor?.status == .saving
    }

    /// Commits the current draft and waits for any saves still running.
    public func flushPendingEdits() async {
        let saves = detachedSaves
        await editor?.save()
        for save in saves { await save.value }
    }

    // MARK: User actions

    public func select(_ id: UUID?) {
        guard id != selectedNoteID else { return }

        // Commit the outgoing draft. The Task holds a strong reference to the old
        // editor, so the save finishes even though we drop our reference below.
        if let outgoing = editor {
            trackDetachedSave(Task { await outgoing.save() })
        }

        selectedNoteID = id
        editor = id
            .flatMap { id in notes.first { $0.id == id } }
            .map(makeEditor(for:))
    }

    public func createNote(kind: EntryKind = .snippet) async {
        await createNote(title: "", body: "", kind: kind)
    }

    public func deleteNote(id: UUID) async {
        guard let store else { return }
        if selectedNoteID == id {
            // The user is deleting this note, so drop any not-yet-saved draft.
            editor?.discardPendingAutosave()
            editor = nil
            selectedNoteID = nil
        }
        do throws(StoreError) {
            try await store.deleteNote(id: id)
            notes.removeAll { $0.id == id }
        } catch {
            Log.storage.error("Delete failed for note \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            presentedError = error
        }
    }

    /// The open note was deleted on another device while it had unsaved edits. This keeps
    /// the draft by saving it as a new note, so the edit is never silently lost.
    public func keepDeletedNoteDraftAsNewNote() async {
        guard let editor, editor.noteWasDeleted else { return }
        let draft = editor.draft
        self.editor = nil
        selectedNoteID = nil
        await createNote(title: draft.title, body: draft.body, kind: draft.kind)
    }

    /// During an account mismatch: archives this database (it belongs to the other
    /// account and is kept on disk, not deleted), then starts an empty database bound to
    /// the current account.
    public func startFreshForCurrentAccount() async {
        guard let sync, let store, let storeURL, await sync.mismatchedCurrentAccount != nil else { return }
        await flushPendingEdits()
        editor = nil
        selectedNoteID = nil
        changesTask?.cancel()
        state = .loading

        do throws(StoreError) {
            await store.close()
            let archive = try StoreFiles.archive(storeAt: storeURL)
            Log.storage.notice("Archived previous account's database to \(archive.lastPathComponent, privacy: .public)")
            let fresh = try await NoteStore.open(at: storeURL)
            try await sync.startFresh(with: fresh)
            await attach(fresh)
        } catch {
            Log.storage.error("Account switch failed: \(String(describing: error), privacy: .public)")
            state = .failed(error)
        }
    }

    // MARK: Store changes

    /// Reacts to committed store changes. Remote (sync) changes may affect the open
    /// note: a clean editor adopts the new content, and a note deleted elsewhere closes
    /// its editor unless there's a draft worth keeping.
    func handleStoreChange(_ change: StoreChange) async {
        guard let store else { return }
        do throws(StoreError) {
            notes = try await store.allNotes()
        } catch {
            Log.storage.error("Reload after change failed: \(String(describing: error), privacy: .public)")
            return
        }
        guard change.origin == .sync, let editor else { return }
        guard change.noteIDs.isEmpty || change.noteIDs.contains(editor.noteID) else { return }

        if let current = notes.first(where: { $0.id == editor.noteID }) {
            editor.adoptStoredContent(current)
        } else if !editor.hasUnsavedChanges, editor.status != .saving {
            // Deleted elsewhere with no local draft: nothing to keep.
            self.editor = nil
            selectedNoteID = nil
        } else {
            // Deleted elsewhere while the user has an unsaved draft. The next save fails
            // with noteNotFound, and the editor offers "Keep as New Note".
            await editor.save()
        }
    }

    // MARK: Private

    private func createNote(title: String, body: String, kind: EntryKind) async {
        guard let store else { return }
        do throws(StoreError) {
            let note = try await store.createNote(title: title, body: body, kind: kind)
            if !notes.contains(where: { $0.id == note.id }) {
                notes.insert(note, at: 0)
            }
            searchText = ""  // Make sure the new note is visible.
            select(note.id)
        } catch {
            Log.storage.error("Create failed: \(String(describing: error), privacy: .public)")
            presentedError = error
        }
    }

    /// Subscribes before returning, so no committed change is missed.
    private func observeChanges(of store: NoteStore) async {
        changesTask?.cancel()
        let changes = await store.changes()
        changesTask = Task { [weak self] in
            for await change in changes {
                await self?.handleStoreChange(change)
            }
        }
    }

    private func makeEditor(for note: Note) -> NoteEditorModel {
        NoteEditorModel(note: note, store: storeOrPreconditionFailure, autosaveDelay: autosaveDelay) {
            [weak self] saved in self?.noteDidSave(saved)
        }
    }

    /// `select` can only pick ids from `notes`, which is only filled after `attach`
    /// sets `store`. Reaching this without a store is a programming error.
    private var storeOrPreconditionFailure: NoteStore {
        guard let store else { preconditionFailure("NotesModel used before a store was attached") }
        return store
    }

    private func noteDidSave(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index] = note
        notes.sort { $0.modifiedAt > $1.modifiedAt }
    }

    private func trackDetachedSave(_ task: Task<Void, Never>) {
        detachedSaves.append(task)
        Task {
            await task.value
            detachedSaves.removeAll { $0 == task }
        }
    }
}

/// File operations on a closed store.
enum StoreFiles {
    /// Moves the database and its WAL/shared-memory side files into an `Archived`
    /// folder next to it, under a timestamped name. Nothing is deleted.
    ///
    /// The store must be closed first. On close, SQLite checkpoints the WAL, but the
    /// side files are moved too in case they remain.
    static func archive(storeAt url: URL, now: Date = Date()) throws(StoreError) -> URL {
        let fileManager = FileManager.default
        let folder = url.deletingLastPathComponent().appending(path: "Archived", directoryHint: .isDirectory)
        let stamp = now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let base = url.deletingPathExtension().lastPathComponent + "-" + stamp
        let destination = folder.appending(path: base + "." + url.pathExtension)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try fileManager.moveItem(at: url, to: destination)
            for suffix in ["-wal", "-shm"] {
                let side = URL(filePath: url.path(percentEncoded: false) + suffix)
                if fileManager.fileExists(atPath: side.path(percentEncoded: false)) {
                    try fileManager.moveItem(at: side, to: URL(filePath: destination.path(percentEncoded: false) + suffix))
                }
            }
        } catch {
            throw .fileSystem(message: error.localizedDescription)
        }
        return destination
    }
}
