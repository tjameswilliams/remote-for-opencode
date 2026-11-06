import Highlightr
import SwiftUI

/// Syntax highlighting for code the agent writes, shared by the tool
/// preview on both platforms. Highlightr wraps highlight.js in
/// JavaScriptCore; spinning up that context costs real milliseconds, so
/// one engine is built per appearance and kept.
///
/// Themes are gruvbox: the bundled family closest to the app's warm
/// neutral palette (browns, olives, an apricot-adjacent orange). A custom
/// palette-mapped theme isn't possible today — Highlightr only loads its
/// bundled CSS — and gruvbox is close enough that nothing clashes. The
/// theme's own background is ignored; the view draws the app's surface.
public enum CodeHighlighter {
    /// One serial queue for all highlighting: Highlightr instances are not
    /// thread-safe, and code previews are occasional, not a firehose.
    private static let queue = DispatchQueue(label: "code-highlight", qos: .userInitiated)
    private static var engines: [Bool: Highlightr] = [:]

    /// Only ever called on `queue`.
    private static func engine(dark: Bool) -> Highlightr? {
        if let engine = engines[dark] { return engine }
        guard let engine = Highlightr() else { return nil }
        engine.setTheme(to: dark ? "gruvbox-dark" : "gruvbox-light")
        engine.theme.setCodeFont(codeFont())
        engines[dark] = engine
        return engine
    }

    /// The reading size for code, tracking Dynamic Type at engine creation.
    /// (A size change mid-session re-highlights at the old size until
    /// relaunch — acceptable for a preview.)
    private static func codeFont() -> RPFont {
        #if canImport(UIKit)
        let size = UIFont.preferredFont(forTextStyle: .footnote).pointSize
        #else
        let size = NSFont.preferredFont(forTextStyle: .footnote).pointSize
        #endif
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Nil when the language is unknown or highlighting fails — callers
    /// render the plain text instead; a wrong guess colors code as noise.
    static func highlight(_ code: String, language: String?, dark: Bool) async -> AttributedString? {
        guard let language else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async {
                let highlighted = engine(dark: dark)?
                    .highlight(code, as: language, fastRender: true)
                continuation.resume(returning: highlighted.map(AttributedString.init))
            }
        }
    }

    /// Past this, a whole file is shown plain: highlight.js runs in
    /// JavaScriptCore and a megabyte of source would hold the queue for
    /// seconds.
    public static let fileLimit = 300_000

