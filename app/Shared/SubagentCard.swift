import RemoteKit
import SwiftUI

/// Where a subagent card leads: the child session a subagent runs in,
/// opened read-only on top of the conversation that started it.
struct SubagentRoute: Hashable {
    let session: String
    /// The parent's project directory. A subagent runs where its parent
    /// does, and the Mac needs the directory to read the child's history.
    let project: String
    let title: String
    let agent: String?
}

/// A subagent in the transcript: which agent, what it was asked to do,
/// and whether it's still at it. Tapping it opens the subagent's own
/// conversation, the way OpenCode's TUI and web app do.
///
/// Before the Mac has reported the child session (an older companion, or
/// the first moments of the call) the card is the same, minus the link.
struct SubagentCard: View {
    let part: TurnPart
    /// The conversation's project directory; nil leaves the card inert.
    var project: String?

    private var ref: SubagentRef? { part.subagent }

    private var route: SubagentRoute? {
        guard let session = ref?.session, let project else { return nil }
        return SubagentRoute(
            session: session, project: project,
            title: ref?.description ?? "Subagent", agent: ref?.agent
        )
    }

    private var agentName: String {
        guard let agent = ref?.agent, !agent.isEmpty else { return "Subagent" }
        return agent.prefix(1).uppercased() + agent.dropFirst() + " subagent"
    }

    private var working: Bool {
        part.status == "pending" || part.status == "running" || ref?.background == true
    }

    var body: some View {
        if let route {
            NavigationLink(value: route) { card(linked: true) }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the subagent's conversation")
        } else {
            card(linked: false)
        }
    }

    private func card(linked: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                if working {
                    ProgressView().controlSize(.small)
                } else if part.status == "error" {
                    Image(systemName: "xmark.circle")
                } else {
                    Image(systemName: "checkmark.circle")
                }
            }
            .foregroundStyle(Color.inkMuted)
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agentName)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.ink)
                    if ref?.background == true {
                        Text("Background")
                            .font(.caption2)
                            .foregroundStyle(Color.inkMuted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                }
                if let description = ref?.description, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(Color.inkMuted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if linked {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.inkFaint)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.block, style: .continuous)
                .fill(Color.surface)
        )
        .contentShape(RoundedRectangle(cornerRadius: Radius.block, style: .continuous))
    }
}

/// An ask's session differs from the conversation on screen: one of the
/// conversation's subagents is the one waiting. The Mac only relays asks
/// from the conversation's own family, so "different" means "subagent".
func isSubagentAsk(_ askSession: String?, in conversation: String?) -> Bool {
    guard let askSession, let conversation else { return false }
    return askSession != conversation
}

/// The line under an ask's title when a subagent raised it.
struct SubagentAskNote: View {
    var body: some View {
        Label("Asked by a subagent", systemImage: "arrow.turn.down.right")
            .font(.caption)
            .foregroundStyle(Color.inkMuted)
    }
}
