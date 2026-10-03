import Foundation

/// Whether an entry is a plain snippet or a command template with placeholders.
///
/// Stored as its raw value in SQLite (`notes.kind`) and in the CloudKit record's `kind`
/// field. Unknown or missing values read as `.snippet`, so data from older builds keeps
/// working.
public enum EntryKind: String, Sendable, Hashable, CaseIterable {
    case snippet
    case template

    /// Decodes a stored value. Anything unrecognized is a snippet.
    public init(storedValue: String?) {
        self = storedValue.flatMap(EntryKind.init(rawValue:)) ?? .snippet
    }
}

/// A parsed command template.
///
/// ## Grammar
///
/// A placeholder is `{{name}}`, optionally with spaces inside the braces
/// (`{{ name }}`). `name` starts with an ASCII letter or `_`, followed by ASCII letters,
/// digits, or `_`. Names are case-sensitive.
///
/// Any other `{{` (for example `{{user name}}`, `{{1st}}`, or a `{{` that is never
/// closed) is **malformed**. It is reported, and kept in the output as literal text.
/// There's no escape syntax.
///
/// ## Rendering
///
/// Literal text substitution in a single pass over the parsed segments. A value is
/// inserted as-is and never parsed again, so `{{x}}` inside a value stays literal. This
/// is not a shell parser: values are **not** quoted or escaped for any shell.
///
/// Parsing and rendering are pure functions of their inputs: no I/O, no state. That
/// keeps them easy to test and safe to call from any thread or actor.
public struct Template: Sendable, Equatable {
    public enum Segment: Sendable, Equatable {
        case literal(String)
        case placeholder(String)
    }

    /// A `{{` that doesn't form a valid placeholder.
    public struct Issue: Sendable, Equatable {
        /// 1-based line of the opening `{{`.
        public let line: Int
        /// The offending text, from `{{` up to and including the next `}}` on that line
        /// (or to the end of the line if it's never closed).
        public let text: String
    }

    public let segments: [Segment]
    /// Unique placeholder names, in order of first appearance.
    public let placeholders: [String]
    public let issues: [Issue]

    public init(parsing text: String) {
        var segments: [Segment] = []
        var placeholders: [String] = []
        var issues: [Issue] = []
        var literal = ""
        var line = 1
        var index = text.startIndex

        func flushLiteral() {
            if !literal.isEmpty { segments.append(.literal(literal)) }
            literal = ""
        }

        while index < text.endIndex {
            if text[index...].hasPrefix("{{") {
                if let (name, end) = Self.placeholder(in: text, at: index) {
                    flushLiteral()
                    segments.append(.placeholder(name))
                    if !placeholders.contains(name) { placeholders.append(name) }
                    index = end
                    continue
                }
                // "{{{name}}": a literal "{" followed by a valid placeholder.
                let next = text.index(after: index)
                if text[next...].hasPrefix("{{"), Self.placeholder(in: text, at: next) != nil {
                    literal.append("{")
                    index = next
                    continue
                }
                // Malformed: report it, keep "{{" as literal text, and carry on after it.
                issues.append(Issue(line: line, text: Self.malformedText(in: text, at: index)))
                literal += "{{"
                index = text.index(index, offsetBy: 2)
                continue
            }
            let character = text[index]
            if character.isNewline { line += 1 }
            literal.append(character)
            index = text.index(after: index)
        }
        flushLiteral()
        self.segments = segments
        self.placeholders = placeholders
        self.issues = issues
    }

    /// Names with no value, or an empty one, in placeholder order.
    public func missingValues(in values: [String: String]) -> [String] {
        placeholders.filter { (values[$0] ?? "").isEmpty }
    }

    /// Substitutes `values` in one pass. A placeholder without a non-empty value is left
    /// as `{{name}}`, so a preview shows what's still missing.
    public func render(with values: [String: String]) -> String {
        var output = ""
        for segment in segments {
            switch segment {
            case .literal(let text):
                output += text
            case .placeholder(let name):
                if let value = values[name], !value.isEmpty {
                    output += value
                } else {
                    output += "{{\(name)}}"
                }
            }
        }
        return output
    }

    // MARK: Private

    /// If a valid placeholder starts at `start` (which is at "{{"), its name and the
    /// index just past its closing "}}".
    private static func placeholder(in text: String, at start: String.Index) -> (String, String.Index)? {
        var index = text.index(start, offsetBy: 2)
        func skipSpaces() {
            while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
        }
        skipSpaces()
        var name = ""
        while index < text.endIndex, isIdentifierCharacter(text[index], first: name.isEmpty) {
            name.append(text[index])
            index = text.index(after: index)
        }
        guard !name.isEmpty else { return nil }
        skipSpaces()
        guard text[index...].hasPrefix("}}") else { return nil }
        return (name, text.index(index, offsetBy: 2))
    }

    private static func isIdentifierCharacter(_ character: Character, first: Bool) -> Bool {
        guard character.isASCII else { return false }
        if character == "_" || character.isLetter { return true }
        return !first && character.isNumber
    }

    private static func malformedText(in text: String, at start: String.Index) -> String {
        let rest = text[start...].prefix { !$0.isNewline }
        if let close = rest.range(of: "}}") {
            return String(rest[..<close.upperBound])
        }
        return String(rest)
    }
}
