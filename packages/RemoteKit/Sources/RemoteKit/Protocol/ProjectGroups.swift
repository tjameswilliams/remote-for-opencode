import Foundation

/// One launcher row group: a project and the sessions that live in it.
/// Sessions join projects on `Session.directory == Project.worktree`; that
/// path is the only link the protocol carries, there is no project id on a
/// session.
public struct ProjectGroup: Hashable, Identifiable, Sendable {
    public var project: Project
    /// The project's sessions, most recent first (the server's order).
    public var sessions: [Session]
    /// True when no project in the list claimed these sessions and the
    /// group was synthesized from their shared directory. Its `project` is
    /// a stand-in: good for starting a session in that directory, not a
    /// folder a client should offer to remove.
    public var synthesized: Bool

    public var id: String { project.id }

    public init(project: Project, sessions: [Session], synthesized: Bool = false) {
        self.project = project
        self.sessions = sessions
        self.synthesized = synthesized
    }

    /// When something last happened here. Groups with sessions but no
    /// timestamps still rank above sessionless projects.
    var latestActivity: Date? {
        sessions.compactMap(\.updated).max() ?? (sessions.isEmpty ? nil : .distantPast)
    }
}

/// Builds the grouped launcher list both clients render: every project,
/// with its conversations nested underneath, instead of two disjoint lists
/// the user has to cross-reference by eye.
public enum ProjectGrouping {
    /// `sessions` is expected to be the server-filtered result when
    /// `search` is set (the session list can be thousands long, so title
    /// matching happens on the Mac). Projects are few and already in hand,
    /// so their names are matched here, client-side.
    public static func groups(
        projects: [Project], sessions: [Session], search: String = ""
    ) -> [ProjectGroup] {
        var buckets: [String: [Session]] = [:]
        var orphanOrder: [String] = []
        for session in sessions {
            let key = session.directory ?? ""
            if buckets[key] == nil { orphanOrder.append(key) }
            buckets[key, default: []].append(session)
        }

        var result: [ProjectGroup] = []
        for project in projects {
            let owned = buckets.removeValue(forKey: project.worktree) ?? []
            result.append(ProjectGroup(project: project, sessions: owned))
        }

        // A session can outlive its project entry (the projects call merges
        // and filters on the Mac), and a future Mac may omit `directory`
        // entirely. Neither is a reason to hide a conversation.
        for key in orphanOrder {
            guard let orphans = buckets.removeValue(forKey: key) else { continue }
            let standIn = Project(
                id: key.isEmpty ? "sessions-elsewhere" : key,
                worktree: key,
                name: key.isEmpty ? "Elsewhere" : nil
            )
            result.append(ProjectGroup(project: standIn, sessions: orphans, synthesized: true))
        }

        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            result = result.filter { group in
                !group.sessions.isEmpty
                    || group.project.displayName.lowercased().contains(query)
            }
        }

        // Recent activity floats up; sessionless projects keep the server's
        // order (already recency-merged) below the active ones.
        return result.enumerated()
            .sorted { a, b in
                switch (a.element.latestActivity, b.element.latestActivity) {
                case let (left?, right?) where left != right: return left > right
                case (.some, .none): return true
                case (.none, .some): return false
                default: return a.offset < b.offset
                }
            }
            .map(\.element)
    }
}
