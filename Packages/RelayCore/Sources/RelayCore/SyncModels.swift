import Foundation

// CloudKit-free value types that describe sync traffic.
//
// The real CloudKit adapter (`CloudKitSync.swift`) translates CKRecords, CKErrors, and
// CKSyncEngine events into these types. The store, the conflict resolver, and the
// coordinator's logic only ever see these types. That makes it possible to drive them
// deterministically from tests with a simulated server, without iCloud.

/// One version of a note as stored on the server.
public struct RemoteNote: Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var body: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var conflictOf: UUID?
    /// Missing or unrecognized on the server (an older build's record) reads as `.snippet`.
    public var kind: EntryKind
    /// Server-side tombstone: the note was deleted. Title and body are empty.
    public var isDeleted: Bool
    /// Opaque server version identifier (`CKRecord.recordChangeTag`). It changes on every
    /// server write.
    public var changeTag: String?
    /// Encoded `CKRecord` system fields, used as the base of the next upload.
    public var systemFields: Data?

    public init(
        id: UUID,
        title: String,
        body: String,
        createdAt: Date,
        modifiedAt: Date,
        conflictOf: UUID? = nil,
        kind: EntryKind = .snippet,
        isDeleted: Bool = false,
        changeTag: String?,
        systemFields: Data?
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.conflictOf = conflictOf
        self.kind = kind
        self.isDeleted = isDeleted
        self.changeTag = changeTag
        self.systemFields = systemFields
    }
}

/// A change observed on the server, either fetched or returned by a failed save.
public enum RemoteChange: Sendable, Equatable {
    /// A record was created or modified. It may be a tombstone (`isDeleted`).
    case modified(RemoteNote)
    /// A record no longer exists on the server at all. This is a hard deletion, which
    /// Relay itself never performs but which other tools or zone resets can cause.
    case recordGone(UUID)
}

/// What the sync layer needs from a local row to build an upload.
public struct UploadSnapshot: Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let body: String
    public let createdAt: Date
    public let modifiedAt: Date
    public let conflictOf: UUID?
    public let kind: EntryKind
    public let isDeleted: Bool
    /// The `local_version` being uploaded. When the server confirms this upload, rows are
    /// marked synced only up to this version.
    public let localVersion: Int64
    public let baseSystemFields: Data?
}

/// Why the server rejected a record save, classified for handling.
public enum SendFailure: Sendable, Equatable {
    /// `serverRecordChanged`: someone else changed the record since our base version.
    case conflict(server: RemoteNote)
    /// `unknownItem`: our base refers to a record that no longer exists.
    case recordMissing
    /// `zoneNotFound` / `userDeletedZone`: the zone must be recreated.
    case zoneMissing
    /// The engine retries these itself (network, rate limit, service busy, account
    /// temporarily unavailable). Relay must not add its own retry.
    case transient(code: Int)
    /// `quotaExceeded`: the user's iCloud storage is full. Retrying won't help until they
    /// act, so nothing is re-queued automatically.
    case quotaExceeded
    /// The request itself is invalid (record too large, bad arguments, permissions, and
    /// so on). Re-sending the same data would fail again.
    case invalid(code: Int)
}

/// Outcome of one record in a sent batch.
public enum SendResult: Sendable, Equatable {
    case saved(RemoteNote)
    case failed(id: UUID, SendFailure)
}

/// Account transitions reported by CKSyncEngine. Users are identified by their opaque
/// CloudKit user record name.
public enum AccountChange: Sendable, Equatable {
    case signIn(user: String)
    case signOut(previousUser: String)
    case switchAccounts(previousUser: String, currentUser: String)
}

/// Why the server-side zone disappeared (`CKDatabase.DatabaseChange.Deletion.Reason`).
public enum ZoneDeletionReason: Sendable, Equatable {
    /// The zone was deleted or its data purged, for example via Settings → iCloud → Manage
    /// Storage.
    case deletedOrPurged
    /// The user reset their end-to-end encrypted data. Apple's guidance is to re-upload.
    case encryptedDataReset
}

/// Identifies one sync session: the account that owns the database, and the session
/// number the store assigned when the engine was created. Every write the sync layer
/// makes carries one, and the store rejects it inside the write's transaction if the
/// session has ended or the owner changed. See `NoteStore.beginSyncSession(owner:)`.
public struct SyncFence: Sendable, Equatable {
    public let owner: String
    public let epoch: UInt64
}
