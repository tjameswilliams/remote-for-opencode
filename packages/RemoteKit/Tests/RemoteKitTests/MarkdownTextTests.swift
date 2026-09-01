import Testing

@testable import RemoteKit

/// The block parser behind the transcript's markdown. Rendering is visual,
/// but which block a line lands in is pure logic and worth pinning down:
/// a table mistaken for a paragraph shows up as one run-on line of pipes.
@Suite("Markdown blocks")
struct MarkdownTextTests {
    @Test("Pipe table becomes a table block with a header")
    func table() {
        let blocks = MarkdownText.blocks(of: """
        Before.

        | Name | Value |
        |------|-------|
        | a    | 1     |
        | b    | 2     |

        After.
        """)
        #expect(blocks.count == 3)
        guard case let .table(rows, hasHeader) = blocks[1] else {
            Issue.record("expected a table, got \(blocks[1])")
            return
        }
        #expect(hasHeader)
        #expect(rows == [["Name", "Value"], ["a", "1"], ["b", "2"]])
    }

    @Test("Alignment colons still read as a separator")
    func alignedSeparator() {
        let blocks = MarkdownText.blocks(of: "| L | R |\n|:--|--:|\n| a | b |")
        guard case let .table(rows, hasHeader) = blocks.first else {
            Issue.record("expected a table")
            return
        }
        #expect(hasHeader)
        #expect(rows.count == 2)
    }

    @Test("Rows without a separator keep no header")
    func headerless() {
        let blocks = MarkdownText.blocks(of: "| a | 1 |\n| b | 2 |")
        guard case let .table(rows, hasHeader) = blocks.first else {
            Issue.record("expected a table")
            return
        }
        #expect(!hasHeader)
        #expect(rows == [["a", "1"], ["b", "2"]])
    }

    @Test("A table ends where the next block begins")
    func tableThenList() {
        let blocks = MarkdownText.blocks(of: "| a | 1 |\n- item")
        #expect(blocks.count == 2)
        guard case .table = blocks[0], case .bullet = blocks[1] else {
            Issue.record("expected table then bullets, got \(blocks)")
            return
        }
    }

    @Test("Pipes inside a code fence stay code")
    func pipesInCode() {
        let blocks = MarkdownText.blocks(of: "```\n| not | a | table |\n```")
        guard case let .code(text) = blocks.first else {
            Issue.record("expected code")
            return
        }
        #expect(text == "| not | a | table |")
    }

    @Test("A lone pipe in prose is not a table")
    func proseWithPipe() {
        let blocks = MarkdownText.blocks(of: "use a | b in the shell")
        guard case .paragraph = blocks.first else {
            Issue.record("expected a paragraph")
            return
        }
        #expect(blocks.count == 1)
    }
}