    /// A whole file, highlighted, as the platform's attributed string at
    /// `size` points, for a text view to show. Nil when the language is
    /// unknown, the file is past `fileLimit`, or highlighting fails.
    public static func highlightFile(
        _ code: String, language: String?, dark: Bool, size: CGFloat
    ) async -> NSAttributedString? {
        guard let language, code.utf8.count <= fileLimit else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async {
                guard let highlighted = engine(dark: dark)?
                    .highlight(code, as: language, fastRender: true)
                else { return continuation.resume(returning: nil) }
                continuation.resume(returning: resized(highlighted, to: size))
            }
        }
    }

    /// The same, split into lines, for a lazily drawn list of rows.
    public static func highlightLines(
        _ code: String, language: String?, dark: Bool, size: CGFloat
    ) async -> [AttributedString]? {
        guard let whole = await highlightFile(code, language: language, dark: dark, size: size)
        else { return nil }
        return lines(of: whole)
    }

    /// One attributed string per line, without the line breaks.
    static func lines(of whole: NSAttributedString) -> [AttributedString] {
        let string = whole.string as NSString
        var lines: [AttributedString] = []
        var start = 0
        while start <= string.length {
            let rest = NSRange(location: start, length: string.length - start)
            let newline = string.range(of: "\n", options: [], range: rest)
            let end = newline.location == NSNotFound ? string.length : newline.location
            lines.append(AttributedString(
                whole.attributedSubstring(from: NSRange(location: start, length: end - start))
            ))
            if newline.location == NSNotFound { break }
            start = end + 1
        }
        return lines
    }

    /// The engine's fonts rebuilt as the system monospaced face at
    /// `size`, keeping bold and italic. Rebuilt rather than resized: the
    /// theme's italic (comments) is derived in a way that lands on a
    /// proportional face, and a comment out of the grid misaligns the code.
    private static func resized(_ source: NSAttributedString, to size: CGFloat) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: source)
        let whole = NSRange(location: 0, length: copy.length)
        var cache: [String: RPFont] = [:]
        copy.enumerateAttribute(.font, in: whole) { value, range, _ in
            guard let font = value as? RPFont else { return }
            #if canImport(UIKit)
            let traits = font.fontDescriptor.symbolicTraits
            let bold = traits.contains(.traitBold)
            let italic = traits.contains(.traitItalic)
            #else
            let traits = font.fontDescriptor.symbolicTraits
            let bold = traits.contains(.bold)
            let italic = traits.contains(.italic)
                || font.fontName.lowercased().contains("italic")
                || font.fontName.lowercased().contains("oblique")
            #endif
            let key = "\(bold)\(italic)"
            if cache[key] == nil { cache[key] = monospaced(size: size, bold: bold, italic: italic) }
            copy.addAttribute(.font, value: cache[key]!, range: range)
        }
        return copy
    }

    private static func monospaced(size: CGFloat, bold: Bool, italic: Bool) -> RPFont {
        let base = RPFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
        guard italic else { return base }
        #if canImport(UIKit)
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(
            base.fontDescriptor.symbolicTraits.union(.traitItalic)
        ) else { return base }
        return UIFont(descriptor: descriptor, size: size)
        #else
        let descriptor = base.fontDescriptor.withSymbolicTraits(
            base.fontDescriptor.symbolicTraits.union(.italic)
        )
        return NSFont(descriptor: descriptor, size: size) ?? base
        #endif
    }

    /// highlight.js language for a file, from its extension. Nil means
    /// "don't guess": auto-detection is slow and wrong often enough that
    /// plain monospaced text is the better failure.
    public static func language(forFile path: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        switch name {
        case "dockerfile": return "dockerfile"
        case "makefile", "gnumakefile": return "makefile"
        case "cmakelists.txt": return "cmake"
        case "gemfile", "podfile", "rakefile", "fastfile", "appfile": return "ruby"
        case ".zshrc", ".bashrc", ".bash_profile", ".zprofile", ".profile": return "bash"
        case ".gitignore", ".gitattributes", ".env", ".editorconfig", ".npmrc": return "ini"
        default: break
        }
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "lua": return "lua"
        case "dart": return "dart"
        case "scala", "sc": return "scala"
        case "r": return "r"
        case "pl", "pm": return "perl"
        case "ex", "exs": return "elixir"
        case "hs": return "haskell"
        case "clj", "cljs", "edn": return "clojure"
        case "erl": return "erlang"
        case "gradle": return "gradle"
        case "proto": return "protobuf"
        case "less": return "less"
        case "jsonc", "json5", "jsonl": return "json"
        case "cfg", "conf", "env": return "ini"
        case "mk": return "makefile"
        case "tex": return "latex"
        case "bat", "cmd": return "dos"
        case "ps1": return "powershell"
        case "fish": return "bash"
        case "swift": return "swift"
        case "ts", "tsx", "mts", "cts": return "typescript"
        case "js", "jsx", "mjs", "cjs": return "javascript"
        case "py": return "python"
        case "rb": return "ruby"
        case "go": return "go"
        case "rs": return "rust"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp": return "cpp"
        case "m", "mm": return "objectivec"
        case "cs": return "csharp"
        case "sh", "bash", "zsh": return "bash"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        case "toml", "ini": return "ini"
        case "md", "markdown": return "markdown"
        case "html", "htm", "astro", "vue", "svelte": return "html"
        case "css": return "css"
        case "scss", "sass": return "scss"
        case "sql": return "sql"
        case "php": return "php"
        case "xml", "plist", "entitlements", "storyboard", "xib", "svg": return "xml"
        case "diff", "patch": return "diff"
        default: return nil
        }
    }
}

/// A block of code the agent is writing, highlighted, collapsed to a peek.
///
/// Follows MarkdownText's code-block ruling exactly: scrolls horizontally,
/// never wraps — wrapping destroys indentation, which is the only
/// structure code has. Collapsed to the first lines by default because a
/// transcript is a conversation, not an editor; the block expands in place
/// when the code is the thing being read.
public struct CodePreview: View {
    let code: String
    let language: String?

    /// Collapsed height, in source lines: enough to recognise what is
    /// being written, small enough that three edits in a turn still read
    /// as a conversation.
    private static let peek = 12

    @State private var highlighted: AttributedString?
    @State private var expanded = false
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var lineSpacing: CGFloat = 3

    public init(code: String, file: String?) {
        self.code = code
        language = file.flatMap(CodeHighlighter.language(forFile:))
    }

    private var lines: [Substring] { code.split(separator: "\n", omittingEmptySubsequences: false) }

    public var body: some View {
        let lines = lines
        let shown = expanded ? code : lines.prefix(Self.peek).joined(separator: "\n")
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(highlighted.map { slice($0, to: shown) } ?? AttributedString(shown))
                    .font(.system(.footnote, design: .monospaced))
                    .lineSpacing(lineSpacing)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if lines.count > Self.peek {
                Button {
                    expanded.toggle()
                } label: {
                    Text(expanded ? "Show less" : "Show all \(lines.count) lines")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .task(id: TaskKey(code: code, dark: colorScheme == .dark)) {
            highlighted = await CodeHighlighter.highlight(
                code, language: language, dark: colorScheme == .dark
            )
        }
    }

    /// The whole part is highlighted once; the collapsed view shows a
    /// prefix of that same attributed text so collapsing costs nothing.
    private func slice(_ attributed: AttributedString, to shown: String) -> AttributedString {
        guard shown.count < code.count else { return attributed }
        let characters = attributed.characters
        guard let end = characters.index(
            characters.startIndex, offsetBy: shown.count, limitedBy: characters.endIndex
        ) else { return attributed }
        return AttributedString(attributed[characters.startIndex ..< end])
    }

    private struct TaskKey: Equatable {
        let code: String
        let dark: Bool
    }
}
