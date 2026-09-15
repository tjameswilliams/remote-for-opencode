import RemoteKit
import SwiftUI

/// The workspace's center: one conversation, on the shared TurnController.
/// The transcript reads in a capped column (640pt — Tomte's validated
/// desktop reading measure); blocking asks render as inline cards in the
/// flow rather than modals, so the window stays yours while the agent
/// waits.
struct WorkspaceSessionView: View {
    @ObservedObject var state: WorkspaceState
    let title: String

    @StateObject private var turn: TurnController
    /// Per conversation, unlike the window's stores: which MCP servers
    /// this thread exposes is the thread's own property.
    @StateObject private var mcp: McpStore
    @State private var input = ""
    @StateObject private var attachments = PromptAttachments()
    /// What the inspector's badge and the Dock count: asks waiting on you.
    private var pending: Int {
        (turn.permission == nil ? 0 : 1) + (turn.question == nil ? 0 : 1)
    }

    init(state: WorkspaceState, project: String, session: String?, title: String) {
        self.state = state
        self.title = title
        _turn = StateObject(wrappedValue: TurnController(
            project: project, session: session, makeLink: state.makeLink
        ))
        _mcp = StateObject(wrappedValue: McpStore(
            project: project, session: session, makeLink: state.makeLink
        ))
    }

    /// Commands to offer right now, or nil when the user isn't typing one.
    private var paletteMatches: [AgentCommand]? {
        guard let query = SlashInput.query(input) else { return nil }
        return state.commands.matching(query)
    }

    /// The cards that block a turn, split out of `body` because the
    /// compiler gave up type-checking the whole thing in one expression.
    @ViewBuilder
    private var approvals: some View {
        if let permission = turn.permission {
            PermissionCard(request: permission, queued: turn.queuedPermissions) { answer in
                turn.answer(permission, with: answer)
            }
            .frame(maxWidth: 640)
            .padding(.vertical, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        if let question = turn.question {
            QuestionCard(request: question) { answers in
                turn.answer(question, answers: answers)
            }
            .frame(maxWidth: 640)
            .padding(.vertical, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Leave a trailing space when the command wants arguments, so the
    /// caret is where typing continues.
    private func complete(_ command: AgentCommand) {
        input = "/\(command.name)" + (command.takesArguments ? " " : "")
    }

    var body: some View {
        VStack(spacing: 0) {
            Transcript(
                rows: turn.rows, diffs: turn.diffs, error: turn.error,
                running: turn.running, activity: turn.activity,
                turnStartedAt: turn.turnStartedAt,
                todos: turn.todos, usage: turn.usage,
                loading: turn.loading
            )
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)

            approvals

            if let matches = paletteMatches {
                CommandPalette(commands: matches, pick: complete)
                    .frame(maxWidth: 640)
            }
            DesktopComposer(
                input: $input,
                running: turn.running,
                attachments: attachments,
                models: state.models,
                agents: state.agents,
                mcp: mcp,
                onSend: send,
                onAbort: { turn.abort() }
            )
            .frame(maxWidth: 640)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas)
        .navigationTitle(title)
        .inspector(isPresented: $state.inspectorShown) {
            InspectorPane(state: state, turn: turn, tab: $state.inspectorTab)
                .inspectorColumnWidth(min: 300, ideal: 380, max: 760)
        }
        .toolbar {
            ToolbarItem {
                // Always visible, unlike the transcript's copy, which
                // scrolls: the context meter is what you glance at before
                // deciding to /summarize.
                if let usage = turn.usage {
                    UsageBadge(usage: usage)
                }
            }
            ToolbarItem {
                if turn.running {
                    // The transcript's working indicator anchors autoscroll;
                    // this is its always-visible echo for when you've
                    // scrolled away.
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(turn.activity)
                            .font(.caption)
                            .foregroundStyle(Color.inkMuted)
                    }
                }
            }
            ToolbarItem {
                Button {
                    state.inspectorShown.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                        .overlay(alignment: .topTrailing) {
                            if pending > 0 {
                                Circle()
                                    .fill(Color.caution)
                                    .frame(width: 7, height: 7)
                                    .offset(x: 3, y: -3)
                            }
                        }
                }
                .accessibilityLabel("Toggle inspector")
            }
        }
        .onChange(of: pending) {
            // The Dock badge is the "it needs you" signal when the window
            // is buried; approvals are foreground-only on the desktop.
            NSApp.dockTile.badgeLabel = pending > 0 ? String(pending) : nil
        }
        .onDisappear { NSApp.dockTile.badgeLabel = nil }
        .onChange(of: attachments.error) {
            if let message = attachments.error { turn.error = message }
        }
        .animation(Motion.easeOut(Motion.feedback), value: turn.permission?.id)
        .animation(Motion.easeOut(Motion.feedback), value: turn.question?.id)
        .animation(.easeOut(duration: 0.15), value: paletteMatches?.count)
        .onReceive(NotificationCenter.default.publisher(for: WorkspaceCommand.approveOnce)) { _ in
            if let permission = turn.permission {
                turn.answer(permission, with: PermissionAnswer(reply: "once"))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: WorkspaceCommand.reject)) { _ in
            if let permission = turn.permission {
                turn.answer(permission, with: PermissionAnswer(reply: "reject"))
            }
        }
        .onChange(of: state.pendingCommand?.name) {
            guard let command = state.pendingCommand else { return }
            state.pendingCommand = nil
            input = "/\(command.name)" + (command.takesArguments ? " " : "")
        }
        .onChange(of: turn.session) {
            // A conversation started from a project row now has a session:
            // put it in the sidebar as the selected row, and start the
            // watch the cold path skipped because there was nothing to
            // watch yet.
            guard let id = turn.session, case let .project(project) = state.selection else { return }
            state.adopt(session: id, in: project)
            turn.watch()
        }
        .onChange(of: turn.title) {
            if let id = turn.session, let title = turn.title {
                state.retitle(session: id, to: title)
            }
        }
        .onChange(of: turn.running) {
            // A finished turn moved this conversation to the top of its
            // project on the Mac; the sidebar should agree without a ⌘R.
            guard !turn.running, turn.session != nil else { return }
            Task { await state.loadSessions() }
        }
        .task {
            // Watch first, then load: anything that lands between the two
            // arrives through both and dedupes by part id, where the other
            // order would leave a gap. The watch is what makes a turn
            // driven from the OpenCode TUI show up here live.
            turn.watch()
            await turn.loadTranscript()
        }
        .task { await mcp.loadIfNeeded() }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        input = ""
        turn.send(
            text,
            attachments: attachments,
            model: state.models.selected,
            agent: state.agents.selected?.name,
            knownCommands: state.commands.commands,
            mcp: mcp.wireMap
        )
    }
}
