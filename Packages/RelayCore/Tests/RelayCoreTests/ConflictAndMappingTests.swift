import CloudKit
import Foundation
import Testing
@testable import RelayCore

// MARK: - Pure conflict policy

@Suite("ConflictResolver (pure)")
struct ConflictResolverTests {
    typealias Local = ConflictResolver.LocalState

    let id = UUID()

    func server(_ body: String = "server", tag: String = "t2", deleted: Bool = false) -> RemoteChange {
        .modified(RemoteNote(
            id: id, title: "", body: deleted ? "" : body, createdAt: .distantPast, modifiedAt: .distantPast,
            isDeleted: deleted, changeTag: tag, systemFields: nil))
    }

    func local(_ body: String = "local", dirty: Bool, deleted: Bool = false, base: String? = "t1") -> Local {
        Local(title: "", body: deleted ? "" : body, isDeleted: deleted, hasUnsyncedChanges: dirty, baseChangeTag: base)
    }

    @Test func decisionTable() {
        let cases: [(Local?, RemoteChange, ConflictResolver.Resolution, String)] = [
            (nil, server(), .applyRemote, "new note from server"),
            (nil, server(deleted: true), .ignore, "tombstone for unknown note"),
            (nil, .recordGone(id), .ignore, "hard delete of unknown note"),
            (local(dirty: false), server(tag: "t1"), .ignore, "echo of known version"),
            (local(dirty: true), server(tag: "t1"), .ignore, "echo while local edit pending"),
            (local(dirty: false), server(), .applyRemote, "clean row follows server"),
            (local(dirty: false), server(deleted: true), .deleteLocal, "clean row deleted remotely"),
            (local(dirty: false), .recordGone(id), .deleteLocal, "clean row hard-deleted"),
            (local(dirty: true), server(), .applyRemoteAndCopyLocal, "edit vs edit"),
            (local("server", dirty: true), server("server"), .adoptRemoteMetadata, "identical edits"),
            (local(dirty: true), server(deleted: true), .keepLocal, "local edit vs remote delete: edit wins"),
            (local(dirty: true), .recordGone(id), .keepLocal, "local edit vs hard delete: edit wins"),
            (local(dirty: true, deleted: true), server(), .applyRemote, "local delete vs remote edit: edit wins"),
            (local(dirty: true, deleted: true), server(tag: "t1"), .ignore, "local delete, no remote change"),
            (local(dirty: true, deleted: true), server(deleted: true), .deleteLocal, "deleted on both sides"),
            (local(dirty: true, deleted: true), .recordGone(id), .deleteLocal, "local delete vs hard delete"),
        ]
        for (localState, remote, expected, label) in cases {
            #expect(ConflictResolver.resolve(local: localState, remote: remote) == expected, "\(label)")
        }
    }

    @Test func conflictCopyIdentityIsDeterministicAndContentSpecific() {
        let original = UUID()
        let a = ConflictCopy.id(original: original, title: "t", body: "body")
        #expect(a == ConflictCopy.id(original: original, title: "t", body: "body"))
        #expect(a != ConflictCopy.id(original: original, title: "t", body: "body2"))
        #expect(a != ConflictCopy.id(original: UUID(), title: "t", body: "body"))
        // Field boundaries matter: ("ab","c") is not ("a","bc").
        #expect(ConflictCopy.id(original: original, title: "ab", body: "c")
                != ConflictCopy.id(original: original, title: "a", body: "bc"))
    }

    @Test func conflictCopyTitles() {
        #expect(ConflictCopy.title(forCopyOf: "Plan") == "Plan (Conflict copy)")
        #expect(ConflictCopy.title(forCopyOf: "  ") == "Conflict copy")
    }
}

// MARK: - CloudKit mapping (local CKRecord/CKError values only; no network, no container)

@Suite("CloudKit record mapping")
struct NoteRecordTests {
    let snapshot = UploadSnapshot(
        id: UUID(), title: "Title", body: "Body 👋", createdAt: Date(timeIntervalSince1970: 1_000),
        modifiedAt: Date(timeIntervalSince1970: 2_000), conflictOf: UUID(), isDeleted: false,
        localVersion: 3, baseSystemFields: nil)

    @Test func recordRoundTripsNoteFields() throws {
        let record = NoteRecord.makeRecord(from: snapshot)
        #expect(record.recordType == "Note")
        #expect(record.recordID.recordName == snapshot.id.uuidString)
        #expect(record.recordID.zoneID.zoneName == "Notes")

        let remote = try #require(NoteRecord.remoteNote(from: record))
        #expect(remote.id == snapshot.id)
        #expect(remote.title == snapshot.title)
        #expect(remote.body == snapshot.body)
        #expect(remote.createdAt == snapshot.createdAt)
        #expect(remote.modifiedAt == snapshot.modifiedAt)
        #expect(remote.conflictOf == snapshot.conflictOf)
        #expect(remote.isDeleted == false)
    }

