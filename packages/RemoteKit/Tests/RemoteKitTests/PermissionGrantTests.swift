import Foundation
import Testing

@testable import RemoteKit

/// The scope picker is policy about what a user is allowed to say yes
/// to in one tap, so its edges are pinned here: a dangerous command
/// gets no wider grant, a project scope appears only when it says more
/// than "this folder", and the config edit never loses what the user
/// had already written by hand.
@Suite("Permission grants")
struct PermissionGrantTests {
    private func ask(
        _ permission: String, _ patterns: [String], always: [String]? = nil
    ) -> PermissionRequest {
        PermissionRequest(
            id: "per_1", sessionID: "ses_1", permission: permission, patterns: patterns,
            always: always ?? patterns,
            risk: PermissionRisk.classify(permission: permission, patterns: patterns).rawValue
        )
    }

    @Test("A folder outside the project offers the folder and its whole project")
    func folderScopes() {
        let request = ask("external_directory", ["/Users/t/www/proj/server/lib/*"])
        let scopes = PermissionScopes.candidates(for: request) { path in
            path.hasPrefix("/Users/t/www/proj") ? "/Users/t/www/proj" : nil
        }
        #expect(scopes.map(\.id) == ["folder", "project"])
        #expect(scopes[0].patterns == ["/Users/t/www/proj/server/lib/*"])
        #expect(scopes[1].label == "Whole project: proj")
        #expect(scopes[1].patterns == ["/Users/t/www/proj/**"])
    }

    @Test("No repository, or the folder is the project root, means folder only")
    func folderOnly() {
        let loose = ask("external_directory", ["/tmp/scratch/*"])
        #expect(PermissionScopes.candidates(for: loose) { _ in nil }.map(\.id) == ["folder"])
        let root = ask("external_directory", ["/Users/t/www/proj/*"])
        #expect(PermissionScopes.candidates(for: root) { _ in "/Users/t/www/proj" }.map(\.id) == ["folder"])
    }

    @Test("A command offers itself and its first word; a dangerous one offers nothing")
    func commandScopes() {
        let git = PermissionScopes.candidates(for: ask("bash", ["git log --oneline"])) { _ in nil }
        #expect(git.map(\.id) == ["command", "prefix"])
        #expect(git[1].patterns == ["git *"])
        #expect(git[1].label == "Every git command")
        let bare = PermissionScopes.candidates(for: ask("bash", ["pwd"])) { _ in nil }
        #expect(bare.map(\.id) == ["command"])
        let rm = PermissionScopes.candidates(for: ask("bash", ["rm -rf build"])) { _ in nil }
        #expect(rm.isEmpty)
        let fetch = PermissionScopes.candidates(for: ask("webfetch", ["https://example.com"])) { _ in nil }
        #expect(fetch.isEmpty)
    }

    @Test("Wildcards match the way OpenCode documents them")
    func wildcards() {
        #expect(PermissionScopes.matches(pattern: "/a/b/**", "/a/b/c/d.ts"))
        #expect(PermissionScopes.matches(pattern: "/a/b/*", "/a/b/c/d.ts"))
        #expect(!PermissionScopes.matches(pattern: "/a/b/*", "/a/c/d.ts"))
        #expect(PermissionScopes.matches(pattern: "git *", "git status"))
        #expect(!PermissionScopes.matches(pattern: "git *", "git"))
        #expect(PermissionScopes.matches(pattern: "file?.ts", "file1.ts"))
        #expect(!PermissionScopes.matches(pattern: "file?.ts", "file10.ts"))
        #expect(!PermissionScopes.matches(pattern: "a.b", "axb"))
    }

    @Test("The project root is the nearest ancestor with a .git")
    func projectRoot() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("grant-\(UUID().uuidString)")
        let repo = base.appendingPathComponent("repo")
        let deep = repo.appendingPathComponent("src/lib")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(PermissionScopes.projectRoot(containing: deep.path) == repo.path)
        #expect(PermissionScopes.projectRoot(containing: repo.path) == repo.path)
        #expect(PermissionScopes.projectRoot(containing: base.path) == nil)
    }

    @Test("Adding a rule keeps the user's shorthand as the wildcard entry")
    func configMerge() {
        let root: [String: Any] = ["permission": ["bash": "allow", "edit": ["*": "ask"]], "model": "x"]
        let out = PermissionConfig.allowing(["/p/**"], for: "external_directory", in: root)
        let permission = out["permission"] as? [String: Any]
        #expect(permission?["bash"] as? String == "allow")
        #expect((permission?["external_directory"] as? [String: String]) == ["/p/**": "allow"])
        #expect(out["model"] as? String == "x")

        let shorthand = PermissionConfig.allowing(["git *"], for: "bash", in: ["permission": "ask"])
        let block = shorthand["permission"] as? [String: Any]
        #expect(block?["*"] as? String == "ask")
        #expect((block?["bash"] as? [String: String]) == ["git *": "allow"])

        let widened = PermissionConfig.allowing(["git *"], for: "bash", in: root)
        #expect(((widened["permission"] as? [String: Any])?["bash"] as? [String: String])
            == ["*": "allow", "git *": "allow"])
        let twice = PermissionConfig.allowing(["git *"], for: "bash", in: widened)
        #expect(NSDictionary(dictionary: twice) == NSDictionary(dictionary: widened))
    }
}
