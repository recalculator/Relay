import CryptoKit
import Foundation

/// Decides how a server version of a note combines with the local row.
///
/// This is a pure function of its inputs. It does no I/O, and the same inputs always
/// produce the same decision. The store applies the decision inside one transaction.
///
/// ## Policy
///
/// * **Server echoes are ignored.** If the server's change tag equals the tag this row is
///   based on, the server holds nothing we haven't seen.
/// * **Clean rows follow the server.** With no unsynced local work, the server version
///   is applied, including deletions.
/// * **Edit vs. edit:** the server version stays the primary note, because every other
///   device already has it. The differing local content is preserved as a conflict copy.
///   If the contents are identical, nothing is copied.
/// * **Edit vs. delete: the edit wins**, in both directions. A concurrent deletion never
///   discards content that the deleting device hadn't seen.
///
/// This is a "keep both versions" policy, not a merge, a CRDT, or collaborative editing.
public enum ConflictResolver {
    /// The local row as the resolver sees it.
    public struct LocalState: Sendable, Equatable {
        public var title: String
        public var body: String
        public var isDeleted: Bool
        public var hasUnsyncedChanges: Bool
        public var baseChangeTag: String?

        public init(title: String, body: String, isDeleted: Bool, hasUnsyncedChanges: Bool, baseChangeTag: String?) {
            self.title = title
            self.body = body
            self.isDeleted = isDeleted
            self.hasUnsyncedChanges = hasUnsyncedChanges
            self.baseChangeTag = baseChangeTag
        }
    }

    public enum Resolution: Sendable, Equatable {
        /// Nothing new. Leave the row unchanged.
        case ignore
        /// Overwrite (or insert) the local row with the server version and mark it synced.
        case applyRemote
        /// Content is already identical. Adopt the server's metadata and mark synced.
        case adoptRemoteMetadata
        /// Remove the local row (server deleted it, and there's no local work to keep).
        case deleteLocal
        /// Keep local content as pending work, re-based on the server's current version,
        /// so the next upload overwrites it. Used when a local edit beats a deletion.
        case keepLocal
        /// Apply the server version to the note, and save the local content as a new
        /// conflict-copy note.
        case applyRemoteAndCopyLocal
    }

    public static func resolve(local: LocalState?, remote: RemoteChange) -> Resolution {
        switch remote {
        case .recordGone:
            guard let local else { return .ignore }
            // A pending edit survives a hard deletion and recreates the record.
            return local.hasUnsyncedChanges && !local.isDeleted ? .keepLocal : .deleteLocal

        case .modified(let server):
            guard let local else {
                // Unknown note: create it unless the server only has a tombstone.
                return server.isDeleted ? .ignore : .applyRemote
            }
            if server.changeTag != nil, server.changeTag == local.baseChangeTag {
                return .ignore
            }
            guard local.hasUnsyncedChanges else {
                return server.isDeleted ? .deleteLocal : .applyRemote
            }
            switch (local.isDeleted, server.isDeleted) {
            case (true, true):
                return .deleteLocal  // Both sides deleted it. Done.
            case (true, false):
                return .applyRemote  // Our delete vs. their edit: the edit wins.
            case (false, true):
                return .keepLocal  // Our edit vs. their delete: the edit wins.
            case (false, false):
                let sameContent = local.title == server.title && local.body == server.body
                return sameContent ? .adoptRemoteMetadata : .applyRemoteAndCopyLocal
            }
        }
    }
}

/// Naming and identity of conflict copies.
public enum ConflictCopy {
    public static let titleSuffix = " (Conflict copy)"

    /// A deterministic id derived from the original note and the preserved content.
    ///
    /// Handling the same conflict twice (for example after a crash and retry, or a
    /// repeated fetch) produces the same id, so the copy is upserted rather than
    /// duplicated.
    public static func id(original: UUID, title: String, body: String) -> UUID {
        var hasher = SHA256()
        hasher.update(data: Data("relay.conflict-copy.v1".utf8))
        hasher.update(data: Data(original.uuidString.utf8))
        // Length-prefix each field so ("ab","c") and ("a","bc") hash differently.
        for field in [title, body] {
            let bytes = Data(field.utf8)
            hasher.update(data: withUnsafeBytes(of: UInt64(bytes.count).bigEndian) { Data($0) })
            hasher.update(data: bytes)
        }
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80  // RFC 9562 version 8 (custom).
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 9562 variant.
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Visible title for a copy. The original title is kept so the user can tell which
    /// note it came from.
    public static func title(forCopyOf title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Conflict copy" : trimmed + titleSuffix
    }
}
