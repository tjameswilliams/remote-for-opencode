import Foundation
import Testing

@testable import RemoteKit

/// File references in the agent's replies: what links, where it points,
/// and what stays prose.
@Suite("File links")
struct FileLinksTests {
    let links = FileLinks(root: "/Users/me/app", paths: [
        "README.md",
        "docs/README.md",
        "app/Shared/Transcript.swift",
        "app/Phone/SessionView.swift",
        "tools/harness/SessionView.swift",
        "app/MacCompanion/Workspace/WorkspaceSessionView.swift",
        ".gitignore",
    ])

    @Test("Names, partial paths, and absolute paths resolve to one file")
    func resolution() {
        #expect(links.resolve("Transcript.swift")?.path == "app/Shared/Transcript.swift")
        #expect(links.resolve("Shared/Transcript.swift")?.path == "app/Shared/Transcript.swift")
        #expect(links.resolve("app/Shared/Transcript.swift")?.path == "app/Shared/Transcript.swift")
        #expect(links.resolve("./app/Shared/Transcript.swift")?.path == "app/Shared/Transcript.swift")
        #expect(links.resolve("/Users/me/app/app/Shared/Transcript.swift")?.path == "app/Shared/Transcript.swift")
        #expect(links.resolve(".gitignore")?.path == ".gitignore")
    }

    @Test("Ambiguous names link only when one is the exact path")
    func ambiguity() {
        #expect(links.resolve("README.md")?.path == "README.md")
        #expect(links.resolve("docs/README.md")?.path == "docs/README.md")
        // Two files are named SessionView.swift; WorkspaceSessionView.swift
        // is not one of them.
        #expect(links.resolve("SessionView.swift") == nil)
        #expect(links.resolve("WorkspaceSessionView.swift") != nil)
        #expect(links.resolve("Phone/SessionView.swift")?.path == "app/Phone/SessionView.swift")
    }

    @Test("Line citations and punctuation come off")
    func lines() {
        #expect(links.resolve("Transcript.swift:42") == .init(path: "app/Shared/Transcript.swift", line: 42))
        #expect(links.resolve("Transcript.swift:42:7") == .init(path: "app/Shared/Transcript.swift", line: 42))
        #expect(links.resolve("Transcript.swift:42-50") == .init(path: "app/Shared/Transcript.swift", line: 42))
        #expect(links.resolve("Transcript.swift#L12-L20") == .init(path: "app/Shared/Transcript.swift", line: 12))
        #expect(links.resolve("(Transcript.swift).")?.path == "app/Shared/Transcript.swift")
    }

    @Test("Things that aren't project files stay prose")
    func nonFiles() {
        #expect(links.resolve("Nope.swift") == nil)
        #expect(links.resolve("/etc/hosts") == nil)
        #expect(links.resolve("https://example.com/README.md") == nil)
        #expect(links.resolve("e.g.") == nil)
    }

    @Test("Prose gets links on the file names only")
    func linking() throws {
        let text = try AttributedString(
            markdown: "Fixed in `Transcript.swift` and Phone/SessionView.swift:12, see e.g. [docs](https://x.y/README.md) or Nope.swift.",
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        let linked = links.linked(text)
        var found: [(String, URL)] = []
        for run in linked.runs {
            if let url = run.link { found.append((String(linked[run.range].characters), url)) }
        }
        #expect(found.map(\.0) == ["Transcript.swift", "Phone/SessionView.swift:12", "docs"])
        #expect(FileLinks.target(ofLink: found[1].1) == .init(path: "app/Phone/SessionView.swift", line: 12))
        #expect(FileLinks.target(ofLink: found[2].1) == nil)
    }

    @Test("A markdown link written as a relative path opens the file")
    func relativeLinks() throws {
        #expect(links.target(of: try #require(URL(string: "app/Shared/Transcript.swift")))?.path
            == "app/Shared/Transcript.swift")
        #expect(links.target(of: try #require(URL(string: "https://example.com"))) == nil)
    }
}
