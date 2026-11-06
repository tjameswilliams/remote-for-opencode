import PDFKit
import RemoteKit
import SwiftUI
import WebKit

/// One opened project file, drawn the way its kind reads best: code
/// highlighted with line numbers, markdown rendered, images and PDFs
/// native, HTML and SVG in an offline web view. `showSource` flips the
/// rendered kinds to their text; `draft` (set while editing) turns the
/// source into an editor over that text.
struct FileViewer: View {
    let content: FileContent
    var showSource = false
    /// The line to bring into view and mark, in the source.
    var line: Int?
    var draft: Binding<String>?

    var body: some View {
        VStack(spacing: 0) {
            if content.truncated == true {
                notice("Showing the first \(FileBrowser.size(content.text?.utf8.count ?? 0)) of \(FileBrowser.size(content.size)).")
            }
            viewer
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var viewer: some View {
        if let draft {
            CodeFileView(text: content.text ?? "", path: content.path, draft: draft)
        } else {
            switch content.kind {
            case .image:
                ImageFileView(data: content.data ?? Data())
            case .pdf:
                PDFFileView(data: content.data ?? Data())
            case .markdown where !showSource:
                ScrollView {
                    MarkdownText(text: content.text ?? "")
                        .foregroundStyle(Color.ink)
                        .frame(maxWidth: 760, alignment: .leading)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .html where !showSource:
                WebFileView(html: content.text ?? "")
            case .svg where !showSource:
                WebFileView(html: WebFileView.page(forSVG: content.text ?? ""))
            case .binary:
                BinaryFileView(content: content)
            default:
                CodeFileView(text: content.text ?? "", path: content.path, line: line)
            }
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color.inkMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.surface)
    }
}

// MARK: - Code

/// Source text, highlighted when the language is known and the file small
/// enough, with a line-number gutter. Never wraps: indentation is the only
/// structure code has. With a `draft`, an editor over it.
struct CodeFileView: View {
    let text: String
    let path: String
    var line: Int?
    var draft: Binding<String>?

    var body: some View {
        #if os(macOS)
        CodeTextView(
            text: text, path: path, language: CodeHighlighter.language(forFile: path),
            line: line, draft: draft
        )
        #else
        if let draft {
            PlainTextEditor(text: draft)
        } else {
            CodeLinesView(text: text, language: CodeHighlighter.language(forFile: path), line: line)
        }
        #endif
    }
}

#if os(macOS)
/// AppKit's text view, because a desktop file viewer has to select across
/// lines, find with ⌘F, open a 50,000-line file without blinking, and edit
/// with the platform's own undo, find and replace.
private struct CodeTextView: NSViewRepresentable {
    let text: String
    let path: String
    let language: String?
    let line: Int?
    let draft: Binding<String>?
    @Environment(\.colorScheme) private var colorScheme

    static let fontSize: CGFloat = 12

    final class Coordinator {
        var shownText: String?
        var shownPath: String?
        var shownDark: Bool?
        var shownLine: Int?
        var editing = false
        var task: Task<Void, Never>?
        var restyle: Task<Void, Never>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> CodeContainer { CodeContainer() }

    func updateNSView(_ view: CodeContainer, context: Context) {
        let dark = colorScheme == .dark
        let coordinator = context.coordinator
        let editing = draft != nil
        let draft = draft
        let language = language

        // Typing reports back to the draft, and the colours follow a beat
        // behind, so the highlighter never runs once per keystroke.
        view.onEdit = { [weak view] string in
            draft?.wrappedValue = string
            coordinator.restyle?.cancel()
            coordinator.restyle = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let highlighted = await CodeHighlighter.highlightFile(
                    string, language: language, dark: dark, size: Self.fontSize
                ) else { return }
                view?.restyle(with: highlighted)
            }
        }
        if editing != coordinator.editing {
            coordinator.editing = editing
            view.setEditable(editing)
            // A cancelled edit shows the file as it was read again.
            if !editing { coordinator.shownText = nil }
        }

        if coordinator.shownText != text || coordinator.shownDark != dark {
            let samePath = coordinator.shownPath == path
            let textChanged = coordinator.shownText != text
            coordinator.shownText = text
            coordinator.shownPath = path
            coordinator.shownDark = dark
            if textChanged {
                // Same file (a save, a reload, a dropped edit): stay where
                // the reader was.
                view.show(plain(text), keepScroll: samePath)
                coordinator.shownLine = nil
            }
            coordinator.task?.cancel()
            let text = text
            coordinator.task = Task { @MainActor in
                guard let highlighted = await CodeHighlighter.highlightFile(
                    text, language: language, dark: dark, size: Self.fontSize
                ), !Task.isCancelled, coordinator.shownText == text else { return }
                // Mid-edit, only the colours change (and only while the
                // text still matches); the text, caret and undo stay put.
                if coordinator.editing {
                    view.restyle(with: highlighted)
                } else {
                    view.show(highlighted, keepScroll: true)
                }
            }
        }

        if let line, line != coordinator.shownLine, !editing {
            coordinator.shownLine = line
            DispatchQueue.main.async { view.reveal(line: line) }
        }
    }

    private func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: Self.fontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])
    }
}

