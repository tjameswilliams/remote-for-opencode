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
enum CodeHighlighter {
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

    /// highlight.js language for a file, from its extension. Nil means
    /// "don't guess": auto-detection is slow and wrong often enough that
    /// plain monospaced text is the better failure.
    static func language(forFile path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
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
