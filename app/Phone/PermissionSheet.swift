import RemoteKit
import SwiftUI

/// "The agent wants to do X — allow?"
///
/// A sheet rather than an alert, deliberately: Apple's HIG puts choices
/// related to an intentional action on an action sheet, and this one
/// carries content the user has to read — the exact command, its scope,
/// what "always" would grant. Every shipped agent tool converged here.
///
/// **The card varies with risk.** Anthropic reports users approve 93% of
/// permission prompts; a card that looks identical every time is
/// optimising for that habituation, and varying presentation by risk is
/// the empirically supported counter. A `git status` and an `rm -rf` must
/// not look the same.
struct PermissionSheet: View {
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
    @Environment(\.dynamicTypeSize) private var typeSize

    private var risk: PermissionRequest.Risk { request.riskLevel }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    command
                    if redirecting { redirectField } else if choosingScope { scopePicker } else { scopeNote }
                }
                .padding(20)
            }
            .background(Color.canvas)
            .safeAreaInset(edge: .bottom) { actions }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.canvas)
        .interactiveDismissDisabled()
    }

    // MARK: - Content

    private var header: some View {
        HStack(spacing: 10) {
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
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(Color.ink)
                .textSelection(.enabled)
                .padding(14)
        }
        .background(
            RoundedRectangle(cornerRadius: Radius.block, style: .continuous)
                .fill(Color.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.block, style: .continuous)
                        .stroke(risk == .high ? Color.caution.opacity(0.5) : Color.hairline,
                                lineWidth: risk == .high ? 1.5 : 1)
                )
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
        VStack(alignment: .leading, spacing: 8) {
            Text("What should it do instead?")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.inkMuted)
            TextField("Optional — leave blank to just say no", text: $redirection, axis: .vertical)
                .lineLimit(2 ... 5)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(Color.surface)
                )
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 10) {
            if redirecting {
                Button("Reject") { reply(PermissionAnswer(reply: "reject", message: redirection.isEmpty ? nil : redirection)) }
                    .buttonStyle(Primary(tint: .negative))
                Button("Back") { redirecting = false }
                    .buttonStyle(Secondary())
            } else if choosingScope {
                Button(remember ? "Allow and Remember" : "Allow") { grantSelected() }
                    .buttonStyle(Primary(tint: .clay))
                    .disabled(selectedScope == nil)
                Button("Back") { choosingScope = false }
                    .buttonStyle(Secondary())
            } else if confirmingAlways {
                Text("Allow every \(request.permission ?? "action") like this until OpenCode restarts?")
                    .font(.footnote)
                    .foregroundStyle(Color.inkMuted)
                    .multilineTextAlignment(.center)
                Button("Yes, allow always") { reply(PermissionAnswer(reply: "always")) }
                    .buttonStyle(Primary(tint: .clay))
                Button("Back") { confirmingAlways = false }
                    .buttonStyle(Secondary())
            } else {
                Button("Allow Once") { reply(PermissionAnswer(reply: "once")) }
                    .buttonStyle(Primary(tint: .clay))
                // Reject sits apart from Allow on purpose: adjacent 44pt
                // targets for consequential opposites is a known hazard.
                HStack(spacing: 10) {
                    Button("Reject…") { redirecting = true }
                        .buttonStyle(Secondary())
                    if let scopes = request.scopes, !scopes.isEmpty {
                        // The Mac worked out what "always" could mean here;
                        // the choice is the user's. Scopes exist only for
                        // asks that are safe to widen, so risk is already
                        // in the list.
                        Button("Allow…") {
                            scopeID = scopes.first?.id
                            choosingScope = true
                        }
                        .buttonStyle(Secondary())
                    } else if risk != .high {
                        // An older companion sends no scopes: OpenCode's
                        // own "always" is the one blanket grant on offer,
                        // and never for a high-risk ask.
                        Button("Always") { confirmingAlways = true }
                            .buttonStyle(Secondary())
                    }
                }
            }
        }
        .padding(20)
        .background(.bar)
        .animation(Motion.easeOut(Motion.feedback), value: redirecting)
        .animation(Motion.easeOut(Motion.feedback), value: confirmingAlways)
        .animation(Motion.easeOut(Motion.feedback), value: choosingScope)
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

    /// Which grant, and for how long. Narrowest first, the narrowest
    /// preselected: widening is a deliberate tap, never the default.
    private var scopePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Allow, and stop asking for")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.inkMuted)
            ForEach(request.scopes ?? []) { scope in
                Button { scopeID = scope.id } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: scopeID == scope.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(scopeID == scope.id ? Color.clay : Color.inkMuted)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(scope.label)
                                .foregroundStyle(Color.ink)
                            Text(scope.patterns.joined(separator: "\n"))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Color.inkMuted)
                                .lineLimit(2)
                                .truncationMode(.head)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .fill(Color.surface)
                    )
                }
                .buttonStyle(.plain)
            }
            Toggle("Remember on this Mac", isOn: $remember)
                .tint(Color.clay)
                .foregroundStyle(Color.ink)
            Text(remember
                ? "Saved to this project's opencode.json, for every conversation. This conversation has it now; the rest after OpenCode next restarts."
                : "This conversation only, until OpenCode restarts.")
                .font(.footnote)
                .foregroundStyle(Color.inkMuted)
        }
    }

    private struct Primary: ButtonStyle {
        let tint: Color
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(tint.opacity(configuration.isPressed ? 0.75 : 1))
                )
        }
    }

    private struct Secondary: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.body)
                .foregroundStyle(Color.ink)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .stroke(Color.hairline, lineWidth: 1)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .fill(configuration.isPressed ? Color.surface : .clear)
                        )
                )
        }
    }
}
