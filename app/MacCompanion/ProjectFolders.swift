import Foundation
import OSLog

/// Folders the user has pinned as project sources by hand: the escape
/// hatch for anything RepoDiscovery's fixed roots will never find (a repo
/// on an external drive, a folder that isn't a git repo yet). Paths only,
/// persisted in defaults; the projects listing merges them in alongside
/// OpenCode's history and the discovered repos.
enum ProjectFolders {
    private static let key = "projectFolders"
    private static let logger = Logger(
        subsystem: "com.timwilliams.opencodego", category: "folders"
    )

    static func all() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    enum FolderError: LocalizedError {
        case missing(String)
        case notAFolder(String)

        var errorDescription: String? {
            switch self {
            case let .missing(path):
                return "There's no folder at \(path) on this Mac."
            case let .notAFolder(path):
                return "\(path) is a file, not a folder."
            }
        }
    }

    /// Validate and persist one folder. The path may arrive with a tilde or
    /// trailing slash (it is typed on a phone as often as picked in a
    /// panel); what's stored is the standardized absolute path. Adding a
    /// path twice is a no-op, not an error.
    @discardableResult
    static func add(_ raw: String) throws -> String {
        let path = (raw.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
            .expandingTildeInPath
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized, isDirectory: &isDirectory)
        else { throw FolderError.missing(standardized) }
        guard isDirectory.boolValue else { throw FolderError.notAFolder(standardized) }
        var folders = all()
        if !folders.contains(standardized) {
            folders.append(standardized)
            UserDefaults.standard.set(folders, forKey: key)
            logger.notice("added project folder \(standardized, privacy: .public)")
        }
        return standardized
    }

    static func remove(_ path: String) {
        let folders = all().filter { $0 != path }
        UserDefaults.standard.set(folders, forKey: key)
        logger.notice("removed project folder \(path, privacy: .public)")
    }
}