/// A line-number gutter and a scrolling text view, side by side. The
/// gutter is a plain view rather than an NSRulerView: recent macOS lays a
/// ruler over the clip view, hiding the start of every line, and
/// insetting for it moves the ruler along with the text.
private final class CodeContainer: NSView, NSTextViewDelegate {
    let scroll = NSScrollView()
    let textView: NSTextView
    private let gutter = LineGutter()
    var onEdit: ((String) -> Void)?

    override init(frame: NSRect) {
        // TextKit 1, built by hand: the gutter counts lines through the
        // layout manager, which a TextKit 2 view would drop out of anyway.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(
            size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        )
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        textView = NSTextView(frame: .zero, textContainer: container)
        super.init(frame: frame)

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.autoresizingMask = [.width, .height]
        textView.textContainerInset = NSSize(width: 4, height: 10)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = textView

        // Code, not prose: none of the typing "help" that rewrites quotes,
        // dashes and words.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.allowsUndo = true
        textView.delegate = self

        gutter.textView = textView
        addSubview(gutter)
        addSubview(scroll)

        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            gutter, selector: #selector(LineGutter.redraw),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView
        )
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func layout() {
        super.layout()
        let width = gutter.width
        gutter.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        scroll.frame = NSRect(x: width, y: 0, width: max(0, bounds.width - width), height: bounds.height)
    }

    func setEditable(_ editable: Bool) {
        textView.isEditable = editable
        if editable {
            window?.makeFirstResponder(textView)
        } else {
            textView.undoManager?.removeAllActions(withTarget: textView.textStorage as Any)
        }
    }

    func textDidChange(_ notification: Notification) {
        gutter.textChanged()
        needsLayout = true
        onEdit?(textView.string)
    }

    /// New colours for the text being edited, without touching the text,
    /// the selection, or undo.
    func restyle(with highlighted: NSAttributedString) {
        guard let storage = textView.textStorage, storage.string == highlighted.string else { return }
        storage.beginEditing()
        highlighted.enumerateAttributes(
            in: NSRange(location: 0, length: highlighted.length)
        ) { attributes, range, _ in
            storage.setAttributes(attributes, range: range)
        }
        storage.endEditing()
    }

    /// Scrolls `line` (1-based) to the middle of the view and selects it,
    /// with the flash Xcode gives a jump.
    func reveal(line: Int) {
        let string = textView.string as NSString
        var start = 0
        var current = 1
        while current < line, start < string.length {
            let next = string.range(
                of: "\n", options: [], range: NSRange(location: start, length: string.length - start)
            )
            guard next.location != NSNotFound else { break }
            start = next.location + 1
            current += 1
        }
        guard current == line else { return }
        let range = string.lineRange(for: NSRange(location: min(start, string.length), length: 0))
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let visible = scroll.contentView.bounds
        let y = max(0, rect.midY + textView.textContainerOrigin.y - visible.height / 2)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        textView.setSelectedRange(NSRange(location: range.location, length: max(0, range.length - 1)))
        textView.showFindIndicator(for: NSRange(location: range.location, length: max(0, range.length - 1)))
        gutter.needsDisplay = true
    }

    func show(_ string: NSAttributedString, keepScroll: Bool) {
        let origin = scroll.contentView.bounds.origin
        textView.textStorage?.setAttributedString(string)
        gutter.textChanged()
        needsLayout = true
        layoutSubtreeIfNeeded()
        if keepScroll {
            scroll.contentView.scroll(to: origin)
        } else {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            scroll.contentView.scroll(to: .zero)
        }
        scroll.reflectScrolledClipView(scroll.contentView)
        gutter.needsDisplay = true
    }
}

