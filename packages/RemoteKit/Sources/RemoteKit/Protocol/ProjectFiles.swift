import Foundation

/// The project file explorer's half of the protocol: a folder's entries
/// (`files`), one file's contents (`file`), every file's path for quick
/// open (`files.index`), and writing a file back (`file.save`). The Mac serves all three straight from
/// disk, so they work whatever OpenCode version is installed, and even
/// while it is restarting.

/// One row of a folder listing.
public struct FileEntry: Codable, Hashable, Sendable, Identifiable {
    /// Relative to the project root, "/"-separated, no leading slash.
    public var path: String
    public var name: String
    public var directory: Bool
    /// Bytes, for files.
    public var size: Int?
    /// Matched by the repository's ignore rules: shown, but dimmed, the
    /// way an editor shows `node_modules`.
    public var ignored: Bool?
    /// Git's view of it: "modified" | "added" | "deleted" | "untracked" |
    /// "renamed" | "conflicted". A folder carries "modified" when anything
    /// under it has changed, so a change is findable from the top.
    public var status: String?

    public var id: String { path }

    public init(
        path: String, name: String, directory: Bool, size: Int? = nil,
        ignored: Bool? = nil, status: String? = nil
    ) {
        self.path = path
        self.name = name
        self.directory = directory
        self.size = size
        self.ignored = ignored
        self.status = status
    }

    /// Folders first, then names the way Finder sorts them.
    public static func ordered(_ a: FileEntry, _ b: FileEntry) -> Bool {
        if a.directory != b.directory { return a.directory }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

/// One file, read for viewing.
public struct FileContent: Codable, Equatable, Sendable {
    public var path: String
    /// The whole file's size on disk, whatever was sent.
    public var size: Int
    /// The decoded text, for anything that reads as UTF-8.
    public var text: String?
    /// The bytes, for what renders natively (images, PDFs). Base64 on the
    /// wire, which the frame compression mostly wins back.
    public var data: Data?
    /// `text` is the head of a file larger than the Mac sends.
    public var truncated: Bool?
    /// A digest of the bytes this was read from, for whole text files.
    /// `file.save` hands it back, so a save can't silently overwrite what
    /// the agent wrote since the file was opened. Absent means the file
    /// can't be edited here (binary, truncated, or an older Mac).
    public var version: String?

    public init(
        path: String, size: Int, text: String? = nil, data: Data? = nil,
        truncated: Bool? = nil, version: String? = nil
    ) {
        self.path = path
        self.size = size
        self.text = text
        self.data = data
        self.truncated = truncated
        self.version = version
    }

    public var kind: FileKind { FileKind(path: path, isText: text != nil, hasData: data != nil) }

    /// Whole text with a version: what an editor can open and save back.
    public var editable: Bool { text != nil && truncated != true && version != nil }
}

/// Which viewer a file gets.
public enum FileKind: Equatable, Sendable {
    case image, pdf, svg, html, markdown, text
    /// Bytes nothing here renders, or too big to send.
    case binary

    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff", "ico", "icns",
    ]

    public init(path: String, isText: Bool, hasData: Bool) {
        let ext = (path as NSString).pathExtension.lowercased()
        if Self.imageExtensions.contains(ext) { self = hasData ? .image : .binary; return }
        if ext == "pdf" { self = hasData ? .pdf : .binary; return }
        guard isText else { self = .binary; return }
        switch ext {
        case "svg": self = .svg
        case "html", "htm": self = .html
        case "md", "markdown", "mdx": self = .markdown
        default: self = .text
        }
    }

    /// Whether the Mac should ship this file's raw bytes rather than text.
    public static func sendsBytes(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext) || ext == "pdf"
    }

    /// Has a rendered view and a source view to switch between.
    public var hasSource: Bool {
        switch self {
        case .svg, .html, .markdown: return true
        default: return false
        }
    }
}

/// Paths inside a project, kept inside it.
public enum ProjectPath {
    /// `path` (project-relative, or absolute under `root`) as a clean
    /// project-relative path: "" for the root itself, nil when it names
    /// somewhere outside. Lexical only; the Mac also resolves symlinks
    /// before it reads anything.
    public static func relative(_ path: String, to root: String) -> String? {
        let rootParts = components(root)
        var parts: [String]
        if path.hasPrefix("/") {
            let absolute = components(path)
            guard absolute.count >= rootParts.count,
                  Array(absolute.prefix(rootParts.count)) == rootParts
            else { return nil }
            parts = Array(absolute.dropFirst(rootParts.count))
        } else {
            parts = []
            for part in path.split(separator: "/", omittingEmptySubsequences: true) {
                switch part {
                case ".": continue
                case "..":
                    guard !parts.isEmpty else { return nil }
                    parts.removeLast()
                default: parts.append(String(part))
                }
            }
        }
        return parts.joined(separator: "/")
    }

    /// The folders that hold `path`, outermost first: "a/b/c.txt" gives
    /// ["a", "a/b"].
    public static func ancestors(of path: String) -> [String] {
        let parts = path.split(separator: "/")
        guard parts.count > 1 else { return [] }
        return (1 ..< parts.count).map { parts.prefix($0).joined(separator: "/") }
    }

    /// Normalised absolute components, with "." and ".." applied.
    private static func components(_ path: String) -> [String] {
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(part))
            }
        }
        return parts
    }
}

/// Quick open: rank a project's paths against what was typed, the way an
/// editor's "go to file" does. Every query character must appear in order;
/// matches inside the file name beat matches spread over folders, and
/// runs of consecutive characters and word starts score higher.
public enum FileSearch {
    public static func rank(_ paths: [String], query: String, limit: Int = 60) -> [String] {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return [] }
        var scored: [(path: String, score: Int)] = []
        for path in paths {
            if let score = score(path, needle: needle) { scored.append((path, score)) }
        }
        scored.sort {
            $0.score != $1.score ? $0.score > $1.score
                : $0.path.count != $1.path.count ? $0.path.count < $1.path.count
                : $0.path < $1.path
        }
        return scored.prefix(limit).map(\.path)
    }

    /// Nil when `needle` isn't a subsequence of the path.
    static func score(_ path: String, needle: [Character]) -> Int? {
        let original = Array(path)
        let haystack = original.map { Character($0.lowercased()) }
        guard haystack.count == original.count else { return nil }
        let nameStart = (haystack.lastIndex(of: "/") ?? -1) + 1
        // Inside the name alone, when it fits there.
        if let inName = match(haystack, original, from: nameStart, needle: needle) {
            return 1000 + inName - (haystack.count - nameStart)
        }
        guard let anywhere = match(haystack, original, from: 0, needle: needle) else { return nil }
        return anywhere - haystack.count / 4
    }

    /// Where a word begins: after a separator, or a capital after a
    /// lowercase letter (the C in TurnController).
    private static func wordStart(_ original: [Character], _ index: Int, from start: Int) -> Bool {
        guard index > start else { return true }
        let previous = original[index - 1]
        if "/._- ".contains(previous) { return true }
        return original[index].isUppercase && previous.isLowercase
    }

    /// Greedy left-to-right subsequence match with bonuses.
    private static func match(
        _ haystack: [Character], _ original: [Character], from start: Int, needle: [Character]
    ) -> Int? {
        var score = 0
        var at = start
        var previous = -2
        for ch in needle {
            var found = -1
            while at < haystack.count {
                if haystack[at] == ch { found = at; break }
                at += 1
            }
            guard found >= 0 else { return nil }
            if found == previous + 1 { score += 8 }
            if wordStart(original, found, from: start) { score += 6 }
            score += 1
            previous = found
            at = found + 1
        }
        return score
    }
}
