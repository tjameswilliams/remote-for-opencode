import RemoteKit
import Sparkle
import SwiftUI

/// The Mac companion: a menu bar item and nothing else. Its jobs — keep
/// `opencode serve` alive on localhost, serve the paired phone over the
/// authenticated channel, and give pairing a window to happen in.
@main
struct MacCompanionApp: App {
    @StateObject private var opencode: OpenCodeProcess
    @StateObject private var phone = ConnectedClients.shared
    @StateObject private var server: RemoteServer
    @StateObject private var scheduler: Scheduler
    @StateObject private var modelSources = ModelSourceStore.shared
    @State private var started = false
    /// Sparkle drives its own update checks against the appcast; this also
    /// backs the menu's manual "Check for Updates…". The app is distributed
    /// outside the App Store (brew cask / direct dmg), so updating is ours
    /// to do.
    ///
    /// Deliberately not started at construction. Sparkle treats an invalid
    /// `SUPublicEDKey` as a fatal error and kills the app on launch, so the
    /// updater only starts once `updatesConfigured` has vetted the build —
    /// which also keeps Debug builds off the update channel entirely.
    private let updater = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
    )

    /// Whether this build can actually check for updates. False in
    /// development, which is why the menu item hides rather than lying.
    ///
    /// The key check alone stopped being a dev/release signal once the real
    /// `SUPublicEDKey` was committed to Info.plist: a Debug build from Xcode
    /// would auto-update over its own DerivedData copy with lldb attached —
    /// Sparkle's installer then wedges the app mid-termination, and a hung
    /// menu bar app holding an input grab can freeze the keyboard
    /// system-wide. Debug builds get no update channel, period.
    private static var updatesConfigured: Bool {
        #if DEBUG
            return false
        #else
            guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
            else { return false }
            return !key.isEmpty && !key.hasPrefix("REPLACE_WITH_")
        #endif
    }

    @MainActor
    init() {
        let opencode = OpenCodeProcess()
        _opencode = StateObject(wrappedValue: opencode)
        let adapter: () -> OpenCodeAdapter? = { [weak opencode] in
            guard case let .running(port, _) = opencode?.state else { return nil }
            return OpenCodeAdapter(port: port)
        }
        let scheduler = Scheduler(adapter: adapter)
        _scheduler = StateObject(wrappedValue: scheduler)
        // Built eagerly rather than in onAppear so the menu can observe its
        // conflict state from the first frame — a second instance must be
        // able to say so before the user opens anything.
        _server = StateObject(wrappedValue: RemoteServer(adapter: adapter, scheduler: scheduler))
        // Applying a model change ends in a restart of our own `opencode
        // serve`, held back while a turn is mid-flight.
        ModelSourceStore.shared.restartOpenCode = { [weak opencode] in opencode?.restart() }
        ModelSourceStore.shared.activeTurns = { LiveTurns.shared.activeCount }
    }

    var body: some Scene {
        MenuBarExtra("Remote for OpenCode", systemImage: menuSymbol) {
            StatusMenu(
                opencode: opencode, phone: phone, server: server, modelSources: modelSources,
                updater: Self.updatesConfigured ? updater : nil
            )
            .onAppear(perform: bootstrap)
        }

        Window("Workspace", id: "workspace") {
            WorkspaceWindow()
        }
        .defaultSize(width: 1200, height: 800)
        .commands { WorkspaceCommands() }

        Window("Devices", id: "devices") {
            DevicesWindow()
        }
        .windowResizability(.contentSize)
    }

    private var menuSymbol: String {
        switch opencode.state {
        case .running: return "iphone.gen3.radiowaves.left.and.right"
        case .starting: return "ellipsis.circle"
        case .stopped, .failed: return "exclamationmark.circle"
        }
    }

    private func bootstrap() {
        guard !started else { return }
        started = true
        if Self.updatesConfigured { updater.startUpdater() }
        opencode.start()
        server.start()
        scheduler.start()
        modelSources.start()
    }
}