/// Line numbers for a text view. Line starts are indexed once per text,
/// so drawing is a binary search plus the visible lines.
private final class LineGutter: NSView {
    weak var textView: NSTextView?
    private var lineStarts: [Int] = [0]
    private(set) var width: CGFloat = 32

    override var isFlipped: Bool { true }

    @objc func redraw() { needsDisplay = true }

    func textChanged() {
        let string = (textView?.string ?? "") as NSString
        var starts = [0]
        var location = 0
        while location < string.length {
            let range = string.range(
                of: "\n", options: [], range: NSRange(location: location, length: string.length - location)
            )
            guard range.location != NSNotFound else { break }
            starts.append(range.location + 1)
            location = range.location + 1
        }
        lineStarts = starts
        width = CGFloat(max(2, String(starts.count).count)) * 7.5 + 14
        needsDisplay = true
    }

    private static let font = NSFont.monospacedDigitSystemFont(
        ofSize: CodeTextView.fontSize - 1, weight: .regular
    )

    override func draw(_ dirtyRect: NSRect) {
        guard let textView, let layout = textView.layoutManager,
              let container = textView.textContainer else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font, .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let length = (textView.string as NSString).length

        // First visible line: the last start at or before the range.
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= characters.location { low = mid } else { high = mid - 1 }
        }
        var line = low
        let inset = textView.textContainerOrigin.y
        while line < lineStarts.count {
            let start = lineStarts[line]
            if start > NSMaxRange(characters), start > characters.location { break }
            let fragment: NSRect
            if start >= length {
                // The empty last line after a trailing newline.
                fragment = layout.extraLineFragmentRect
                if fragment.isEmpty { break }
            } else {
                let glyph = layout.glyphIndexForCharacter(at: start)
                fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            }
            let top = convert(NSPoint(x: 0, y: fragment.minY + inset), from: textView).y
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(
                at: NSPoint(x: width - size.width - 6, y: top + (fragment.height - size.height) / 2),
                withAttributes: attributes
            )
            line += 1
        }
    }
}
#else
/// Rows drawn as they scroll into view: a phone can't afford to lay out a
/// whole large file at once, and per-line rows keep the gutter aligned.
private struct CodeLinesView: View {
    let text: String
    let language: String?
    let line: Int?
    private let plain: [Substring]

    init(text: String, language: String?, line: Int?) {
        self.text = text
        self.language = language
        self.line = line
        plain = text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    @State private var highlighted: [AttributedString]?
    @Environment(\.colorScheme) private var colorScheme

    private var size: CGFloat { UIFont.preferredFont(forTextStyle: .footnote).pointSize }

    var body: some View {
        let count = highlighted?.count ?? plain.count
        let gutter = CGFloat(max(2, String(count).count)) * size * 0.62
        ScrollViewReader { proxy in
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(0 ..< count, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(index + 1)")
                            .foregroundStyle(Color.inkFaint)
                            .frame(width: gutter, alignment: .trailing)
                        Group {
                            if let highlighted, index < highlighted.count {
                                Text(highlighted[index])
                            } else {
                                Text(index < plain.count ? String(plain[index]) : "")
                                    .foregroundStyle(Color.ink)
                            }
                        }
                        .fixedSize()
                    }
                    .font(.system(size: size, design: .monospaced))
                    .background(index + 1 == line ? Color.clay.opacity(0.16) : Color.clear)
                    .id(index)
                }
            }
            .padding(12)
            .textSelection(.enabled)
        }
        // A two-axis ScrollView centres content smaller than the viewport;
        // a file must start at its first line, flush left.
        .defaultScrollAnchor(.topLeading)
        .task(id: line) {
            guard let line, line > 0 else { return }
            try? await Task.sleep(for: .milliseconds(100))
            proxy.scrollTo(line - 1, anchor: .center)
        }
        }
        .task(id: colorScheme == .dark) {
            highlighted = await CodeHighlighter.highlightLines(
                text, language: language, dark: colorScheme == .dark, size: size
            )
        }
    }
}

/// The phone's editor: UIKit's text view with every prose convenience
/// off. Smart quotes alone would break most of the code typed into it.
private struct PlainTextEditor: UIViewRepresentable {
    @Binding var text: String

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textViewDidChange(_ view: UITextView) { text.wrappedValue = view.text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular
        )
        view.textColor = .label
        view.backgroundColor = .clear
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        view.delegate = context.coordinator
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.text = $text
        if view.text != text { view.text = text }
    }
}
#endif