    @Test func uploadStartsFromStoredSystemFields() throws {
        let original = NoteRecord.makeRecord(from: snapshot)
        let fields = NoteRecord.encodeSystemFields(of: original)
        let decoded = try #require(NoteRecord.decodeSystemFields(fields))
        #expect(decoded.recordID == original.recordID)

        let withBase = UploadSnapshot(
            id: snapshot.id, title: "new", body: "", createdAt: snapshot.createdAt, modifiedAt: snapshot.modifiedAt,
            conflictOf: nil, isDeleted: true, localVersion: 4, baseSystemFields: fields)
        let record = NoteRecord.makeRecord(from: withBase)
        #expect(record.recordID == original.recordID)
        #expect(record["isDeleted"] as? Int64 == 1)
        #expect(record["conflictOf"] == nil)
    }

    @Test func garbageSystemFieldsFallBackToAFreshRecord() {
        let withJunk = UploadSnapshot(
            id: snapshot.id, title: "t", body: "", createdAt: snapshot.createdAt, modifiedAt: snapshot.modifiedAt,
            conflictOf: nil, isDeleted: false, localVersion: 1, baseSystemFields: Data("junk".utf8))
        #expect(NoteRecord.makeRecord(from: withJunk).recordID.recordName == snapshot.id.uuidString)
    }

    @Test func recordsThatAreNotValidNotesAreRejected() {
        let wrongType = CKRecord(recordType: "Other", recordID: NoteRecord.recordID(for: UUID()))
        #expect(NoteRecord.remoteNote(from: wrongType) == nil)
        let badName = CKRecord(recordType: "Note", recordID: CKRecord.ID(recordName: "not-a-uuid", zoneID: NoteRecord.zoneID))
        #expect(NoteRecord.remoteNote(from: badName) == nil)
        let missingDates = CKRecord(recordType: "Note", recordID: NoteRecord.recordID(for: UUID()))
        #expect(NoteRecord.remoteNote(from: missingDates) == nil)
        let otherZone = CKRecord(recordType: "Note", recordID: CKRecord.ID(recordName: UUID().uuidString))
        #expect(NoteRecord.remoteNote(from: otherZone) == nil)
    }

    @Test func errorClassification() throws {
        func classify(_ code: CKError.Code, _ userInfo: [String: Any] = [:]) -> SendFailure {
            NoteRecord.classify(CKError(code, userInfo: userInfo))
        }
        for code: CKError.Code in [.networkFailure, .networkUnavailable, .requestRateLimited, .serviceUnavailable,
                                   .zoneBusy, .notAuthenticated, .accountTemporarilyUnavailable] {
            #expect(classify(code) == .transient(code: code.rawValue), "\(code.rawValue)")
        }
        #expect(classify(.unknownItem) == .recordMissing)
        #expect(classify(.zoneNotFound) == .zoneMissing)
        #expect(classify(.userDeletedZone) == .zoneMissing)
        #expect(classify(.quotaExceeded) == .quotaExceeded)
        #expect(classify(.invalidArguments) == .invalid(code: CKError.Code.invalidArguments.rawValue))

        let serverRecord = NoteRecord.makeRecord(from: snapshot)
        guard case .conflict(let server) = classify(.serverRecordChanged, [CKRecordChangedErrorServerRecordKey: serverRecord]) else {
            Issue.record("serverRecordChanged with a server record should be a conflict")
            return
        }
        #expect(server.body == snapshot.body)
        // Without the server record, there is nothing to resolve against.
        #expect(classify(.serverRecordChanged) == .invalid(code: CKError.Code.serverRecordChanged.rawValue))
    }
}

// MARK: - Schema and durability

@Suite("Schema migration and durability")
struct SchemaTests {
    @Test func v1DatabaseMigratesToCurrentKeepingDataAndPendingWork() async throws {
        let directory = try TemporaryDirectory()
        // Build a v1 database exactly as Phase 1 shipped it.
        let raw = try SQLiteConnection(url: directory.storeURL)
        try raw.execute("""
            CREATE TABLE notes (
                id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL,
                created_at REAL NOT NULL, modified_at REAL NOT NULL,
                is_deleted INTEGER NOT NULL DEFAULT 0, local_version INTEGER NOT NULL,
                synced_version INTEGER NOT NULL DEFAULT 0
            ) STRICT;
            INSERT INTO notes (id, title, body, created_at, modified_at, local_version)
            VALUES ('6A2F41A0-0000-4000-8000-000000000001', 'old note', 'kept', 1, 2, 3);
            PRAGMA user_version = 1;
            """)
        raw.close()

        let store = try NoteStore(url: directory.storeURL)
        #expect(try await store.allNotes().map(\.title) == ["old note"])
        #expect(try await store.pendingChanges().map(\.localVersion) == [3])
        #expect(try await store.queryIntForTesting("PRAGMA user_version") == Int64(Schema.currentVersion))
        #expect(try await store.boundAccount() == nil)  // sync_state table exists and is empty.
    }

