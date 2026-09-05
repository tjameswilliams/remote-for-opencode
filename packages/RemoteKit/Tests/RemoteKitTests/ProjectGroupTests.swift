import Foundation
import Testing

@testable import RemoteKit

/// The launcher's grouped list is a join the protocol never states
/// outright: sessions attach to projects by directory path. Getting it
/// wrong strands conversations where the user can't see them, so the join,
/// the orphan handling, and the ordering each get pinned down here.
@Suite("Project grouping")
struct ProjectGroupTests {
    private let app = Project(id: "p1", worktree: "/Users/t/app", updated: date(daysAgo: 3))
    private let site = Project(id: "p2", worktree: "/Users/t/site", updated: date(daysAgo: 1))
    private let idle = Project(id: "p3", worktree: "/Users/t/idle", updated: date(daysAgo: 9))

    private static func date(daysAgo: Int) -> Date {
        Date(timeIntervalSinceReferenceDate: 1_000_000).addingTimeInterval(-Double(daysAgo) * 86_400)
    }

    private func date(daysAgo: Int) -> Date { Self.date(daysAgo: daysAgo) }

    @Test("Sessions attach to their project, in the order they arrived")
    func join() {
        let sessions = [
            Session(id: "s1", title: "Fix login", directory: "/Users/t/app", updated: date(daysAgo: 0)),
            Session(id: "s2", title: "New landing", directory: "/Users/t/site", updated: date(daysAgo: 1)),
            Session(id: "s3", title: "Fix logout", directory: "/Users/t/app", updated: date(daysAgo: 2)),
        ]
        let groups = ProjectGrouping.groups(projects: [app, site, idle], sessions: sessions)
        #expect(groups.map(\.project.id) == ["p1", "p2", "p3"])
        #expect(groups[0].sessions.map(\.id) == ["s1", "s3"])
        #expect(groups[1].sessions.map(\.id) == ["s2"])
        #expect(groups[2].sessions.isEmpty)
    }

    @Test("Active projects float above sessionless ones, freshest first")
    func ordering() {
        let sessions = [
            Session(id: "s1", directory: "/Users/t/site", updated: date(daysAgo: 0)),
            Session(id: "s2", directory: "/Users/t/app", updated: date(daysAgo: 5)),
        ]
        let groups = ProjectGrouping.groups(projects: [app, site, idle], sessions: sessions)
        #expect(groups.map(\.project.id) == ["p2", "p1", "p3"])
    }

    @Test("Sessionless projects keep the server's order")
    func idleOrder() {
        let groups = ProjectGrouping.groups(projects: [idle, app, site], sessions: [])
        #expect(groups.map(\.project.id) == ["p3", "p1", "p2"])
    }

    @Test("A session whose project isn't listed gets a stand-in group")
    func orphanDirectory() {
        let sessions = [Session(id: "s1", directory: "/Users/t/archived", updated: date(daysAgo: 0))]
        let groups = ProjectGrouping.groups(projects: [app], sessions: sessions)
        let orphan = groups.first { $0.synthesized }
        #expect(orphan?.project.displayName == "archived")
        #expect(orphan?.project.worktree == "/Users/t/archived")
        #expect(orphan?.sessions.map(\.id) == ["s1"])
    }

    @Test("Sessions with no directory land in an Elsewhere group")
    func orphanNoDirectory() {
        let sessions = [Session(id: "s1", updated: date(daysAgo: 0))]
        let groups = ProjectGrouping.groups(projects: [app], sessions: sessions)
        let orphan = groups.first { $0.synthesized }
        #expect(orphan?.project.displayName == "Elsewhere")
        #expect(orphan?.project.worktree.isEmpty == true)
    }

    @Test("Search keeps name matches and session matches, drops the rest")
    func search() {
        // The server already filtered sessions to the query; only the
        // matching one is in hand.
        let sessions = [Session(id: "s1", title: "Fix login", directory: "/Users/t/idle")]
        let groups = ProjectGrouping.groups(
            projects: [app, site, idle], sessions: sessions, search: "app"
        )
        // "app" matches p1 by name, and p3 by having a matching session.
        #expect(groups.map(\.project.id) == ["p3", "p1"])
        #expect(groups[0].sessions.map(\.id) == ["s1"])
        #expect(groups[1].sessions.isEmpty)
    }

    @Test("Search matching is case-insensitive")
    func searchCase() {
        let groups = ProjectGrouping.groups(projects: [app], sessions: [], search: "APP")
        #expect(groups.map(\.project.id) == ["p1"])
    }
}
