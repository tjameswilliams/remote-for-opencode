import RemoteKit
import SwiftUI

/// A subagent's own conversation, opened from its card in the parent's
/// transcript. Read-only: the subagent takes its instructions from the
/// model that started it, so there is no composer, only the work as it
/// happens. Its own subagents open the same way, one level deeper.
///
/// It watches the child session live, and raises the asks waiting on it
/// (its own and its subagents'), because while it's on screen the parent's
/// cards are out of sight.
struct SubagentSessionView: View {
    let route: SubagentRoute

    @StateObject private var turn: TurnController
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    @State private var onTop = true
    #endif

    init(route: SubagentRoute, makeLink: @escaping () -> CompanionLink = { CompanionLink() }) {
        self.route = route
        _turn = StateObject(wrappedValue: TurnController(
            project: route.project, session: route.session, makeLink: makeLink
        ))
    }

    private var agentLabel: String {
        guard let agent = route.agent, !agent.isEmpty else { return "Subagent" }
        return agent.prefix(1).uppercased() + agent.dropFirst() + " subagent"
    }

    var body: some View {
        content
            .background(Color.canvas)
            .task {
                // Same order as the parent's screen: watch, then load, so
                // nothing that lands in between is missed.
                turn.watch()
                await turn.loadTranscript()
            }
    }

    #if os(iOS)
    private var content: some View {
        Transcript(
            rows: turn.rows, diffs: turn.diffs, error: turn.error,
            running: turn.running, activity: turn.activity,
            turnStartedAt: turn.turnStartedAt,
            todos: turn.todos, usage: turn.usage,
            loading: turn.loading,
            project: turn.project
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(route.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(agentLabel)
                        .font(.caption)
                        .foregroundStyle(Color.inkMuted)
                }
            }
        }
        .sheet(item: onTop ? $turn.permission : .constant(nil)) { request in
            PermissionSheet(
                request: request, queued: turn.queuedPermissions, conversation: turn.session
            ) { answer in
                turn.answer(request, with: answer)
            }
        }
        .sheet(item: onTop ? $turn.question : .constant(nil)) { request in
            QuestionSheet(request: request, conversation: turn.session) { answers in
                turn.answer(request, answers: answers)
            }
        }
        .onAppear { onTop = true }
        .onDisappear { onTop = false }
        .onChange(of: scenePhase) {
            turn.active = scenePhase == .active
            if scenePhase == .active {
                // The socket died in the background: watch again and fill
                // the gap from history (upserts dedupe).
                turn.watch()
                Task { await turn.loadTranscript() }
            }
        }
    }
    #else
    private var content: some View {
        VStack(spacing: 0) {
            Transcript(
                rows: turn.rows, diffs: turn.diffs, error: turn.error,
                running: turn.running, activity: turn.activity,
                turnStartedAt: turn.turnStartedAt,
                todos: turn.todos, usage: turn.usage,
                loading: turn.loading,
                project: turn.project
            )
            .frame(maxWidth: 640)
            if let permission = turn.permission {
                PermissionCard(
                    request: permission, queued: turn.queuedPermissions,
                    conversation: turn.session
                ) { answer in
                    turn.answer(permission, with: answer)
                }
                .frame(maxWidth: 640)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            } else if let question = turn.question {
                QuestionCard(request: question, conversation: turn.session) { answers in
                    turn.answer(question, answers: answers)
                }
                .frame(maxWidth: 640)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(route.title)
        .navigationSubtitle(agentLabel)
        .animation(Motion.easeOut(Motion.feedback), value: turn.permission?.id)
        .animation(Motion.easeOut(Motion.feedback), value: turn.question?.id)
    }
    #endif
}
