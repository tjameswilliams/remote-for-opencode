import Foundation
import SwiftUI

/// Turns file references in the agent's prose into links: `Transcript.swift`,
/// `app/Shared/Transcript.swift:42`, an absolute path inside the project.
///
/// Only names that are files in the project's index link, so a sentence
/// that happens to contain "e.g." or "v1.2" stays text. A bare name links
/// when exactly one file has it (or a project-root file does); a partial
/// path links when exactly one file ends with it.
public final class FileLinks {
    /// The scheme the links carry; a client's `openURL` handler claims it.
    public static let scheme = "opencodego-file"

    public let root: String
    private let paths: Set<String>
    /// Every trailing run of components ("c.swift", "b/c.swift", ...) to
    /// the one file it names, or nil when several files share it.
    private let suffixes: [String: String?]

    public init(root: String, paths: [String]) {
        self.root = root.hasSuffix("/") ? String(root.dropLast()) : root
        self.paths = Set(paths)
        var suffixes: [String: String?] = [:]
        for path in paths {
            let parts = path.split(separator: "/")
            for start in parts.indices.dropFirst() {
                let key = parts[start...].joined(separator: "/")
                if let existing = suffixes[key], existing != path {
                    suffixes[key] = .some(nil)
                } else {
                    suffixes[key] = path
                }
            }
        }
        self.suffixes = suffixes
    }

    public struct Target: Equatable {
        public var path: String
        public var line: Int?
    }

    /// The project file a reference names, with the line it cites, if any.
    public func resolve(_ reference: String) -> Target? {
        // Brackets and quotes either side, sentence punctuation after, in
        // any nesting: "(Foo.swift)." A leading dot stays: .gitignore.
        var token = reference
        while true {
            var trimmed = token.trimmingCharacters(in: Self.wrapping)
            while let last = trimmed.last, ".:,".contains(last) { trimmed.removeLast() }
            if trimmed == token { break }
            token = trimmed
        }
        guard !token.isEmpty, !token.contains("://") else { return nil }
        var line: Int?
        if let match = Self.lineSuffix.firstMatch(
            in: token, range: NSRange(token.startIndex..., in: token)
        ), let cut = Range(match.range, in: token) {
            let digits = match.range(at: 1).location != NSNotFound ? 1 : 2
            if let range = Range(match.range(at: digits), in: token) { line = Int(token[range]) }
            token = String(token[..<cut.lowerBound])
        }
        if token.hasPrefix("./") { token = String(token.dropFirst(2)) }
        if token.hasPrefix("/") {
            guard token.hasPrefix(root + "/") else { return nil }
            token = String(token.dropFirst(root.count + 1))
        }
        guard !token.isEmpty else { return nil }
        if paths.contains(token) { return Target(path: token, line: line) }
        if case let .some(.some(path)) = suffixes[token] { return Target(path: path, line: line) }
        return nil
    }

    // MARK: - URLs

    public static func url(for target: Target) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "file"
        components.path = "/" + target.path
        if let line = target.line { components.queryItems = [URLQueryItem(name: "line", value: String(line))] }
        return components.url
    }

    /// The file a link names: one of ours, or a markdown link written as a
    /// bare relative path (`[the store](Sources/TokenStore.swift)`).
    public func target(of url: URL) -> Target? {
        if let own = Self.target(ofLink: url) { return own }
        if url.scheme == nil || url.scheme == "file" {
            let raw = url.scheme == "file" ? url.path : url.relativeString
            let decoded = raw.removingPercentEncoding ?? raw
            return resolve(decoded)
        }
        return nil
    }

    /// The file one of our own links names; nil for any other URL.
    public static func target(ofLink url: URL) -> Target? {
        guard url.scheme == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let path = String(components.path.dropFirst())
        let line = components.queryItems?.first { $0.name == "line" }?.value.flatMap(Int.init)
        return path.isEmpty ? nil : Target(path: path, line: line)
    }

    // MARK: - Linking

    /// `text` with every resolvable file reference made a link. Code spans
    /// are tried whole; plain text is scanned for path-shaped words.
    /// Existing links are left alone.
    public func linked(_ text: AttributedString) -> AttributedString {
        var result = text
        var edits: [(Range<AttributedString.Index>, URL)] = []
        for run in text.runs where run.link == nil {
            let piece = String(text[run.range].characters)
            if run.inlinePresentationIntent?.contains(.code) == true {
                if let target = resolve(piece), let url = Self.url(for: target) {
                    edits.append((run.range, url))
                }
                continue
            }
            let ns = piece as NSString
            for match in Self.pathWord.matches(in: piece, range: NSRange(location: 0, length: ns.length)) {
                guard let target = resolve(ns.substring(with: match.range)),
                      let url = Self.url(for: target),
                      let local = Range(match.range, in: piece)
                else { continue }
                let startOffset = piece.distance(from: piece.startIndex, to: local.lowerBound)
                let length = piece.distance(from: local.lowerBound, to: local.upperBound)
                let start = text.characters.index(run.range.lowerBound, offsetBy: startOffset)
                let end = text.characters.index(start, offsetBy: length)
                edits.append((start ..< end, url))
            }
        }
        for (range, url) in edits {
            result[range].link = url
        }
        return result
    }

    /// Punctuation a reference sits inside or ends a sentence with.
    private static let wrapping = CharacterSet(charactersIn: "`'\"()[]{}<>,;!?").union(.whitespaces)

    /// `:42`, `:42:7`, `:42-50`, `#L42`, `#L42-L50` at the end.
    private static let lineSuffix = try! NSRegularExpression(
        pattern: #"(?::(\d+)(?::\d+)?(?:-\d+)?|#L(\d+)(?:-L?\d+)?)$"#
    )

    /// A word with a dot-extension or a slash, optionally a line suffix.
    private static let pathWord = try! NSRegularExpression(
        pattern: #"(?<![\w/.~-])(?:[\w.~@+-]*/)*[\w@+-][\w.@+-]*\.[A-Za-z0-9]{1,12}(?::\d+(?::\d+)?(?:-\d+)?|#L\d+(?:-L?\d+)?)?(?![\w/])"#
    )
}

private struct FileLinksKey: EnvironmentKey {
    static let defaultValue: FileLinks? = nil
}

public extension EnvironmentValues {
    /// The project's file index as a link resolver, for `MarkdownText` to
    /// turn file references into links. Nil leaves prose as it is.
    var fileLinks: FileLinks? {
        get { self[FileLinksKey.self] }
        set { self[FileLinksKey.self] = newValue }
    }
}
