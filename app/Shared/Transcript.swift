import RemoteKit
import SwiftUI

/// The conversation: parts, the turn's diffs, any error, and the working
/// indicator pinned to the bottom while the agent runs.
///
/// No divider lines anywhere. Structure comes from the spacing ladder —
/// the gap between turns is more than 3× the gap between parts of one
/// turn, and that ratio is the only thing telling a reader where a turn
/// ended. See docs/design-spec.md.
struct Transcript: View {
    let rows: [TurnPart]
    let diffs: [FileDiff]
    let error: String?
    let running: Bool
    let activity: String
    var turnStartedAt: Date = .init()
    var todos: [TodoItem] = []
    /// The session's context occupancy, when the Mac has reported it.
    var usage: TurnUsage?
    /// History is on its way. While it lands the view stays pinned to
    /// the bottom without animating there, so the reader opens on the
    /// newest turn and older ones fill in above, unseen.
    var loading: Bool = false

    private static let indicatorID = "working"
    @ScaledMetric(relativeTo: .body) private var betweenParts: CGFloat = 12
    @ScaledMetric(relativeTo: .body) private var betweenTurns: CGFloat = 40
    @ScaledMetric(relativeTo: .body) private var gutter: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var userInset: CGFloat = 48

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, part in
                        row(at: index, part: part)
                    }
                    // The agent's own plan, above the diff: what it set
                    // out to do, then what it actually changed.
                    if !todos.isEmpty {
                        TodoList(todos: todos)
                            .padding(.top, betweenParts)
                    }
                    if !diffs.isEmpty {
                        ChangeSummary(diffs: diffs)
                            .padding(.top, betweenParts)
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(Color.inkMuted)
                            .padding(.top, betweenParts)
                    }
                    if loading, rows.isEmpty {
                        // The only blank transcript that means "wait":
                        // small and muted, gone the moment the tail lands.
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading conversation")
                                .font(.callout)
                                .foregroundStyle(Color.inkMuted)
                        }
                        .padding(.top, betweenParts)
                    }
                    if running {
                        HStack(spacing: 8) {
                            WorkingIndicator(activity: activity, since: turnStartedAt)
                            Spacer(minLength: 8)
                            if let usage { UsageBadge(usage: usage) }
                        }
                        .id(Self.indicatorID)
                        .padding(.top, betweenParts)
                    } else if let usage, !rows.isEmpty {
                        // The settled reading, kept where the indicator
                        // was: how full the window is going into the next
                        // turn.
                        UsageBadge(usage: usage)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.top, betweenParts)
                    }
                }
                .padding(.horizontal, gutter)
                .padding(.vertical, betweenParts)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Open on the newest turn, not the oldest: the anchor puts
            // the first layout at the bottom and keeps it there while a
            // loading transcript grows upward, and it leaves a reader who
            // has scrolled up where they are when the tail grows.
            .defaultScrollAnchor(.bottom)
            .background(Color.canvas)
            .onChange(of: rows.count) { scroll(proxy) }
            .onChange(of: running) { scroll(proxy) }
        }
    }

    @ViewBuilder
    private func row(at index: Int, part: TurnPart) -> some View {
        let previous = index > 0 ? rows[index - 1] : nil
        // A turn begins at the user's message, and again at the agent's
        // first part after it.
        let startsTurn = index > 0 && (part.type == "user" || previous?.type == "user")

        Group {
            if part.type == "user" {
                Text(part.text ?? "")
                    .textSelection(.enabled)
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.block, style: .continuous)
                            .fill(Color.surfaceRaised)
                    )
                    // Inset from the leading edge, not centred: the
                    // asymmetry separates the two voices without giving the
                    // agent a bubble. Bubbles on both sides read as a
                    // messenger app and undermine the tool framing.
                    .padding(.leading, userInset)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else if part.type == "reasoning" {
                ReasoningBlock(
                    text: part.text ?? "",
                    // Live only while it is the newest thing and the turn
                    // is still going.
                    isActive: running && index == rows.count - 1
                )
            } else {
                PartRow(part: part)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .id(index)
        .padding(.top, index == 0 ? 0 : (startsTurn ? betweenTurns : betweenParts))
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        // Animating is for a turn arriving live. History landing in
        // batches must not be seen to move: each batch pins the bottom
        // in the same frame it lays out.
        var transaction = Transaction(animation: loading ? nil : Motion.easeOut(0.2))
        transaction.disablesAnimations = loading
        withTransaction(transaction) {
            if running {
                proxy.scrollTo(Self.indicatorID, anchor: .bottom)
            } else if !rows.isEmpty {
                proxy.scrollTo(rows.count - 1, anchor: .bottom)
            }
        }
    }
}

/// What the turn changed. A tinted block rather than a ruled section —
/// the same job a `Section` header did, done with surface instead of lines.
struct ChangeSummary: View {
    let diffs: [FileDiff]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Changes")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.inkMuted)
            ForEach(diffs, id: \.file) { diff in
                HStack(spacing: 8) {
                    Text(diff.file)
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text("+\(diff.additions ?? 0)")
                        .foregroundStyle(Color.positive)
                    Text("−\(diff.deletions ?? 0)")
                        .foregroundStyle(Color.negative)
                }
                .font(.caption.monospacedDigit())
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.block, style: .continuous)
                .fill(Color.surface)
        )
    }
}

struct PartRow: View {
    let part: TurnPart

    var body: some View {
        switch part.type {
        case "text":
            MarkdownText(text: part.text ?? "")
                .foregroundStyle(Color.ink)
        case "tool":
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    // A write/edit names its file — "edit · Transcript.swift"
                    // says what's happening; "edit" alone says almost nothing.
                    Text(toolTitle)
                } icon: {
                    switch part.status {
                    case "completed": Image(systemName: "checkmark.circle")
                    case "error": Image(systemName: "xmark.circle")
                    default: ProgressView().controlSize(.small)
                    }
                }
                .font(.callout)
                .foregroundStyle(Color.inkMuted)
                // The code being written, as OpenCode's own TUI previews it.
                // Identity is the part id: an upserted snapshot must update
                // this block in place, not reset its expansion.
                if let preview = part.preview {
                    CodePreview(code: preview, file: part.file)
                        .id(part.id)
                }
            }
        default:
            EmptyView()
        }
    }

    private var toolTitle: String {
        guard let file = part.file?.split(separator: "/").last else {
            return part.tool ?? "tool"
        }
        return "\(part.tool ?? "tool") · \(file)"
    }
}
