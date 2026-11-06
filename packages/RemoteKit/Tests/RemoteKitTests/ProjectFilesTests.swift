import Foundation
import Testing

@testable import RemoteKit

/// The file explorer's rules: which paths stay inside a project, how quick
/// open ranks, and which viewer a file gets.
@Suite("Project files")
struct ProjectFilesTests {
    @Test("Relative paths are cleaned and kept inside the project")
    func relativePaths() {
        #expect(ProjectPath.relative("", to: "/p") == "")
        #expect(ProjectPath.relative("src/a.swift", to: "/p") == "src/a.swift")
        #expect(ProjectPath.relative("./src//b/../a.swift", to: "/p") == "src/a.swift")
        #expect(ProjectPath.relative("../etc/passwd", to: "/p") == nil)
        #expect(ProjectPath.relative("src/../../x", to: "/p") == nil)
    }

    @Test("Absolute paths count only under the root")
    func absolutePaths() {
        #expect(ProjectPath.relative("/Users/me/p/src/a.swift", to: "/Users/me/p") == "src/a.swift")
        #expect(ProjectPath.relative("/Users/me/p", to: "/Users/me/p/") == "")
        #expect(ProjectPath.relative("/Users/me/project2/a", to: "/Users/me/p") == nil)
        #expect(ProjectPath.relative("/Users/me/p/../q/a", to: "/Users/me/p") == nil)
        #expect(ProjectPath.relative("/etc/passwd", to: "/Users/me/p") == nil)
    }

    @Test("Ancestors run outermost first")
    func ancestors() {
        #expect(ProjectPath.ancestors(of: "a/b/c.txt") == ["a", "a/b"])
        #expect(ProjectPath.ancestors(of: "c.txt") == [])
    }

    @Test("Quick open prefers file names, then tighter matches")
    func ranking() {
        let paths = [
            "app/Shared/Transcript.swift",
            "app/Shared/TurnController.swift",
            "docs/transcripts/notes.md",
            "packages/RemoteKit/Sources/RemoteKit/Protocol/TranscriptLoad.swift",
        ]
        let ranked = FileSearch.rank(paths, query: "transcript")
        #expect(ranked.first == "app/Shared/Transcript.swift")
        #expect(ranked.contains("docs/transcripts/notes.md"))
        #expect(!ranked.contains("app/Shared/TurnController.swift"))
        #expect(FileSearch.rank(paths, query: "tc").first == "app/Shared/TurnController.swift")
        #expect(FileSearch.rank(paths, query: "  ").isEmpty)
        #expect(FileSearch.rank(paths, query: "zzz").isEmpty)
    }

    @Test("Folder words narrow a search spread across the path")
    func pathSearch() {
        let paths = ["a/Phone/View.swift", "a/Mac/View.swift"]
        #expect(FileSearch.rank(paths, query: "phoneview") == ["a/Phone/View.swift"])
    }

    @Test("Each kind of file gets its viewer")
    func kinds() {
        #expect(FileKind(path: "a.png", isText: false, hasData: true) == .image)
        #expect(FileKind(path: "a.PNG", isText: false, hasData: false) == .binary)
        #expect(FileKind(path: "a.pdf", isText: false, hasData: true) == .pdf)
        #expect(FileKind(path: "README.md", isText: true, hasData: false) == .markdown)
        #expect(FileKind(path: "logo.svg", isText: true, hasData: false) == .svg)
        #expect(FileKind(path: "index.html", isText: true, hasData: false) == .html)
        #expect(FileKind(path: "main.swift", isText: true, hasData: false) == .text)
        #expect(FileKind(path: "blob.bin", isText: false, hasData: false) == .binary)
        #expect(FileKind.sendsBytes(path: "x/y.jpeg"))
        #expect(!FileKind.sendsBytes(path: "x/y.svg"))
    }

    @Test("Folders sort before files, names in Finder order")
    func ordering() {
        let entries = [
            FileEntry(path: "b.txt", name: "b.txt", directory: false),
            FileEntry(path: "file10", name: "file10", directory: false),
            FileEntry(path: "file9", name: "file9", directory: false),
            FileEntry(path: "z", name: "z", directory: true),
        ].sorted(by: FileEntry.ordered)
        #expect(entries.map(\.name) == ["z", "b.txt", "file9", "file10"])
    }

    @Test("A highlighted file splits into lines without its breaks")
    func lineSplitting() {
        let lines = CodeHighlighter.lines(of: NSAttributedString(string: "a\n\nb\n"))
        #expect(lines.map { String($0.characters) } == ["a", "", "b", ""])
    }

    @Test("File events round-trip with their bytes")
    func wire() throws {
        var event = Wire.Event(kind: "file")
        event.file = FileContent(path: "a.png", size: 3, data: Data([1, 2, 3]))
        let decoded = try JSONDecoder().decode(Wire.Event.self, from: JSONEncoder().encode(event))
        #expect(decoded.file?.data == Data([1, 2, 3]))
        #expect(decoded.file?.kind == .image)
    }
}
