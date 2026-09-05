import Foundation

/// A prompt the Mac runs on its own later: once at `runAt`, or on the
/// `cron` expression's beat. Exactly one of the two is set. The Mac owns
/// the list and the clock; clients edit the definition fields and read the
/// history fields, which only the Mac writes.
public struct ScheduledTask: Codable, Hashable, Identifiable, Sendable {
    /// Client-minted UUID string; saving an existing id replaces the task.
    public var id: String
    public var name: String?
    /// Worktree path on the Mac the run starts in.
    public var project: String?
    public var prompt: String?
    /// Absent means the Mac's default model, same as an interactive prompt.
    public var providerID: String?
    public var modelID: String?
    /// Which agent to run as; "plan" keeps an unattended run read-only.
    public var agent: String?
    /// 5-field cron expression, in the Mac's local time.
    public var cron: String?
    /// One-shot fire date. A fired one-shot is disabled, not deleted, so
    /// its history survives.
    public var runAt: Date?
    /// Absent reads as true.
    public var enabled: Bool?
    public var created: Date?

    // History, written only by the Mac.
    public var lastRun: Date?
    /// "running" | "succeeded" | "failed" | "missed".
    public var lastOutcome: String?
    public var lastError: String?
    /// The session a run produced; how the user reads the transcript later.
    public var lastSessionID: String?
    public var lastTurnID: String?
    /// The Mac's answer to "when next", informational for clients.
    public var nextFire: Date?

    public var isEnabled: Bool { enabled ?? true }

    public init(
        id: String, name: String? = nil, project: String? = nil, prompt: String? = nil,
        providerID: String? = nil, modelID: String? = nil, agent: String? = nil,
        cron: String? = nil, runAt: Date? = nil, enabled: Bool? = nil, created: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.project = project
        self.prompt = prompt
        self.providerID = providerID
        self.modelID = modelID
        self.agent = agent
        self.cron = cron
        self.runAt = runAt
        self.enabled = enabled
        self.created = created
    }
}
