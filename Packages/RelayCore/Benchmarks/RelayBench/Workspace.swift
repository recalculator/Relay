import Foundation
import RelayCore

/// Every file the benchmark creates lives under one directory of its own in the system
/// temporary directory. Nothing else is read, written, or deleted: not the app's
/// database (`NoteStore.defaultURL`), and not iCloud. No CloudKit object is ever
/// created.
@MainActor
final class Workspace {
    let root: URL
    private var templates: [Int: URL] = [:]

    init() throws {
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL
        root = temporary.appending(path: "RelayBench-\(UUID().uuidString)", directoryHint: .isDirectory)
        try Self.checkSafe(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    /// Refuses any path outside this benchmark's own temporary directory.
    private static func checkSafe(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let appDirectory = NoteStore.defaultURL.deletingLastPathComponent().standardizedFileURL.path
        guard path.hasPrefix(temporary + "/"), path.contains("/RelayBench-"), !path.hasPrefix(appDirectory) else {
            throw BenchmarkFailure("Refusing to use \(path): not inside the benchmark's temporary directory")
        }
    }

    private func checkInside(_ url: URL) throws {
        guard url.standardizedFileURL.path.hasPrefix(root.path + "/") else {
            throw BenchmarkFailure("Refusing to touch \(url.path): outside \(root.path)")
        }
    }

    /// A new, empty directory for one repetition.
    func freshDirectory(_ name: String) throws -> URL {
        let url = root.appending(path: "\(name)-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try checkInside(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    func storeURL(in directory: URL) -> URL {
        directory.appending(path: "Notes.sqlite")
    }

    /// Builds (once) a database of `notes`, each inserted as a synced note downloaded
    /// from the server, through `NoteStore.applyRemote`. Setup only; never timed.
    func template(for notes: [Dataset.GeneratedNote], created: Date) async throws -> URL {
        if let url = templates[notes.count] { return url }
        let directory = try freshDirectory("template-\(notes.count)")
        let url = storeURL(in: directory)
        let store = try await NoteStore.open(at: url)
        for (index, note) in notes.enumerated() {
            try await store.applyRemote(.modified(Dataset.remote(
                note, tag: "t0-\(index)", created: created.addingTimeInterval(Double(index)))))
        }
        let count = try await store.allNotes().count
        let pending = try await store.pendingChanges().count
        await store.close()
        try require(count == notes.count, "template has \(count) notes, expected \(notes.count)")
        try require(pending == 0, "template has \(pending) pending changes, expected 0")
        templates[notes.count] = url
        return url
    }

    /// Copies a closed template database into a fresh directory, so each repetition
    /// starts from identical state.
    func copy(template: URL, name: String) throws -> URL {
        let directory = try freshDirectory(name)
        let destination = storeURL(in: directory)
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: template.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: destination.path + suffix))
        }
        return destination
    }

    /// Deletes a repetition's directory (inside the workspace only).
    func remove(directoryOf store: URL) throws {
        let directory = store.deletingLastPathComponent()
        try checkInside(directory)
        try FileManager.default.removeItem(at: directory)
    }

    /// Deletes the whole workspace. Only `root`, which this process created.
    func removeAll() {
        do {
            try Self.checkSafe(root)
            try FileManager.default.removeItem(at: root)
        } catch {
            FileHandle.standardError.write(Data("warning: couldn't remove \(root.path): \(error)\n".utf8))
        }
    }
}
