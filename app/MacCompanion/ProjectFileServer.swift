import CryptoKit
import Foundation
import RemoteKit

/// The file explorer's three requests, answered from disk. Deliberately not
/// through OpenCode: its file endpoints differ between 1.x and 2.x, return
/// only text, and are down whenever OpenCode is restarting. A paired client
/// can already ask the agent to read anything, so reading files directly
/// widens nothing; every path is still confined to the project it names.
enum ProjectFileServer {
    enum Failure: LocalizedError {
        case notAFolder(String)
        case outside(String)
        case missing(String)
        case aFolder(String)
        case conflict(String)
        case protected(String)

        var errorDescription: String? {
            switch self {
            case let .notAFolder(path): return "\(path) isn't a folder on this Mac."
            case let .outside(path): return "\(path) is outside the project."
            case let .missing(path): return "\(path) doesn't exist on this Mac any more."
            case let .aFolder(path): return "\(path) is a folder, not a file."
            case let .conflict(path):
                return "\(path) changed on this Mac since you opened it, probably by the agent."
            case let .protected(path): return "\(path) is inside .git, which only git should write."
            }
        }
    }

    /// Text past this arrives as its head, marked truncated.
    static let textLimit = 2 << 20
    /// Images and PDFs past this aren't sent at all.
    static let bytesLimit = 25 << 20
    /// Quick open stops counting here; a monorepo with more is rare, and
    /// the index is one frame.
    static let indexLimit = 60_000

    /// Never listed: noise in every project, and `.git` is git's business.
    static let hiddenNames: Set<String> = [".git", ".DS_Store"]

    // MARK: - files

    static func list(root: String, path: String) throws -> (String, [FileEntry]) {
        let (rootURL, relative, url) = try resolve(root: root, path: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw Failure.missing(relative.isEmpty ? root : relative)
        }
        guard isDirectory.boolValue else { throw Failure.notAFolder(relative) }

        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: []
        )
        var entries: [FileEntry] = urls.compactMap { child in
            let name = child.lastPathComponent
            guard !hiddenNames.contains(name) else { return nil }
            let values = try? child.resourceValues(forKeys: Set(keys))
            // A symlinked folder lists as a folder, the way Finder shows it;
            // opening anything through it is still confined to the project.
            var directory = values?.isDirectory ?? false
            if values?.isSymbolicLink == true {
                var target: ObjCBool = false
                directory = FileManager.default.fileExists(atPath: child.path, isDirectory: &target)
                    && target.boolValue
            }
            return FileEntry(
                path: relative.isEmpty ? name : relative + "/" + name,
                name: name,
                directory: directory,
                size: directory ? nil : values?.fileSize
            )
        }

