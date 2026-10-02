import Foundation

/// A plain-text note as the app sees it.
///
/// `Note` is a struct, so it has value semantics: every copy is independent. Handing a
/// `Note` to the UI or across actors can never let one side mutate the other's copy,
/// which is also why it can be `Sendable` with no extra work.
public struct Note: Identifiable, Hashable, Sendable {
    /// Stable identity. Generated once on creation and later reused as the CloudKit
    /// record name, so the same logical note always maps to the same record.
    public let id: UUID
    public var title: String
    public var body: String
    public let createdAt: Date
    public var modifiedAt: Date
    /// For a conflict copy, the id of the note it was split from. `nil` for ordinary notes.
    public var conflictOf: UUID?

    public init(
        id: UUID,
        title: String,
        body: String,
        createdAt: Date,
        modifiedAt: Date,
        conflictOf: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.conflictOf = conflictOf
    }
}

extension Note {
    /// Title shown in lists: the explicit title, else the first non-empty body line.
    public var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { return trimmedTitle }
        return firstNonEmptyLine(of: body) ?? "New Note"
    }

    /// A one-line preview of the body for list rows.
    public var preview: String {
        firstNonEmptyLine(of: body) ?? ""
    }

    /// Case- and diacritic-insensitive match on title or body, using the user's locale.
    public func matches(searchText: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return title.localizedStandardContains(query) || body.localizedStandardContains(query)
    }
}

private func firstNonEmptyLine(of text: String) -> String? {
    // `first(where:)` returns an Optional: nil when no element matches.
    text.split(whereSeparator: \.isNewline)
        .lazy
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { !$0.isEmpty }
}

/// A batch of committed store changes, delivered to observers after the transaction commits.
public struct StoreChange: Sendable, Equatable {
    public enum Origin: Sendable, Equatable {
        /// Made by the user on this device. The sync layer should upload these.
        case local
        /// Applied by the sync layer from the server. The UI should refresh. These
        /// changes must *not* be uploaded again.
        case sync
    }

    public let origin: Origin
    /// The notes affected. Empty means "any note may have changed".
    public let noteIDs: Set<UUID>
}

/// Local work that has not yet been confirmed by the server.
///
/// Derived from the `notes` table (`local_version > synced_version`), so it is written in
/// the same SQL statement as the edit itself and cannot be lost separately from it.
public struct PendingChange: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case save
        case delete
    }

    public let noteID: UUID
    public let kind: Kind
    /// The local edit counter at the time this was read. The sync layer uses it to tell
    /// whether a newer edit happened while an older upload was in flight.
    public let localVersion: Int64
}