struct StatusMenu: View {
    @ObservedObject var opencode: OpenCodeProcess
    @ObservedObject var phone: ConnectedClients
    @ObservedObject var server: RemoteServer
    @ObservedObject var modelSources: ModelSourceStore
    var updater: SPUStandardUpdaterController?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if server.conflict {
                // The single most confusing state this app can be in: two
                // copies running, the phone talking to the other one.
                Text("⚠︎ Another copy of Remote for OpenCode is running — quit it")
            }
            switch opencode.state {
            case let .running(port, version):
                Text("OpenCode \(version) · port \(String(port))")
            case .starting:
                Text("Starting OpenCode…")
            case .stopped:
                Text("OpenCode stopped")
            case let .failed(message):
                Text(message)
            }
            if let name = phone.connectedName {
                Text("\(name) connected")
            } else if !PairingStore.peers().isEmpty {
                Text("No device connected")
            }
            if !modelSources.pending.isEmpty {
                // A check found something; nothing is written until the
                // user has seen it, so the menu is where it waits.
                Button("Review Model Changes…") {
                    openWindow(id: "workspace")
                    NSApp.activate(ignoringOtherApps: true)
                    modelSources.reviewRequested = true
                }
            } else if modelSources.restartNeeded {
                Button("Restart OpenCode for New Models") { modelSources.restartNow() }
            }
            Divider()
            Button("Open Workspace") {
                openWindow(id: "workspace")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button(PairingStore.peers().isEmpty ? "Pair a Device…" : "Devices…") {
                openWindow(id: "devices")
                NSApp.activate(ignoringOtherApps: true)
            }
            // The kill switch: paused means the Mac stops advertising and
            // listening on both paths — not merely refusing.
            Button(server.paused ? "Resume Remote Access" : "Pause Remote Access") {
                server.setPaused(!server.paused)
            }
            Divider()
            if let updater {
                Button("Check for Updates…") { updater.checkForUpdates(nil) }
            }
            Button("Quit") {
                opencode.stop()
                NSApp.terminate(nil)
            }
        }
    }
}

/// Every paired peer — iPhones and Macs alike — plus the door to pairing
/// another. Revocation is per-peer now; the last revoke also wipes the key
/// material and rendezvous, matching the old single-device behavior.
struct DevicesWindow: View {
    @StateObject private var pairing = PairingSession()
    @StateObject private var clients = ConnectedClients.shared
    @State private var peers = PairingStore.peers()
    @State private var revoking: PairedPeer?
    @State private var addingDevice = false

    var body: some View {
        VStack(spacing: 16) {
            if peers.isEmpty || addingDevice {
                PairingPhaseView(session: pairing)
                if !peers.isEmpty {
                    Button("Back to Devices") {
                        addingDevice = false
                        pairing.stop()
                    }
                    .buttonStyle(.link)
                }
            } else {
                List {
                    ForEach(peers) { peer in
                        peerRow(peer)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 180)

                Text("Revoking removes this Mac's trust in that device. It can no longer connect, see your projects, or approve anything.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)

                Button("Pair Another Device…") {
                    addingDevice = true
                    pairing.start()
                }
            }
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 340)
        .confirmationDialog(
            "Revoke \(revoking?.name ?? "")?",
            isPresented: Binding(
                get: { revoking != nil },
                set: { if !$0 { revoking = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Revoke", role: .destructive) {
                if let peer = revoking { pairing.unpair(peer) }
                revoking = nil
            }
        } message: {
            Text("You'll need to pair again from both devices to reconnect.")
        }
        .onReceive(NotificationCenter.default.publisher(for: PairingStore.changed)) { _ in
            peers = PairingStore.peers()
            if case .paired = pairing.phase { addingDevice = false }
        }
    }

    private func peerRow(_ peer: PairedPeer) -> some View {
        HStack(spacing: 12) {
            Image(systemName: peer.role == .mac ? "macbook" : "iphone.gen3")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name).font(.headline)
                if clients.clients.contains(where: { !$0.loopback && $0.name == peer.name }) {
                    Label("Connected now", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text("Paired \(peer.pairedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Revoke", role: .destructive) { revoking = peer }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
        }
        .padding(.vertical, 4)
    }
}
