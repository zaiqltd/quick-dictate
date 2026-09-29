import Foundation

// Explicit live smoke test. Sends only the synthetic prompts below; does not
// change saved feature settings or send files, selections, or private context.
@main struct AgentSmoke {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.dropFirst().first == "--live" else {
            print("Pass --live to run synthetic OpenRouter requests using your saved key.")
            return
        }
        let client = AgentClient()
        let key = Credentials.load() ?? ""
        let streaming = CommandLine.arguments.contains("--stream")
        func respond(messages: [[String: Any]], model: String, tools: [[String: Any]]) async throws -> AgentReply {
            if streaming {
                return try await client.stream(messages: messages, model: model, key: key, tools: tools) { _ in }
            }
            return try await client.respond(messages: messages, model: model, key: key, tools: tools)
        }
        if CommandLine.arguments.contains("--search-only") {
            let start = Date()
            let result = try await WebSearchClient(client: client).search("Python official documentation tutorial", key: key)
            let data = try JSONSerialization.data(withJSONObject: ["test": "public web search", "model": AgentModel.defaultID,
                "summary": result.summary, "sources": result.sources.map(\.url.absoluteString),
                "seconds": Date().timeIntervalSince(start)], options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        if CommandLine.arguments.contains("--history-only") {
            let messages: [[String: Any]] = [
                ["role": "user", "content": "Synthetic completed action fixture: print a fixed test marker."],
                ["role": "assistant", "content": NSNull(), "tool_calls": [["id": "test_completed_action", "type": "function", "function": ["name": "run_terminal", "arguments": "{\"command\":\"printf test\"}"]]]],
                ["role": "tool", "tool_call_id": "test_completed_action", "content": "test"],
                ["role": "assistant", "content": "The fixture action printed test."],
                ["role": "user", "content": "We are now in Ask mode, with no tools available. Reply exactly: History accepted."]
            ]
            let start = Date()
            let reply = try await respond(messages: messages, model: AgentModel.defaultID, tools: [])
            guard reply.text.contains("History accepted"), reply.toolCalls.isEmpty else { throw DictationError(message: "History smoke failed") }
            let data = try JSONSerialization.data(withJSONObject: ["test": "Completed tool history followed by Ask without tools", "text": reply.text, "seconds": Date().timeIntervalSince(start), "usage": reply.usage ?? [:]], options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8)!)
            return
        }
        var evidence: [[String: Any]] = []
        let models = CommandLine.arguments.contains("--default-only") ? [AgentModel.defaultID] : [AgentModel.defaultID, "anthropic/claude-haiku-4.5"]
        for model in models {
            let start = Date()
            let reply = try await respond(messages: [["role": "user", "content": "This is an integration smoke test. Reply with exactly: Quick Dictate is ready."]], model: model, tools: [])
            guard reply.text.contains("Quick Dictate is ready"), reply.toolCalls.isEmpty else { throw DictationError(message: "Unexpected smoke answer") }
            evidence.append(["test": "text reply", "model": model, "text": reply.text, "seconds": Date().timeIntervalSince(start), "usage": reply.usage ?? [:]])
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quick-dictate-live-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var options = FeatureOptions(); options.actEnabled = true; options.terminalEnabled = true; options.workRoot = root.path
        let toolSchema = AgentSession.toolDefinitions(options: options)
        let command = "printf 'quick-dictate-action-ok\\n'"
        var messages: [[String: Any]] = [["role": "user", "content": "Integration test. Call run_terminal exactly once with command exactly \(command) and omit directory. This prints a fixed test marker only. After the tool result, reply with exactly: Action verified."]]
        let start = Date()
        let proposal = try await respond(messages: messages, model: AgentModel.defaultID, tools: toolSchema)
        if CommandLine.arguments.contains("--proposal-only") {
            let sample = try JSONSerialization.data(withJSONObject: ["text": proposal.text,
                "calls": proposal.toolCalls.map { ["name": $0.name, "arguments": $0.arguments] },
                "seconds": Date().timeIntervalSince(start)], options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: sample, as: UTF8.self))
            return
        }
        guard proposal.toolCalls.count == 1, let call = proposal.toolCalls.first,
              call.name == "run_terminal", call.arguments["command"] as? String == command,
              call.arguments["directory"] == nil || call.arguments["directory"] as? String == "." || call.arguments["directory"] as? String == "" else {
            throw DictationError(message: "Model did not return the exact inert test command; nothing executed")
        }
        let action = try LocalAction.proposal(toolName: call.name, arguments: call.arguments, workRoot: root)
        let result = try await LocalActionExecutor().run(ReviewedLocalAction(action: action, workRoot: root), timeout: 5, outputLimit: 1024)
        guard result.succeeded, result.output == "quick-dictate-action-ok\n" else { throw DictationError(message: "Test action failed") }
        messages.append(proposal.assistantMessage)
        messages.append(["role": "tool", "tool_call_id": call.id, "content": result.output])
        let final = try await respond(messages: messages, model: AgentModel.defaultID, tools: toolSchema)
        guard final.toolCalls.isEmpty, final.text.contains("Action verified") else { throw DictationError(message: "Tool follow-up failed") }
        evidence.append(["test": "tool proposal, explicit test review, terminal execution, model follow-up", "model": AgentModel.defaultID, "output": result.output, "answer": final.text, "seconds": Date().timeIntervalSince(start), "proposal_usage": proposal.usage ?? [:], "followup_usage": final.usage ?? [:]])
        let json = try JSONSerialization.data(withJSONObject: ["date": ISO8601DateFormatter().string(from: Date()), "transport": streaming ? "SSE streaming" : "JSON response", "checks": evidence], options: [.prettyPrinted, .sortedKeys])
        print(String(data: json, encoding: .utf8)!)
    }
}
