import Foundation

/// Translates OpenCode 2's event stream into the 1.x events the turn loop
/// (`TurnRunner.pump`) is written against, as `{type, properties}`.
///
/// 2.x's events are finer grained and named differently. Verified live on
/// 2.1.4, a turn reads:
///
///     session.inbox.enqueued        the user's prompt
///     session.execution.started
///     session.step.started          one model call, with its model
///       session.reasoning.started / .delta / .ended
///       session.text.started / .delta / .ended
///       session.tool.input.started  (name) → .called (input) → .success | .failed
///     session.step.ended            tokens for that call
///     session.usage.updated         the session's running cost
///     … more steps …
///     session.execution.succeeded | .failed | .interrupted
///
/// The mapping: steps become `message.updated` (role, model, tokens), text
/// and reasoning become parts with deltas, tools become tool parts as they
/// progress, the end of an execution becomes `session.idle` (after a
/// `session.error` when it failed), forms become questions, and permission
/// asks are renamed field by field. Anything else passes through under its
/// own name so the stall watchdog still sees the session making progress.
///
/// One translator per subscription: tool events after the first carry only
/// an id, so the tool's name and input are remembered from earlier ones.
/// Used from a single task, never shared.
final class OpenCodeEventsV2: @unchecked Sendable {
    private var models: [String: (providerID: String, modelID: String)] = [:]
    private var toolNames: [String: String] = [:]
    private var toolInputs: [String: [String: Any]] = [:]
    private var compactions = 0