    @Test func durabilityPragmasAreApplied() async throws {
        let directory = try TemporaryDirectory()
        let store = try NoteStore(url: directory.storeURL)
        #expect(try await store.queryTextForTesting("PRAGMA journal_mode") == "wal")
        #expect(try await store.queryIntForTesting("PRAGMA synchronous") == 2)  // 2 = FULL
        #expect(try await store.queryIntForTesting("PRAGMA fullfsync") == 1)
        #expect(try await store.queryIntForTesting("PRAGMA checkpoint_fullfsync") == 1)
    }

    @Test func storeChangeStreamDeliversCommittedLocalChanges() async throws {
        let directory = try TemporaryDirectory()
        let store = try NoteStore(url: directory.storeURL)
        var changes = await store.changes().makeAsyncIterator()
        let note = try await store.createNote(title: "x")
        #expect(await changes.next() == StoreChange(origin: .local, noteIDs: [note.id]))
    }
}

// MARK: - Remote changes reaching the open editor

@MainActor
@Suite("NotesModel with remote changes")
struct RemoteEditorTests {
    let directory: TemporaryDirectory
    let store: NoteStore

    init() throws {
        directory = try TemporaryDirectory()
        store = try NoteStore(url: directory.storeURL, now: steppingClock())
    }

    private func remote(_ id: UUID, body: String, deleted: Bool = false, tag: String) -> RemoteChange {
        .modified(RemoteNote(id: id, title: "t", body: body, createdAt: .now, modifiedAt: .now,
                             isDeleted: deleted, changeTag: tag, systemFields: Data(tag.utf8)))
    }

    @Test func cleanEditorAdoptsRemoteEdit() async throws {
        let model = NotesModel(autosaveDelay: .seconds(3600))
        await model.attach(store, at: nil, observeChanges: false)
        await model.createNote()
        let id = try #require(model.selectedNoteID)
        model.editor?.title = "t"
        await model.flushPendingEdits()
        try await store.executeForTesting("UPDATE notes SET synced_version = local_version WHERE id = '\(id.uuidString)'")

        try await store.applyRemote(remote(id, body: "from another device", tag: "r1"))
        await model.handleStoreChange(StoreChange(origin: .sync, noteIDs: [id]))

        #expect(model.editor?.body == "from another device")
        #expect(model.editor?.status == .saved)
        #expect(try await store.pendingChanges().isEmpty)  // Adopting isn't a local edit.
    }

    @Test func draftOfNoteDeletedElsewhereCanBeKeptAsNewNote() async throws {
        let model = NotesModel(autosaveDelay: .seconds(3600))
        await model.attach(store, at: nil, observeChanges: false)
        await model.createNote()
        let id = try #require(model.selectedNoteID)
        model.editor?.title = "t"
        await model.flushPendingEdits()
        try await store.executeForTesting("UPDATE notes SET synced_version = local_version WHERE id = '\(id.uuidString)'")

        model.editor?.body = "unsaved words"
        try await store.applyRemote(remote(id, body: "", deleted: true, tag: "r1"))
        await model.handleStoreChange(StoreChange(origin: .sync, noteIDs: [id]))

        #expect(model.editor?.noteWasDeleted == true, "status: \(String(describing: model.editor?.status)) editorID: \(String(describing: model.editor?.noteID)) id: \(id)")
        #expect(model.editor?.body == "unsaved words")

        await model.keepDeletedNoteDraftAsNewNote()
        #expect(model.notes.map(\.body) == ["unsaved words"])
        #expect(model.selectedNoteID != id)
    }

    @Test func cleanEditorClosesWhenNoteIsDeletedElsewhere() async throws {
        let model = NotesModel(autosaveDelay: .seconds(3600))
        await model.attach(store, at: nil, observeChanges: false)
        await model.createNote()
        let id = try #require(model.selectedNoteID)
        try await store.executeForTesting("UPDATE notes SET synced_version = local_version WHERE id = '\(id.uuidString)'")

        try await store.applyRemote(remote(id, body: "", deleted: true, tag: "r1"))
        await model.handleStoreChange(StoreChange(origin: .sync, noteIDs: [id]))

        #expect(model.editor == nil)
        #expect(model.notes.isEmpty)
    }
}
