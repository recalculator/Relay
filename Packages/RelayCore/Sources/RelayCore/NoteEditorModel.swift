import Foundation
import Observation

/// UI state for editing one note: the in-memory draft and its save status.
///
/// **When is an edit saved?** Only when `NoteStore.updateNote` has returned, meaning the
/// SQLite transaction committed. Before that, the edit exists only in this object's
/// memory. Saves happen:
///  - automatically, `autosaveDelay` after the last keystroke (debounced),
///  - immediately when `save()` is called. The app calls it when the selection changes,
///    when the app leaves the foreground, and before quitting on macOS.
///
/// Keystrokes made within the debounce window before an abrupt process kill (a crash,
/// or the system killing the app) are lost. Everything already saved is not.
///
/// `@MainActor` means every property and method runs on the main thread, where SwiftUI
/// reads it. `@Observable` lets SwiftUI re-render only views that read a changed property.
@MainActor
@Observable
public final class NoteEditorModel {
    public enum SaveStatus: Equatable, Sendable {
        /// The draft matches what is committed to disk.
        case saved
        /// The draft has changes that are not saved yet. An autosave is scheduled.
        case editing
        /// A save is in flight.
        case saving
        /// The last save failed. The draft is still in memory, and the next edit or
        /// `save()` will try again.
        case failed(StoreError)
    }

    public let noteID: UUID

    public var title: String {
        didSet { if title != oldValue { draftDidChange() } }
    }

    public var body: String {
        didSet { if body != oldValue { draftDidChange() } }
    }

    /// Snippet or template. Changing it is an edit like any other: autosaved, uploaded.
    public var kind: EntryKind {
        didSet { if kind != oldValue { draftDidChange() } }
    }

    public private(set) var status: SaveStatus = .saved

    /// The draft as one value.
    public var draft: NoteContent { NoteContent(title: title, body: body, kind: kind) }

    /// The content last committed to disk by (or adopted into) this editor.
    public private(set) var savedContent: NoteContent

    /// True when the draft differs from the last committed content.
    public var hasUnsavedChanges: Bool {
        draft != savedContent
    }

    // Bookkeeping that no view displays, so changes to it shouldn't trigger re-renders.
    @ObservationIgnored private let store: NoteStore
    @ObservationIgnored private let autosaveDelay: Duration
    @ObservationIgnored private let onSaved: @MainActor (Note) -> Void
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var lastSave: Task<Void, Never>?

    /// - Parameter onSaved: Called on the main actor after each successful save, so the
    ///   owner can refresh the list. It's a closure rather than a reference to the
    ///   owner, so the editor depends only on what it needs.
    public init(
        note: Note,
        store: NoteStore,
        autosaveDelay: Duration,
        onSaved: @escaping @MainActor (Note) -> Void
    ) {
        noteID = note.id
        title = note.title
        body = note.body
        kind = note.kind
        savedContent = note.content
        self.store = store
        self.autosaveDelay = autosaveDelay
        self.onSaved = onSaved
    }

    /// Saves the current draft now and returns once it is committed or has failed.
    ///
    /// Saves are chained: each one waits for the previous one to finish. This keeps an
    /// older snapshot from ever being written after a newer one, even when autosave
    /// and an explicit flush overlap.
    public func save() async {
        autosaveTask?.cancel()
        autosaveTask = nil

        let previous = lastSave
        let current = Task {
            await previous?.value
            await performSave()
        }
        lastSave = current
        await current.value
    }

    /// True when the last save failed because the note no longer exists, usually
    /// because it was deleted on another device. The draft is still in memory.
    public var noteWasDeleted: Bool {
        status == .failed(.noteNotFound(noteID))
    }

    /// Replaces the editor's content with a newer stored version, such as a change
    /// synced from another device.
    ///
    /// Only applied when there's no unsaved draft. With a draft, the next save detects
    /// the newer version (via its base) and keeps it as a conflict copy.
    ///
    /// - Returns: Whether the content was applied.
    @discardableResult
    func adoptStoredContent(_ note: Note) -> Bool {
        guard !hasUnsavedChanges, status != .saving else { return false }
        savedContent = note.content
        title = note.title  // didSet sees no unsaved changes, so no autosave is scheduled.
        body = note.body
        kind = note.kind
        return true
    }

    public enum SaveVersionOutcome: Equatable, Sendable {
        case saved
        /// Identical to the newest saved version, so nothing was added.
        case unchanged
        /// The draft couldn't be saved first, or the checkpoint failed.
        case failed(StoreError)
    }

    /// "Save Version": commits the draft, then records the committed content as a
    /// revision. If the draft can't be saved, no revision is made, so a revision never
    /// claims content that isn't on disk.
    public func saveVersion() async -> SaveVersionOutcome {
        await save()
        if case .failed(let error) = status { return .failed(error) }
        do throws(StoreError) {
            return switch try await store.saveCheckpoint(of: noteID) {
            case .saved: .saved
            case .unchanged: .unchanged
            }
        } catch {
            return .failed(error)
        }
    }

    /// A history model bound to this editor and its store.
    public func makeHistory() -> RevisionHistoryModel {
        RevisionHistoryModel(editor: self, store: store)
    }

    /// Cancels a scheduled autosave without saving. Used when the note is being deleted.
    public func discardPendingAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    // MARK: Private

    private func draftDidChange() {
        status = hasUnsavedChanges ? .editing : .saved
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        guard hasUnsavedChanges else { return }
        // This Task inherits the main actor from its surrounding context. `[weak self]`
        // lets the editor be deallocated while the timer is pending; the task then does
        // nothing.
        autosaveTask = Task { [weak self, autosaveDelay] in
            do {
                try await Task.sleep(for: autosaveDelay)
            } catch {
                return  // Cancelled by a newer keystroke or an explicit save.
            }
            await self?.save()
        }
    }

    private func performSave() async {
        guard hasUnsavedChanges else {
            if case .failed = status {} else { status = .saved }
            return
        }
        // Snapshot before suspending. While awaiting the store, the main actor is free
        // and the user may keep typing (actor reentrancy). Those newer keystrokes are not
        // part of this save; they schedule their own.
        let draft = self.draft
        status = .saving

        do throws(StoreError) {
            // Passing the base lets the store detect that the note changed underneath
            // this draft (a sync from another device) and keep that version as a
            // conflict copy instead of silently overwriting it.
            let note = try await store.updateNote(
                id: noteID, title: draft.title, body: draft.body, kind: draft.kind, base: savedContent
            )
            savedContent = draft
            status = hasUnsavedChanges ? .editing : .saved
            onSaved(note)
        } catch {
            status = .failed(error)
            Log.editor.error(
                "Save failed for note \(self.noteID, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }
}
