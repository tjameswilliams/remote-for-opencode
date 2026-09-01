import RemoteKit
import SwiftUI

/// The composer's chips and controls, apart from the composer itself:
/// they are pure SwiftUI and serve the phone's prompt bar and the
/// desktop's alike.

/// The model selector: a chip that opens a menu of what's configured,
/// grouped into a submenu per provider so a long catalogue stays usable.
struct ModelMenu: View {
    @ObservedObject var models: ModelStore

    private var byProvider: [(provider: String, models: [AgentModel])] {
        Dictionary(grouping: models.models, by: \.provider)
            .map { (provider: $0.key, models: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.provider < $1.provider }
    }

    var body: some View {
        Menu {
            if let error = models.error {
                Section(error) {
                    Button {
                        Task { await models.load() }
                    } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                    }
                }
            }
            Button {
                models.selected = nil
            } label: {
                Label(
                    "Mac's default",
                    systemImage: models.selected == nil ? "checkmark" : "desktopcomputer"
                )
            }
            // One flat list when it fits in a menu; providers as submenus
            // when it doesn't. Twelve is about where scrolling starts.
            if models.models.count <= 12 {
                ForEach(models.models) { model in
                    button(for: model)
                }
            } else {
                ForEach(byProvider, id: \.provider) { group in
                    Menu(group.provider) {
                        ForEach(group.models) { model in
                            button(for: model)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if models.loading, models.models.isEmpty {
                    ProgressView().controlSize(.mini)
                }
                Text(models.label).lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .tint(.primary)
        .accessibilityLabel("Model: \(models.label). Tap to change.")
    }

    @ViewBuilder
    private func button(for model: AgentModel) -> some View {
        Button {
            models.selected = model
        } label: {
            if models.selected?.id == model.id {
                Label(model.name, systemImage: "checkmark")
            } else {
                Text(model.name)
            }
        }
    }
}

/// Which agent the turn runs as. Plan mode is the one that matters most —
/// it cannot edit anything, so it is the only mode that is safe by
/// construction rather than by vigilance. Shown tinted when active,
/// because it changes what the whole screen means.
struct AgentMenu: View {
    @ObservedObject var agents: AgentStore

    var body: some View {
        Menu {
            ForEach(agents.agents) { agent in
                Button {
                    agents.selected = agent.name == "build" ? nil : agent
                } label: {
                    let chosen = (agents.selected?.name ?? "build") == agent.name
                    if chosen {
                        Label(agent.name.capitalized, systemImage: "checkmark")
                    } else {
                        Text(agent.name.capitalized)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if agents.isReadOnly {
                    Image(systemName: "eye")
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(agents.label).lineLimit(1)
            }
            .font(.subheadline)
            .foregroundStyle(agents.isReadOnly ? Color.clay : Color.primary)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(
                Capsule().fill(agents.isReadOnly
                    ? Color.clay.opacity(0.15) : Color.primary.opacity(0.08))
            )
        }
        .tint(.primary)
        .accessibilityLabel("Agent: \(agents.label)")
    }
}

/// Which MCP servers' tools this conversation exposes: one switch per
/// server. Only rendered when the user's OpenCode has MCP servers at all,
/// so the composer stays uncluttered for everyone else. Tinted while
/// filtered, because a conversation missing tools it usually has is worth
/// saying out loud.
struct McpMenu: View {
    @ObservedObject var mcp: McpStore

    var body: some View {
        Menu {
            if let error = mcp.error {
                Section(error) {
                    Button {
                        Task { await mcp.load() }
                    } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                    }
                }
            }
            ForEach(mcp.servers) { server in
                Button {
                    mcp.toggle(server)
                } label: {
                    // A configured-but-unreachable server would do nothing
                    // switched on; say so where the switch is.
                    let name = server.connected ? server.name : "\(server.name) (offline)"
                    if server.enabled {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
            if mcp.servers.count > 1 {
                Divider()
                Button("All On") { mcp.setAll(true) }
                Button("All Off") { mcp.setAll(false) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 11, weight: .semibold))
                Text(mcp.label).lineLimit(1)
            }
            .font(.subheadline)
            .foregroundStyle(mcp.filtered ? Color.clay : Color.primary)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(
                Capsule().fill(mcp.filtered
                    ? Color.clay.opacity(0.15) : Color.primary.opacity(0.08))
            )
        }
        .tint(.primary)
        .accessibilityLabel(
            "Tools: \(mcp.enabledCount) of \(mcp.servers.count) MCP servers on. Tap to change."
        )
    }
}

/// A 36pt circular control — comfortably tappable, visually weighted to
/// match the field it sits under.
struct CircleButton: View {
    let systemName: String
    let foreground: Color
    let background: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 36, height: 36)
                .background(Circle().fill(background))
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
    }
}
