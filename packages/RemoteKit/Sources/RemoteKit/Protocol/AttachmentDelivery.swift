import Foundation

/// How an attachment reaches the model, decided by what models can
/// actually take.
///
/// OpenCode forwards a file part to the provider untouched, and the
/// provider layer under it (the AI SDK's OpenAI-compatible adapter, for a
/// local vllm) accepts exactly two kinds: images and PDFs. Anything else
/// fails the turn with "'file part media type application/json'
/// functionality not supported", and because the part is now in the
/// thread's history, every turn after it fails the same way. A JSON file
/// is text, though, and every model reads text: it goes inline, the way
/// a pasted file would. What is neither is refused on the phone, before
/// it can poison a thread.
public enum AttachmentDelivery: Equatable, Sendable {
    /// A file part the provider accepts as an image.
    case image
    /// A file part the provider accepts as a document.
    case pdf
    /// Inlined as a text part; the payload is the decoded content.
    case text(String)
    /// Text by type, but more than a prompt can carry.
    case tooLarge
    /// Nothing a model can read.
    case unreadable

    /// Inlined text above this is not a prompt, it is a context window.
    public static let textLimit = 1 << 20

    static let textMimes: Set<String> = [
        "application/json", "application/xml", "application/yaml", "application/x-yaml",
        "application/toml", "application/javascript", "application/typescript",
        "application/x-sh", "application/x-shellscript", "application/sql",
        "application/x-httpd-php", "application/x-python", "application/x-ndjson",
        "application/ld+json", "application/rtf",
    ]

    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "jsonl", "jsonc", "yaml", "yml", "toml", "xml",
        "csv", "tsv", "log", "ini", "cfg", "conf", "env", "sh", "zsh", "bash", "fish",
        "py", "rb", "js", "mjs", "cjs", "ts", "tsx", "jsx", "swift", "m", "h", "c", "cc",
        "cpp", "hpp", "cs", "java", "kt", "go", "rs", "php", "sql", "html", "htm", "css",
        "scss", "less", "vue", "svelte", "graphql", "proto", "tex", "rst", "org", "diff",
        "patch", "lock", "gradle", "cmake", "make", "mk", "dockerfile", "plist",
    ]

    public static func classify(mime: String, name: String, bytes: Data) -> AttachmentDelivery {
        let mime = mime.lowercased().split(separator: ";").first.map(String.init) ?? ""
        if mime.hasPrefix("image/") { return .image }
        if mime == "application/pdf" { return .pdf }
        let ext = (name as NSString).pathExtension.lowercased()
        let declaredText = mime.hasPrefix("text/") || textMimes.contains(mime)
            || mime.hasSuffix("+json") || mime.hasSuffix("+xml")
            || textExtensions.contains(ext) || name.lowercased() == "dockerfile"
        // An unknown type that decodes as UTF-8 without a NUL is text in
        // every way that matters. A declared binary type is taken at its
        // word even when its first bytes happen to be printable, and a
        // declared text type that does not decode is a lie, and not one
        // worth sending.
        let unknownType = mime.isEmpty || mime == "application/octet-stream"
        guard declaredText || (unknownType && looksTextual(bytes)) else { return .unreadable }
        guard bytes.count <= textLimit else { return .tooLarge }
        guard let text = String(data: bytes, encoding: .utf8) else { return .unreadable }
        return .text(text)
    }

    public static func classify(_ attachment: Attachment) -> AttachmentDelivery {
        guard let bytes = Data(base64Encoded: attachment.data) else { return .unreadable }
        return classify(mime: attachment.mime, name: attachment.name, bytes: bytes)
    }

    /// The prompt text for an inlined file: named, fenced, and tagged with
    /// the language a highlighter would use, so the model knows what it
    /// is reading and the transcript renders it the way it was written.
    public static func inlined(name: String, text: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        // A fence longer than any run of backticks in the content, so the
        // file cannot close its own block early.
        var fence = "```"
        while text.contains(fence) { fence += "`" }
        let body = text.hasSuffix("\n") ? text : text + "\n"
        return "Attached file: \(name)\n\(fence)\(ext)\n\(body)\(fence)"
    }

    private static func looksTextual(_ bytes: Data) -> Bool {
        guard !bytes.isEmpty, bytes.count <= textLimit else { return false }
        let sample = bytes.prefix(8192)
        guard !sample.contains(0) else { return false }
        return String(data: sample, encoding: .utf8) != nil
            || String(data: bytes, encoding: .utf8) != nil
    }
}
