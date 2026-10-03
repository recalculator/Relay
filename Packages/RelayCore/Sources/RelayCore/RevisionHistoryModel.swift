import Foundation
import Observation

/// UI state for one entry's History sheet.
///
/// It's created for one editor (one entry) and holds that editor's store, so its
/// awaited work can't land on a different entry, or on a different database after an
/// account switch. A newer `load()` supersedes an older one still in flight: the older
/// result is discarded, not shown.
@MainActor
@Observable
public final class RevisionHistoryModel: Identifiable {
    public enum LoadState: Equatable, Sendable {
        case loading
        case loaded
        case failed(StoreError)
    }

    public let noteID: UUID
    public private(set) var state: LoadState = .loading
    /// Newest first.
    public private(set) var revisions: [Revision] = []
    /// The entry's current saved content, which diffs compare against.
    public private(set) var current: NoteContent?
    public var selectedRevisionID: Int64?
    public private(set) var restoreError: StoreError?

    @ObservationIgnored private let editor: NoteEditorModel
    @ObservationIgnored private let store: NoteStore
    @ObservationIgnored private var loadGeneration = 0

    init(editor: NoteEditorModel, store: NoteStore) {
        self.editor = editor
        self.store = store
        noteID = editor.noteID
    }

    public var selectedRevision: Revision? {
        revisions.first { $0.id == selectedRevisionID }
    }

    /// What restoring the selected revision would change: current body → its body.
    public var bodyDiff: [LineDiff.Line] {
        guard let current, let selected = selectedRevision else { return [] }
        return LineDiff.compare(old: current.body, new: selected.content.body)
    }

    public func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        do throws(StoreError) {
            let history = try await store.revisionHistory(of: noteID)
            guard generation == loadGeneration else { return }  // A newer load started.
            current = history.current.content
            revisions = history.revisions
            if selectedRevision == nil { selectedRevisionID = revisions.first?.id }
            state = .loaded
        } catch {
            guard generation == loadGeneration else { return }
            state = .failed(error)
        }
    }

    /// Restores the selected revision. The editor's draft is saved first, so text typed
    /// before opening History is kept: it becomes the content preserved by the restore's
    /// recovery checkpoint.
    ///
    /// - Returns: Whether the entry now has the revision's content.
    public func restoreSelected() async -> Bool {
        guard let revision = selectedRevision else { return false }
        restoreError = nil
        await editor.save()
        if case .failed(let error) = editor.status {
            restoreError = error
            return false
        }
        do throws(StoreError) {
            let restored = try await store.restore(revision: revision.id, of: noteID)
            // The sheet is modal, so there's normally no new draft. If there were, the
            // editor keeps it, and its next save keeps the restored text as a conflict
            // copy instead of overwriting it.
            editor.adoptStoredContent(restored)
            await load()
            return true
        } catch {
            restoreError = error
            await load()
            return false
        }
    }
}