// MARK: - Images and PDFs

private struct ImageFileView: View {
    let data: Data

    var body: some View {
        if let image = PlatformImage(data: data) {
            // Fitted to the pane, never enlarged past its own size.
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 8) {
                        picture(image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: min(image.size.width, max(0, geometry.size.width - 32)))
                        Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.inkFaint)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity)
                }
            }
        } else {
            Text("This image couldn't be decoded.")
                .font(.footnote)
                .foregroundStyle(Color.inkMuted)
        }
    }

    private func picture(_ image: PlatformImage) -> Image {
        #if os(macOS)
        Image(nsImage: image)
        #else
        Image(uiImage: image)
        #endif
    }
}

#if os(macOS)
private struct PDFFileView: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> PDFView { Self.configured(PDFView()) }
    func updateNSView(_ view: PDFView, context: Context) { Self.show(data, in: view) }
}
#else
private struct PDFFileView: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView { Self.configured(PDFView()) }
    func updateUIView(_ view: PDFView, context: Context) { Self.show(data, in: view) }
}
#endif

private extension PDFFileView {
    static func configured(_ view: PDFView) -> PDFView {
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .clear
        return view
    }

    static func show(_ data: Data, in view: PDFView) {
        guard view.document?.dataRepresentation() != data else { return }
        view.document = PDFDocument(data: data)
    }
}

// MARK: - HTML and SVG

/// A page rendered with nothing reaching the network: the file is the
/// user's, but a preview that phones home (analytics, CDN fonts) is not a
/// preview. Scripts run, so interactive pages still work; a link the user
/// clicks opens in their browser instead of replacing the preview.
struct WebFileView {
    let html: String

    static func page(forSVG svg: String) -> String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width">
        <style>html,body{margin:0;height:100%;background:transparent}
        body{display:flex;align-items:center;justify-content:center}
        svg{max-width:100%;max-height:100%;height:auto}</style></head>
        <body>\(svg)</body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var shown: String?

        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard action.navigationType == .linkActivated else { return decisionHandler(.allow) }
            if let url = action.request.url, ["http", "https", "mailto"].contains(url.scheme ?? "") {
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #else
                UIApplication.shared.open(url)
                #endif
            }
            decisionHandler(.cancel)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = coordinator
        #if os(macOS)
        view.setValue(false, forKey: "drawsBackground")
        #else
        view.isOpaque = false
        view.backgroundColor = .clear
        #endif
        return view
    }

    private func update(_ view: WKWebView, _ coordinator: Coordinator) {
        guard coordinator.shown != html else { return }
        coordinator.shown = html
        let html = html
        Task { @MainActor in
            if let rules = await Self.offlineRules() {
                view.configuration.userContentController.removeAllContentRuleLists()
                view.configuration.userContentController.add(rules)
            } else {
                // Without the block list there is no offline guarantee, and
                // the source view is always one click away.
                view.loadHTMLString(
                    "<p style=\"font:13px -apple-system;color:gray\">Preview unavailable.</p>",
                    baseURL: nil
                )
                return
            }
            view.loadHTMLString(html, baseURL: nil)
        }
    }

    /// Blocks every load with a scheme that leaves the process; the page
    /// itself arrives as a string, so nothing it needs is blocked.
    @MainActor private static var rules: WKContentRuleList?

    @MainActor private static func offlineRules() async -> WKContentRuleList? {
        if let rules { return rules }
        // One rule per scheme: content-blocker regexes have no "|".
        let source = "[" + ["^https?:", "^wss?:", "^ftp:", "^file:", "^blob:"].map {
            #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"block"}}"#
        }.joined(separator: ",") + "]"
        let compiled = try? await WKContentRuleListStore.default()
            .compileContentRuleList(forIdentifier: "opencodego.offline", encodedContentRuleList: source)
        rules = compiled
        return compiled
    }
}

#if os(macOS)
extension WebFileView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) { update(view, context.coordinator) }
}
#else
extension WebFileView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) { update(view, context.coordinator) }
}
#endif

// MARK: - Everything else

private struct BinaryFileView: View {
    let content: FileContent

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc")
                .font(.title)
                .foregroundStyle(Color.inkFaint)
            Text(content.data == nil && FileKind.sendsBytes(path: content.path)
                ? "Too large to preview (\(FileBrowser.size(content.size)))."
                : "A binary file (\(FileBrowser.size(content.size))) with no preview.")
                .font(.footnote)
                .foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
