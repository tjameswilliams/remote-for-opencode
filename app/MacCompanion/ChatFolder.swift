import Foundation
import OSLog
import RemoteKit

/// The folder behind "New Chat": a directory the companion owns, for
/// conversations that belong to no project. OpenCode has no session
/// without a working directory; what it has is a synthetic `global`
/// project that every non-repo directory maps to, which is exactly what
/// running the CLI from a scratch folder does (verified on 1.18.15).
/// Pointing chats at a folder of our own, rather than home or `/`, keeps
/// the agent's file listing, grep, and anything it writes somewhere
/// harmless, and keeps a "this folder" permission grant scoped to it.
enum ChatFolder {
    private static let logger = Logger(
        subsystem: "com.timwilliams.opencodego", category: "chats"
    )

    /// `~/Library/Application Support/Remote for OpenCode/Chats`. Under
    /// the product name rather than the pre-rename bundle slug the pidfile
    /// keeps: this path is user-visible (the TUI shows a session's
    /// directory), the pidfile's is not.
    static let path: String = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    )[0].appendingPathComponent("Remote for OpenCode/Chats").path

    /// The project row every client pins first. The folder is created
    /// here, on the way into the list, so the first prompt never lands in
    /// a directory that isn't there.
    static func project() -> Project {
        do {
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true
            )
        } catch {
            logger.error("could not create the chat folder: \(error.localizedDescription, privacy: .public)")
        }
        return Project(id: "chats", worktree: path, name: "Chats", known: true, scratch: true)
    }
}
