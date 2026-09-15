import RemoteKit
import SwiftUI

/// "The agent wants to do X — allow?", as a card in the conversation flow
/// rather than a modal: the desktop has room for the question to sit where
/// it arose, and a blocked turn shouldn't lock the whole window.
///
/// The risk-tier rules are the phone sheet's, verbatim in spirit: the card
/// varies with risk because a `git status` and an `rm -rf` must not look
/// the same, and a high-risk ask offers no blanket grant at all.
struct PermissionCard: View {
    let request: PermissionRequest
    /// Asks waiting behind this one. Said out loud so "always" is chosen
    /// knowing it will cover the rest, and "once" knowing it will not.
    var queued = 0
    /// reply, plus an optional message when the user redirects instead of
    /// simply refusing.
    let reply: (PermissionAnswer) -> Void

    @State private var confirmingAlways = false
    @State private var choosingScope = false
    @State private var scopeID: String?
    @State private var remember = false
    @State private var redirecting = false
    @State private var redirection = ""

    private var risk: PermissionRequest.Risk { request.riskLevel }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            command
            if redirecting { redirectField } else if choosingScope { scopePicker } else { scopeNote }
            actions
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: Radius.block, style: .continuous)
                .fill(Color.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.block, style: .continuous)
                        .stroke(risk == .high ? Color.caution.opacity(0.6) : Color.hairline,
                                lineWidth: risk == .high ? 1.5 : 1)
                )
        )
        .animation(Motion.easeOut(Motion.feedback), value: redirecting)
        .animation(Motion.easeOut(Motion.feedback), value: confirmingAlways)
        .animation(Motion.easeOut(Motion.feedback), value: choosingScope)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: risk == .high ? "exclamationmark.triangle.fill" : "hand.raised.fill")
                .foregroundStyle(risk == .high ? Color.caution : Color.inkMuted)
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.ink)
            Spacer()
            if queued > 0 {
                Text("\(queued) more waiting")
                    .font(.caption)
                    .foregroundStyle(Color.inkMuted)
            }
        }
    }

    private var title: String {
        switch request.permission {
        case "bash": return risk == .high ? "Run a risky command?" : "Run a command?"
        case "edit", "write", "patch": return "Edit files?"
        case "external_directory": return "Reach outside the project?"
        case "webfetch", "websearch": return "Access the network?"
        default: return (request.permission ?? "Permission").capitalized
        }
    }

    /// The thing being asked about, in mono, scrollable horizontally —
    /// a wrapped command hides exactly the tail that makes it dangerous.
    private var command: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text((request.patterns ?? []).joined(separator: "\n"))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(Color.ink)
                .textSelection(.enabled)
                .padding(10)
        }
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Color.canvas)
        )
    }

    @ViewBuilder
    private var scopeNote: some View {
        if let always = request.always, !always.isEmpty {
            Text("“Always” allows \(always.joined(separator: ", ")) for the rest of this session.")
                .font(.footnote)
                .foregroundStyle(Color.inkMuted)
        }
    }

    private var redirectField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What should it do instead?")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.inkMuted)
            TextField("Optional — leave blank to just say no", text: $redirection, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2 ... 5)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(Color.canvas)
                )
        }
    }

    @ViewBuilder
    private var actions: some View {
        if redirecting {
            HStack(spacing: 8) {
                Button("Reject") { reply(PermissionAnswer(reply: "reject", message: redirection.isEmpty ? nil : redirection)) }
                    .buttonStyle(CardButton(tint: .negative, filled: true))
                Button("Back") { redirecting = false }
                    .buttonStyle(CardButton())
                Spacer()
            }
        } else if choosingScope {
            HStack(spacing: 8) {
                Button(remember ? "Allow and Remember" : "Allow") { grantSelected() }
                    .buttonStyle(CardButton(tint: .clay, filled: true))
                    .disabled(selectedScope == nil)
                Button("Back") { choosingScope = false }
                    .buttonStyle(CardButton())
                Spacer()
            }
        } else if confirmingAlways {
            VStack(alignment: .leading, spacing: 8) {
                Text("Allow every \(request.permission ?? "action") like this until OpenCode restarts?")
                    .font(.footnote)
                    .foregroundStyle(Color.inkMuted)
                HStack(spacing: 8) {
                    Button("Yes, allow always") { reply(PermissionAnswer(reply: "always")) }
                        .buttonStyle(CardButton(tint: .clay, filled: true))
                    Button("Back") { confirmingAlways = false }
                        .buttonStyle(CardButton())
                    Spacer()
                }
            }
        } else {
            HStack(spacing: 8) {
                Button("Allow Once") { reply(PermissionAnswer(reply: "once")) }
                    .buttonStyle(CardButton(tint: .clay, filled: true))
                // Granting more than once is always a click, never a
                // keyboard shortcut. Scopes exist only for asks that are
                // safe to widen; without them (an older companion, or a
                // risky ask) OpenCode's own "always" is the sole offer,
                // and not for high risk at all.
                if let scopes = request.scopes, !scopes.isEmpty {
                    Button("Allow…") {
                        scopeID = scopes.first?.id
                        choosingScope = true
                    }
                    .buttonStyle(CardButton())
                } else if risk != .high {
                    Button("Always") { confirmingAlways = true }
                        .buttonStyle(CardButton())
                }
                Spacer()
                // Reject sits apart from Allow on purpose: adjacent targets
                // for consequential opposites is a known hazard.
                Button("Reject…") { redirecting = true }
                    .buttonStyle(CardButton())
            }
        }
    }

    // MARK: - Scope

    private var selectedScope: PermissionScope? {
        request.scopes?.first { $0.id == scopeID }
    }

    private func grantSelected() {
        guard let scope = selectedScope else { return }
        reply(PermissionAnswer(
            reply: "always",
            grant: PermissionGrant(
                permission: request.permission ?? "", patterns: scope.patterns, persist: remember
            )
        ))
    }

    /// Which grant, and for how long. Narrowest first and preselected:
    /// widening is a deliberate click, never the default.
    private var scopePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Allow, and stop asking for")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.inkMuted)
            ForEach(request.scopes ?? []) { scope in
                Button { scopeID = scope.id } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: scopeID == scope.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(scopeID == scope.id ? Color.clay : Color.inkMuted)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(scope.label)
                                .font(.callout)
                                .foregroundStyle(Color.ink)
                            Text(scope.patterns.joined(separator: "\n"))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Color.inkMuted)
                                .lineLimit(2)
                                .truncationMode(.head)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .fill(Color.canvas)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Toggle("Remember on this Mac", isOn: $remember)
                .font(.callout)
            Text(remember
                ? "Saved to this project's opencode.json, for every conversation. This conversation has it now; the rest after OpenCode next restarts."
                : "This conversation only, until OpenCode restarts.")
                .font(.footnote)
                .foregroundStyle(Color.inkMuted)
        }
    }
}

/// The card's compact button, filled for the primary verb, outlined
/// otherwise — the phone sheet's pair at desktop control size.
struct CardButton: ButtonStyle {
    var tint: Color = .ink
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(filled ? .semibold : .regular))
            .foregroundStyle(filled ? Color.white : Color.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(filled ? tint.opacity(configuration.isPressed ? 0.75 : 1)
                                 : configuration.isPressed ? Color.surfaceRaised : .clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .stroke(filled ? .clear : Color.hairline, lineWidth: 1)
                    )
            )
    }
}