        if let git = GitView(root: rootURL.path) {
            let ignored = git.ignored(entries.map { $0.directory ? $0.path + "/" : $0.path })
            for index in entries.indices {
                let entry = entries[index]
                if ignored.contains(entry.directory ? entry.path + "/" : entry.path) {
                    entries[index].ignored = true
                } else {
                    entries[index].status = git.status(of: entry.path, directory: entry.directory)
                }
            }
        }
        entries.sort(by: FileEntry.ordered)
        return (relative, entries)
    }

    // MARK: - file

    static func read(root: String, path: String) throws -> FileContent {
        let (_, relative, url) = try resolve(root: root, path: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        else { throw Failure.missing(relative) }
        guard !isDirectory.boolValue else { throw Failure.aFolder(relative) }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        if FileKind.sendsBytes(path: relative) {
            guard size <= bytesLimit else { return FileContent(path: relative, size: size) }
            return FileContent(path: relative, size: size, data: try Data(contentsOf: url))
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: textLimit) ?? Data()
        guard let text = decodeText(head, complete: size <= textLimit) else {
            return FileContent(path: relative, size: size)
        }
        let whole = size <= textLimit
        return FileContent(
            path: relative, size: size, text: text, truncated: whole ? nil : true,
            version: whole ? version(of: head) : nil
        )
    }

    // MARK: - file.save

    /// Writes an edited text file back. Refuses when the file's bytes no
    /// longer match `expected` (the agent, or anything else, wrote it since
    /// the edit began) unless `force`. Keeps the file's permissions, so a
    /// script stays executable.
    static func save(
        root: String, path: String, text: String, expected: String?, force: Bool
    ) throws -> FileContent {
        let (_, relative, url) = try resolve(root: root, path: path)
        guard !relative.split(separator: "/").contains(".git") else { throw Failure.protected(relative) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        else { throw Failure.missing(relative) }
        guard !isDirectory.boolValue else { throw Failure.aFolder(relative) }
        if !force, let expected, version(of: try Data(contentsOf: url)) != expected {
            throw Failure.conflict(relative)
        }
        let permissions = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        try Data(text.utf8).write(to: url, options: .atomic)
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
        return try read(root: root, path: relative)
    }

    static func version(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// UTF-8 text, or nil for binary. A NUL in the first few kilobytes is
    /// what git itself takes as binary. A cut-off head may end mid
    /// character, so up to three trailing bytes are allowed to go.
    static func decodeText(_ data: Data, complete: Bool) -> String? {
        if data.prefix(8000).contains(0) { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        guard !complete else { return nil }
        for drop in 1 ... 3 where data.count > drop {
            if let text = String(data: data.dropLast(drop), encoding: .utf8) { return text }
        }
        return nil
    }

    // MARK: - files.index

    static func index(root: String) throws -> (paths: [String], truncated: Bool) {
        let (rootURL, _, _) = try resolve(root: root, path: "")
        if let git = GitView(root: rootURL.path), let tracked = git.files(limit: indexLimit + 1) {
            return (Array(tracked.prefix(indexLimit)), tracked.count > indexLimit)
        }
        return walk(rootURL)
    }

    /// Outside a repository: everything but hidden folders and the
    /// dependency and build folders every ecosystem has.
    private static func walk(_ root: URL) -> (paths: [String], truncated: Bool) {
        let skip: Set<String> = [
            "node_modules", ".build", "build", "dist", "DerivedData", "Pods", "target",
            "vendor", "__pycache__", ".venv", "venv",
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return ([], false) }
        let prefix = root.path.count + 1
        var paths: [String] = []
        for case let url as URL in enumerator {
            if skip.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            paths.append(String(url.path.dropFirst(prefix)))
            if paths.count >= indexLimit { return (paths, true) }
        }
        return (paths, false)
    }

    // MARK: - Confinement

    /// The project root and target, symlinks resolved, with the target
    /// proven to sit inside the root.
    private static func resolve(root: String, path: String) throws -> (URL, String, URL) {
        let rootURL = URL(fileURLWithPath: (root as NSString).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard rootURL.path != "/",
              FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw Failure.notAFolder(root) }
        guard let relative = ProjectPath.relative(path, to: rootURL.path)
            ?? ProjectPath.relative(path, to: root)
        else { throw Failure.outside(path) }
        let target = relative.isEmpty ? rootURL
            : rootURL.appendingPathComponent(relative).resolvingSymlinksInPath()
        guard target.path == rootURL.path || target.path.hasPrefix(rootURL.path + "/") else {
            throw Failure.outside(relative)
        }
        return (rootURL, relative, target)
    }
}

/// What git says about a project folder: per-path status, ignore rules,
/// and the file list. Built per request; a status of a large repository
/// is tens of milliseconds, cheap next to a folder click.
private struct GitView {
    let root: String
    /// The project's path inside the repository ("" at the top), since git
    /// reports status relative to the top.
    let prefix: String
    /// Repository-relative path to status; untracked folders end in "/".
    let statuses: [String: String]

    init?(root: String) {
        // Only where a repository plainly exists: running /usr/bin/git on a
        // Mac without the developer tools opens an install prompt.
        guard Self.insideRepository(root),
              let prefixOut = Self.git(["rev-parse", "--show-prefix"], in: root),
              let statusOut = Self.git(
                  ["status", "--porcelain=v1", "-z", "--untracked-files=normal"], in: root
              )
        else { return nil }
        self.root = root
        prefix = String(decoding: prefixOut, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        statuses = Self.parseStatus(statusOut)
    }

    func status(of path: String, directory: Bool) -> String? {
        let full = prefix + path
        if !directory {
            if let exact = statuses[full] { return exact }
            // Inside an untracked folder, which status reports whole.
            return statuses.first { $0.key.hasSuffix("/") && full.hasPrefix($0.key) }?.value
        }
        if statuses[full + "/"] != nil { return "untracked" }
        return statuses.keys.contains { $0.hasPrefix(full + "/") } ? "modified" : nil
    }

    /// Which of `paths` (project-relative, folders with a trailing slash)
    /// the ignore rules match.
    func ignored(_ paths: [String]) -> Set<String> {
        guard !paths.isEmpty else { return [] }
        let input = Data(paths.joined(separator: "\0").utf8) + Data([0])
        guard let out = Self.git(["check-ignore", "-z", "--stdin"], in: root, input: input, okCodes: [0, 1])
        else { return [] }
        return Set(String(decoding: out, as: UTF8.self).split(separator: "\0").map(String.init))
    }

    /// Tracked files plus untracked ones that aren't ignored: what an
    /// editor's quick open searches.
    func files(limit: Int) -> [String]? {
        guard let out = Self.git(
            ["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--deduplicate"], in: root
        ) else { return nil }
        var paths: [String] = []
        for path in String(decoding: out, as: UTF8.self).split(separator: "\0") {
            paths.append(String(path))
            if paths.count >= limit { break }
        }
        return paths
    }

    static func parseStatus(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        let records = String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard record.count > 3 else { continue }
            let x = record[record.startIndex]
            let y = record[record.index(after: record.startIndex)]
            let path = String(record.dropFirst(3))
            // A rename or copy is followed by its source path.
            if x == "R" || x == "C" { index += 1 }
            let status: String
            switch (x, y) {
            case ("?", "?"): status = "untracked"
            case ("U", _), (_, "U"), ("A", "A"), ("D", "D"): status = "conflicted"
            case ("A", _): status = "added"
            case ("R", _), ("C", _): status = "renamed"
            case ("D", _), (_, "D"): status = "deleted"
            default: status = "modified"
            }
            result[path] = status
        }
        return result
    }

    private static func insideRepository(_ path: String) -> Bool {
        var url = URL(fileURLWithPath: path)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return true
            }
            url.deleteLastPathComponent()
        }
        return false
    }

    private static func git(
        _ arguments: [String], in directory: String, input: Data? = nil, okCodes: Set<Int32> = [0]
    ) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + arguments
        process.environment = ProcessInfo.processInfo.environment
            .merging(["GIT_OPTIONAL_LOCKS": "0"]) { $1 }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let feed = input.map { _ in Pipe() }
        if let feed { process.standardInput = feed }
        do { try process.run() } catch { return nil }
        if let feed, let input {
            // Written off this thread: a large input and a large output
            // would otherwise deadlock on full pipe buffers.
            DispatchQueue.global().async {
                feed.fileHandleForWriting.write(input)
                try? feed.fileHandleForWriting.close()
            }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return okCodes.contains(process.terminationStatus) ? data : nil
    }
}
