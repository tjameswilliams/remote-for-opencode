import AppKit
import Foundation
import OSLog
import RemoteKit

/// Keeps OpenCode's global config in step with the model endpoints the
/// user pointed this Mac at. OpenCode discovers nothing for an
/// OpenAI-compatible provider; whatever `provider.<id>.models` says is the
/// whole truth, and a model listed without limits runs with no context
/// window at all, so compaction never fires and the context meter has no
/// denominator.
///
/// Two halves, deliberately separate. Checking asks every enabled source
/// for its listing and plans what the config would become; it runs on a
/// schedule and never writes. Applying rewrites the file, and happens only
/// when the user has looked at the plan and said yes. OpenCode reads its
/// global config once at startup (verified against 1.18.15: neither the
/// file watcher nor the dispose endpoints reload it), so an apply ends
/// with a restart of the companion's `opencode serve`, deferred while a
/// turn is running.
@MainActor
final class ModelSourceStore: ObservableObject {
    static let shared = ModelSourceStore()

    enum AutoCheck: String, CaseIterable, Identifiable, Codable {
        case off
        case launch
        case hourly
        case daily

        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return "Manually"
            case .launch: return "When the app starts"
            case .hourly: return "Every hour"
            case .daily: return "Every day"
            }
        }
        var interval: TimeInterval? {
            switch self {
            case .off, .launch: return nil
            case .hourly: return 3600
            case .daily: return 86400
            }
        }
    }

    @Published private(set) var sources: [ModelSource] = []
    @Published var autoCheck: AutoCheck {
        didSet {
            UserDefaults.standard.set(autoCheck.rawValue, forKey: Self.autoKey)
            rearm()
        }
    }
    @Published private(set) var checking = false
    /// Plans from the last check that would change the file, waiting for
    /// the user. Empty means the config already matches every source.
    @Published private(set) var pending: [ModelSyncPlan] = []
    @Published private(set) var lastCheck: Date?
    /// Set when an apply wrote the file but OpenCode couldn't be restarted
    /// right then (a turn was running); the pane offers the restart.
    @Published private(set) var restartNeeded = false
    @Published private(set) var problem: String?
    /// Flipped by the menu bar's "Review Model Changes…" so a workspace
    /// window, freshly opened or not, knows to show the pane.
    @Published var reviewRequested = false

    /// The Mac's `opencode serve`, for the restart an apply needs. Wired by
    /// the app; nil in previews.
    var restartOpenCode: (() -> Void)?
    /// How many turns are mid-flight; a restart waits for zero.
    var activeTurns: () -> Int = { 0 }

    let configPath: String
    private let logger = Logger(subsystem: "com.timwilliams.opencodego", category: "models")
    private static let sourcesKey = "modelSources"
    private static let autoKey = "modelSources.autoCheck"
    private static let lastCheckKey = "modelSources.lastCheck"
    private var loop: Task<Void, Never>?

    init(configPath: String = OpenCodeConfigFile.globalPath()) {
        self.configPath = configPath
        autoCheck = UserDefaults.standard.string(forKey: Self.autoKey)
            .flatMap(AutoCheck.init(rawValue:)) ?? .launch
        if let data = UserDefaults.standard.data(forKey: Self.sourcesKey),
           let stored = try? JSONDecoder().decode([ModelSource].self, from: data) {
            sources = stored
        }
        lastCheck = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
    }

    var isEnabled: Bool { sources.contains(where: \.isEnabled) }

    /// Files OpenCode merges after ours; a managed provider redefined in
    /// one would silently undo an apply.
    var shadowingFiles: [String] { OpenCodeConfigFile.shadowingFiles(for: configPath) }

    /// The plan for one source, so a row can say what its check found.
    func plan(for source: ModelSource) -> ModelSyncPlan? {
        pending.first { $0.providerID == source.providerID }
    }

    // MARK: - Sources

    @discardableResult
    func save(_ incoming: ModelSource) -> String? {
        var source = incoming
        source.providerID = source.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        source.name = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
        source.baseURL = source.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = source.validationProblem { return problem }
        if sources.contains(where: { $0.id != source.id && $0.providerID == source.providerID }) {
            return "Another source already uses the provider id \"\(source.providerID)\"."
        }
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            let old = sources[index]
            source.created = old.created
            // A changed endpoint makes the old check meaningless.
            if old.baseURL != source.baseURL || old.apiKey != source.apiKey {
                source.lastChecked = nil
                source.lastError = nil
                source.lastModelCount = nil
            }
            sources[index] = source
        } else {
            source.created = Date()
            sources.append(source)
        }
        // A pending plan for an edited source describes an endpoint that
        // may no longer exist; the next check replaces it.
        pending.removeAll { $0.providerID == source.providerID }
        persist()
        return nil
    }

    func delete(id: String) {
        guard let source = sources.first(where: { $0.id == id }) else { return }
        sources.removeAll { $0.id == id }
        pending.removeAll { $0.providerID == source.providerID }
        persist()
    }

    func setEnabled(_ enabled: Bool, id: String) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].enabled = enabled
        if !enabled { pending.removeAll { $0.providerID == sources[index].providerID } }
        persist()
    }

    // MARK: - Checking

    /// Arms the automatic check. Called once at launch; the picker re-arms
    /// on change. "When the app starts" runs right away and never again.
    func start() {
        rearm()
    }

    private func rearm() {
        loop?.cancel()
        loop = nil
        guard isEnabled, autoCheck != .off else { return }
        if autoCheck == .launch {
            Task { await check() }
            return
        }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let interval = self.autoCheck.interval else { return }
                let due = (self.lastCheck ?? .distantPast).addingTimeInterval(interval)
                let wait = max(1, min(due.timeIntervalSinceNow, 60))
                if due <= Date() {
                    await self.check()
                } else {
                    try? await Task.sleep(for: .seconds(wait))
                }
            }
        }
    }

    /// Ask every enabled source what it serves and plan the config each
    /// would produce. Sources that fail keep their error on the row and
    /// their old config block untouched; a plan is only made from a
    /// listing that arrived whole.
    func check() async {
        guard !checking else { return }
        checking = true
        problem = nil
        defer {
            checking = false
            lastCheck = Date()
            UserDefaults.standard.set(lastCheck, forKey: Self.lastCheckKey)
        }
        let root: [String: Any]
        do {
            root = try OpenCodeConfigFile.read(at: configPath)
        } catch {
            problem = error.localizedDescription
            logger.error("config unreadable: \(error.localizedDescription, privacy: .public)")
            return
        }
        let providers = root["provider"] as? [String: Any] ?? [:]
        var plans: [ModelSyncPlan] = []
        for source in sources where source.isEnabled {
            guard let index = sources.firstIndex(where: { $0.id == source.id }) else { continue }
            sources[index].lastChecked = Date()
            do {
                let discovered = try await Self.fetch(source)
                sources[index].lastError = nil
                sources[index].lastModelCount = discovered.count
                let plan = ModelCatalogSync.plan(
                    source: source, discovered: discovered,
                    existingProvider: providers[source.providerID] as? [String: Any]
                )
                if !plan.isEmpty { plans.append(plan) }
                logger.notice(
                    "\(source.providerID, privacy: .public): \(discovered.count) models, \(plan.isEmpty ? "in sync" : "changes pending", privacy: .public)"
                )
            } catch {
                sources[index].lastError = error.localizedDescription
                logger.error("\(source.providerID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        pending = plans
        persist()
    }

    enum FetchError: LocalizedError {
        case badURL
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .badURL: return "The base URL isn't valid."
            case let .http(status): return "The endpoint answered HTTP \(status)."
            }
        }
    }

    nonisolated static func fetch(_ source: ModelSource) async throws -> [DiscoveredModel] {
        guard let url = source.modelsURL else { throw FetchError.badURL }
        var request = URLRequest(url: url, timeoutInterval: 15)
        if let key = source.apiKey, !key.isEmpty, key != "none" {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw FetchError.http(http.statusCode)
        }
        return try ModelListing.parse(data)
    }

    // MARK: - Applying

    /// Write every pending plan into the config. The file is re-read
    /// first so an edit made since the check survives; each plan's block
    /// replaces its provider whole, which is what the review showed.
    func applyPending() {
        guard !pending.isEmpty else { return }
        do {
            let root = try OpenCodeConfigFile.read(at: configPath)
            let updated = ModelCatalogSync.apply(pending, to: root)
            let backup = try OpenCodeConfigFile.write(updated, to: configPath)
            logger.notice(
                "wrote \(self.pending.count) provider block(s) to \(self.configPath, privacy: .public)\(backup.map { ", backup at \($0)" } ?? "", privacy: .public)"
            )
            pending = []
            problem = nil
            restartIfIdle()
        } catch {
            problem = error.localizedDescription
            logger.error("apply failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func discardPending() {
        pending = []
    }

    /// OpenCode only reads the file at startup. Restart now if nothing is
    /// mid-turn; otherwise leave the offer on the pane.
    func restartIfIdle() {
        guard let restartOpenCode else {
            restartNeeded = true
            return
        }
        if activeTurns() > 0 {
            restartNeeded = true
            return
        }
        restartNeeded = false
        restartOpenCode()
        NotificationCenter.default.post(name: Self.applied, object: nil)
    }

    /// The user's explicit restart from the pane, turns or no turns.
    func restartNow() {
        restartNeeded = false
        restartOpenCode?()
        NotificationCenter.default.post(name: Self.applied, object: nil)
    }

    /// Posted after OpenCode is restarted on a new config: model pickers
    /// should refetch their catalogue.
    static let applied = Notification.Name("ModelSourceStore.applied")

    private func persist() {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: Self.sourcesKey)
        }
    }
}