    func translate(_ event: [String: Any]) -> [[String: Any]] {
        guard let type = event["type"] as? String else { return [] }
        let data = event["data"] as? [String: Any] ?? [:]
        let sessionID = data["sessionID"] as? String
        let messageID = data["assistantMessageID"] as? String ?? ""

        func v1(_ type: String, _ properties: [String: Any]) -> [String: Any] {
            ["type": type, "properties": properties]
        }
        /// A part snapshot, stamped with where it belongs.
        func part(_ part: [String: Any], messageID: String) -> [String: Any] {
            var part = part
            part["sessionID"] = sessionID
            part["messageID"] = messageID
            return v1("message.part.updated", ["part": part])
        }
        func assistant(tokens: Any?) -> [String: Any] {
            var info: [String: Any] = ["id": messageID, "role": "assistant", "sessionID": sessionID as Any]
            if let model = models[messageID] {
                info["providerID"] = model.providerID
                info["modelID"] = model.modelID
            }
            if let tokens { info["tokens"] = tokens }
            return v1("message.updated", ["info": info])
        }

        switch type {
        case "session.step.started":
            if let model = data["model"] as? [String: Any],
               let providerID = model["providerID"] as? String, let id = model["id"] as? String {
                models[messageID] = (providerID, id)
            }
            return [assistant(tokens: nil)]
        case "session.step.ended":
            return [assistant(tokens: data["tokens"])]

        case "session.text.started", "session.reasoning.started",
             "session.text.ended", "session.reasoning.ended":
            let kind = type.hasPrefix("session.text") ? "text" : "reasoning"
            let id = "\(messageID):\(kind):\(data["ordinal"] as? Int ?? 0)"
            return [part(["type": kind, "id": id, "text": data["text"] as? String ?? ""], messageID: messageID)]
        case "session.text.delta", "session.reasoning.delta":
            let kind = type.hasPrefix("session.text") ? "text" : "reasoning"
            return [v1("message.part.delta", [
                "sessionID": sessionID as Any,
                "messageID": messageID,
                "partID": "\(messageID):\(kind):\(data["ordinal"] as? Int ?? 0)",
                "field": "text",
                "delta": data["delta"] as? String ?? "",
            ])]

        case "session.tool.input.started", "session.tool.called",
             "session.tool.success", "session.tool.failed":
            guard let id = data["id"] as? String else { return [] }
            if let name = data["name"] as? String { toolNames[id] = name }
            if let input = data["input"] as? [String: Any] { toolInputs[id] = input }
            let status: String
            switch type {
            case "session.tool.input.started": status = "pending"
            case "session.tool.called": status = "running"
            case "session.tool.success": status = "completed"
            default: status = "error"
            }
            let name = toolNames[id]
            var out = [part(
                OpenCodeAdapter.v1ToolPart(id: id, name: name, status: status, input: toolInputs[id]),
                messageID: messageID
            )]
            // The plan arrives as the todo tool's input; 1.x had an event.
            if type == "session.tool.called", OpenCodeAdapter.isTodoTool(name),
               let todos = toolInputs[id]?["todos"] {
                out.append(v1("todo.updated", ["sessionID": sessionID as Any, "todos": todos]))
            }
            if type == "session.tool.success" || type == "session.tool.failed" {
                toolNames[id] = nil
                toolInputs[id] = nil
            }
            return out

        case "session.compaction.started", "session.compaction.delta", "session.compaction.ended":
            // /summarize. 1.x streamed the summary as an assistant answer;
            // 2.x streams it as compaction events, shown the same way.
            if type == "session.compaction.started" { compactions += 1 }
            let id = "\(sessionID ?? ""):compaction:\(compactions)"
            if type == "session.compaction.delta" {
                return [v1("message.part.delta", [
                    "sessionID": sessionID as Any, "messageID": id, "partID": id,
                    "field": "text", "delta": data["text"] as? String ?? "",
                ])]
            }
            return [part(["type": "text", "id": id, "text": data["text"] as? String ?? ""], messageID: id)]

        case "session.inbox.enqueued":
            // The prompt, from here or from anywhere else (the TUI). Its
            // inbox id is the user message's id.
            guard let item = data["item"] as? [String: Any], item["type"] as? String == "user",
                  let inboxID = data["inboxID"] as? String
            else { return [v1(type, data)] }
            let text = (item["payload"] as? [String: Any])?["text"] as? String ?? ""
            return [
                v1("message.updated", ["info": ["id": inboxID, "role": "user", "sessionID": sessionID as Any]]),
                part(["type": "text", "id": "\(inboxID):text", "text": text], messageID: inboxID),
            ]

        case "session.usage.updated":
            return [v1("session.updated", ["info": ["id": sessionID as Any, "cost": data["cost"] as Any]])]
        case "session.renamed", "session.created":
            var info: [String: Any] = ["id": sessionID as Any]
            if let title = data["title"] as? String { info["title"] = title }
            return [v1(type == "session.created" ? "session.created" : "session.updated", ["info": info])]

        case "permission.asked":
            return [v1("permission.asked", OpenCodeAdapter.v1Permission(from: data))]
        case "permission.replied":
            return [v1("permission.replied", ["sessionID": sessionID as Any])]

        case "form.created":
            guard let form = data["form"] as? [String: Any],
                  let question = OpenCodeAdapter.v1Question(from: form)
            else { return [] }
            return [v1("question.asked", question)]
        case "form.replied", "form.cancelled":
            return [v1("question.replied", ["sessionID": sessionID as Any])]

        case "session.execution.succeeded", "session.execution.interrupted":
            return [v1("session.idle", ["sessionID": sessionID as Any])]
        case "session.execution.failed":
            let error = data["error"] as? [String: Any]
            // The status rides in the name so the retry classifier, which
            // reads words like "429", sees a rate limit for what it is.
            var name = error?["type"] as? String ?? "Error"
            if let status = error?["status"] as? Int { name += " \(status)" }
            return [
                v1("session.error", [
                    "sessionID": sessionID as Any,
                    "error": ["name": name, "data": ["message": error?["message"] as? String ?? name]],
                ]),
                v1("session.idle", ["sessionID": sessionID as Any]),
            ]

        case "session.idle", "session.status":
            // Deprecated in 2.x and redundant with the execution events
            // above; passing them on could end a turn twice.
            return []
        default:
            return [v1(type, data)]
        }
    }
}
