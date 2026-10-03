/// A line-by-line comparison of two texts, for showing what a restore would change.
///
/// Built on the standard library's `CollectionDifference` (`difference(from:)`), which
/// finds a minimal set of line removals and insertions. This type only turns that set
/// into an ordered list for display. A pure function: same inputs, same output.
public enum LineDiff {
    public struct Line: Sendable, Equatable {
        public enum Change: Sendable, Equatable {
            case unchanged
            /// Only in the old text.
            case removed
            /// Only in the new text.
            case added
        }

        public let change: Change
        public let text: String
    }

    /// Lines of `text`, split on "\n". Empty text has no lines; a trailing newline
    /// produces a final empty line, so adding or removing one shows up in the diff.
    public static func lines(of text: String) -> [String] {
        text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// The lines of both texts in order: unchanged lines once, and at each change the
    /// removed lines before the added ones.
    public static func compare(old: String, new: String) -> [Line] {
        let oldLines = lines(of: old)
        let newLines = lines(of: new)
        var removed: Set<Int> = []
        var inserted: Set<Int> = []
        for change in newLines.difference(from: oldLines) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)  // Offset in `oldLines`.
            case .insert(let offset, _, _): inserted.insert(offset)  // Offset in `newLines`.
            }
        }

        // The lines not removed from `old` are, in order, the lines not inserted into
        // `new`. Walk both, emitting removals, then insertions, then a shared line.
        var result: [Line] = []
        var i = 0, j = 0
        while i < oldLines.count || j < newLines.count {
            if i < oldLines.count, removed.contains(i) {
                result.append(Line(change: .removed, text: oldLines[i]))
                i += 1
            } else if j < newLines.count, inserted.contains(j) {
                result.append(Line(change: .added, text: newLines[j]))
                j += 1
            } else if i < oldLines.count, j < newLines.count {
                result.append(Line(change: .unchanged, text: oldLines[i]))
                i += 1
                j += 1
            } else {
                break  // Unreachable for a valid difference; never loop forever.
            }
        }
        return result
    }
}
