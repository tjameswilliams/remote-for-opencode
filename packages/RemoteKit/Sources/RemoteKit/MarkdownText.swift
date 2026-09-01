import SwiftUI

/// Renders the model's markdown.
///
/// SwiftUI's `Text(AttributedString(markdown:))` handles *inline* syntax
/// (bold, italic, code, links) but silently drops block structure — a bullet
/// list arrives as one run-on paragraph still showing its `*` characters. So
/// split into blocks here and render each one, using AttributedString only
/// for the inline pass.
///
/// Parsing runs on every streamed token, so it stays linear and allocation-
/// light: no regex, single pass over lines.
public struct MarkdownText: View {
    let text: String

    public init(text: String) { self.text = text }

    // Reading rhythm (see app/STYLEGUIDE.md). Scaled with Dynamic Type so
    // the gaps keep pace with the text at accessibility sizes.
    @ScaledMetric(relativeTo: .body) private var bodyLineSpacing: CGFloat = 3
    @ScaledMetric(relativeTo: .body) private var blockSpacing: CGFloat = 11
    @ScaledMetric(relativeTo: .body) private var itemSpacing: CGFloat = 5
    @ScaledMetric(relativeTo: .body) private var headingTopPadding: CGFloat = 8

    public var body: some View {
        VStack(alignment: .leading, spacing: blockSpacing) {
            ForEach(Array(Self.blocks(of: text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case let .paragraph(text):
            Text(Self.inline(text))
                .lineSpacing(bodyLineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case let .heading(text, level):
            Text(Self.inline(text))
                .font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                .textSelection(.enabled)
                .padding(.top, headingTopPadding)
        case let .bullet(items):
            VStack(alignment: .leading, spacing: itemSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker).foregroundStyle(.secondary)
                        Text(Self.inline(item.text))
                            .lineSpacing(bodyLineSpacing)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 14)
                }
            }
        case let .table(rows, hasHeader):
            // Same horizontal-scroll bargain as code: a wide table squeezed
            // into a phone column becomes single-character cells, so let it
            // keep its shape and scroll instead.
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leadingFirstTextBaseline,
                     horizontalSpacing: 16,
                     verticalSpacing: itemSpacing) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(Self.inline(cell))
                                    .font(hasHeader && rowIndex == 0
                                        ? .subheadline.weight(.semibold) : .subheadline)
                                    .lineSpacing(bodyLineSpacing)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
        case let .code(text):
            // Scrolls horizontally, never wraps. Fitting 80 columns on a
            // phone would need roughly a 7.5pt font — below Apple's floor
            // and unreadable — and wrapping destroys indentation, which is
            // the only structure code has. Better to scroll a line than to
            // mangle a block.
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.subheadline, design: .monospaced))
                    .lineSpacing(bodyLineSpacing)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
        }
    }

    // MARK: - Model

    struct Item {
        var marker: String
        var text: String
        var depth: Int
    }

    enum Block {
        case paragraph(String)
        case heading(String, Int)
        case bullet([Item])
        case code(String)
        /// Rows of cells; `hasHeader` when a `|---|` separator followed the
        /// first row, which then renders bold.
        case table(rows: [[String]], hasHeader: Bool)
    }

    /// Inline markdown only. `.inlineOnlyPreservingWhitespace` keeps the
    /// spacing we already laid out and prevents the parser from swallowing
    /// list markers we handle ourselves.
    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }

    static func blocks(of text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var items: [Item] = []
        var code: [String] = []
        var inCode = false
        var tableRows: [[String]] = []
        var tableHasHeader = false

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph.removeAll()
            }
        }
        func flushItems() {
            if !items.isEmpty {
                blocks.append(.bullet(items))
                items.removeAll()
            }
        }
        func flushTable() {
            if !tableRows.isEmpty {
                blocks.append(.table(rows: tableRows, hasHeader: tableHasHeader))
                tableRows.removeAll()
            }
            tableHasHeader = false
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine

            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    blocks.append(.code(code.joined(separator: "\n")))
                    code.removeAll()
                } else {
                    flushParagraph()
                    flushItems()
                    flushTable()
                }
                inCode.toggle()
                continue
            }
            if inCode {
                code.append(line)
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                flushItems()
                flushTable()
                continue
            }

            // Heading: #, ##, ###
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }.count
                let body = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                if !body.isEmpty {
                    flushParagraph()
                    flushItems()
                    flushTable()
                    blocks.append(.heading(body, hashes))
                    continue
                }
            }

            // Table rows: `| a | b |`. The `|---|` separator after the first
            // row marks it as a header; a stray separator anywhere else is
            // kept as data rather than guessed at.
            if trimmed.hasPrefix("|"), trimmed.dropFirst().contains("|") {
                flushParagraph()
                flushItems()
                let cells = tableCells(trimmed)
                if tableRows.count == 1, !tableHasHeader,
                   cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }) {
                    tableHasHeader = true
                } else {
                    tableRows.append(cells)
                }
                continue
            }

            // Indent depth from the raw line (2 spaces per level).
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            let depth = min(indent / 2, 3)

            // Bullets: -, *, + followed by whitespace. Gemma emits `*   text`.
            if let first = trimmed.first, "-*+".contains(first),
               trimmed.dropFirst().first == " " {
                let body = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                flushParagraph()
                flushTable()
                items.append(Item(marker: "•", text: body, depth: depth))
                continue
            }

            // Numbered: 1. / 1)
            if let dot = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }),
               trimmed.distance(from: trimmed.startIndex, to: dot) <= 2,
               trimmed[trimmed.startIndex ..< dot].allSatisfy(\.isNumber),
               trimmed.index(after: dot) < trimmed.endIndex,
               trimmed[trimmed.index(after: dot)] == " " {
                let number = String(trimmed[trimmed.startIndex ..< dot])
                let body = trimmed[trimmed.index(after: dot)...]
                    .trimmingCharacters(in: .whitespaces)
                flushParagraph()
                flushTable()
                items.append(Item(marker: "\(number).", text: body, depth: depth))
                continue
            }

            flushItems()
            flushTable()
            paragraph.append(trimmed)
        }

        if inCode, !code.isEmpty { blocks.append(.code(code.joined(separator: "\n"))) }
        flushParagraph()
        flushItems()
        flushTable()
        return blocks
    }

    /// Cells of one `| a | b |` line: split on pipes, shed the empty ends
    /// the outer pipes leave behind, trim the rest.
    static func tableCells(_ line: String) -> [String] {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }
}
