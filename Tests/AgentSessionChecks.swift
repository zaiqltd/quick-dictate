import Foundation

@MainActor final class AgentSessionMockClient: AgentResponding {
    var requests: [(messages: [[String: Any]], tools: [[String: Any]])] = []
    var handler: (@MainActor (Int) async throws -> AgentReply)!
    func respond(messages: [[String: Any]], model: String, key: String, tools: [[String: Any]]) async throws -> AgentReply {
        requests.append((messages, tools))
        return try await handler(requests.count)
    }
}

extension CoreTests {
    @MainActor static func agentSessionChecks() async throws {
        let suite = "quick-dictate-agent-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = FeatureSettings(defaults: defaults)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quick-dictate-agent-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try settings.update { $0.workRoot = root.path }
        check(settings.options.enabledModes == [.dictation] && !settings.options.terminalEnabled && !settings.options.computerEnabled, "Assistant and actions start disabled")
        try settings.update { $0.askEnabled = true }
        check(FeatureSettings(defaults: defaults).options.askEnabled, "Feature choices survive settings reload")
        let beforeInvalid = settings.options
        await expectError("Choose a folder") { try settings.update { $0.workRoot = " " } }
        check(settings.options == beforeInvalid, "Rejected feature changes leave settings intact")

        func reply(_ text: String = "Done.", calls: [AgentToolCall] = []) -> AgentReply {
            var message: [String: Any] = ["role": "assistant", "content": text]
            if !calls.isEmpty {
                message["tool_calls"] = calls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.argumentsJSONString]] }
            }
            return AgentReply(text: text, toolCalls: calls, assistantMessage: message)
        }
        func call(_ id: String = "call_one", command: String = "pwd", name: String = "run_terminal") -> AgentToolCall {
            let args: [String: Any] = name == "run_terminal" ? ["command": command] : ["url": "https://example.com"]
            return AgentToolCall(id: id, name: name, argumentsJSONString: String(data: try! JSONSerialization.data(withJSONObject: args), encoding: .utf8)!, arguments: args)
        }
        func success(_ output: String = "fixture output", cancelled: Bool = false) -> LocalActionResult {
            LocalActionResult(output: output, exitCode: 0, timedOut: false, cancelled: cancelled, truncated: false)
        }
        func waitFor(_ description: String, _ condition: () -> Bool) async {
            for _ in 0..<200 {
                if condition() { check(true, description); return }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            check(false, "Timed out: \(description)")
        }
        func toolResults(_ request: (messages: [[String: Any]], tools: [[String: Any]])) -> [[String: Any]] {
            request.messages.filter { $0["role"] as? String == "tool" }
        }
        var executed = 0
        let neverRun: AgentActionExecution = { _, _, _, _ in executed += 1; return success() }
        let chatClient = AgentSessionMockClient()
        chatClient.handler = { _ in reply("An answer.") }
        let chat = AgentSession(settings: settings, client: chatClient, loadKey: { "fake-key" }, executeAction: neverRun)
        check(!chat.send("An action", mode: .act), "Disabled mode explicitly rejects submission")
        check(chat.state == .idle && chatClient.requests.isEmpty && chat.error.contains("Enable"), "Do mode cannot run while disabled")
        check(!chat.send("Words", mode: .dictation), "Dictation explicitly rejects agent submission")
        check(chatClient.requests.isEmpty, "Dictation cannot accidentally enter the agent")
        check(!chat.send("  ", mode: .ask), "Blank text explicitly rejects submission")
        check(!chat.send(String(repeating: "x", count: 16_001), mode: .ask), "Oversized text explicitly rejects submission")
        check(chatClient.requests.isEmpty, "Blank agent requests are inert")
        let noKey = AgentSession(settings: settings, client: chatClient, loadKey: { nil }, executeAction: neverRun)
        check(!noKey.send("Question", mode: .ask), "Missing key explicitly rejects submission")
        check(noKey.error.contains("OpenRouter key") && noKey.turns.isEmpty, "Missing key does not create a phantom user turn")
        let blankKey = AgentSession(settings: settings, client: chatClient, loadKey: { " \n " }, executeAction: neverRun)
        check(!blankKey.send("Question", mode: .ask) && blankKey.turns.isEmpty, "Blank key also rejects submission without creating a turn")
        try settings.update { $0.actEnabled = true; $0.terminalEnabled = true; $0.computerEnabled = true }
        check(chat.send("Question", mode: .ask, selection: "Private selection"), "Scheduled question reports acceptance")
        await waitFor("Ask finishes", { chat.state == .idle })
        check(chatClient.requests[0].tools.allSatisfy { ($0["function"] as? [String: Any])?["name"] as? String == "web_search" } && executed == 0, "Ask advertises only read-only search, never local actions")
        check(!chatClient.requests[0].messages.contains { ($0["content"] as? String)?.contains("Private selection") == true }, "Selected text is absent unless explicitly enabled")
        try settings.update { $0.useSelectedText = true }
        chat.send("Explain", mode: .ask, selection: "Chosen context")
        await waitFor("Selected-context question finishes", { chat.state == .idle })
        check(chatClient.requests[1].messages.contains { ($0["content"] as? String)?.contains("Chosen context") == true }, "Opted-in selected text accompanies the question")

        let actionClient = AgentSessionMockClient()
        actionClient.handler = { index in index == 1 ? reply("", calls: [call()]) : reply("The command finished.") }
        let agent = AgentSession(settings: settings, client: actionClient, loadKey: { "fake-key" }, executeAction: { reviewed, timeout, limit, output in
            executed += 1
            check(reviewed.workRoot == root.resolvingSymlinksInPath(), "Execution receives the reviewed root")
            check(timeout == 45 && limit == 32_000, "Execution has bounded time and output")
            if case .shell(let command, _) = reviewed.action { check(command == "pwd", "Execution uses the reviewed exact command") }
            else { check(false, "Expected shell proposal") }
            output("fixture output")
            return success()
        })
        agent.send("Check this folder", mode: .act)
        await waitFor("Do pauses for review", { agent.state == .reviewing })
        check(agent.pending.count == 1 && executed == 0 && actionClient.requests.count == 1, "Tool proposals remain inert before Run")
        let advertised = actionClient.requests[0].tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        check(Set(advertised) == ["run_terminal", "open_url", "open_file", "open_application", "web_search"], "Only supported enabled actions and read-only search are advertised")
        agent.draft = "Preserve this draft"
        check(!agent.send("Another request", mode: .ask), "Busy agent reports rejection so spoken audio can remain available to retry")
        check(agent.error.contains("still busy") && agent.draft == "Preserve this draft", "Busy rejection explains recovery and preserves the draft")
        check(agent.turns.filter { $0.role == .user }.count == 1, "A busy agent does not mix new requests into pending action history")
        agent.approveNext(); agent.approveNext()
        await waitFor("Approved action and follow-up finish", { agent.state == .idle })
        check(executed == 1 && agent.pending.isEmpty, "Double Run cannot execute a proposal twice")
        let result = toolResults(actionClient.requests[1])
        check(result.count == 1 && result[0]["tool_call_id"] as? String == "call_one", "Completed action answers exactly its original tool ID")
        check((result[0]["content"] as? String)?.contains("fixture output") == true, "Real action output is supplied to the follow-up")

        func pendingSession(_ id: String) async -> (AgentSession, AgentSessionMockClient) {
            let client = AgentSessionMockClient()
            client.handler = { index in index == 1 ? reply("", calls: [call(id)]) : reply() }
            let session = AgentSession(settings: settings, client: client, loadKey: { "fake-key" }, executeAction: neverRun)
            session.send("Do it", mode: .act)
            await waitFor("Proposal \(id) reaches review", { session.state == .reviewing })
            return (session, client)
        }
        let (gate, gateClient) = await pendingSession("gate_call")
        try settings.update { $0.terminalEnabled = false }
        gate.approveNext()
        check(gate.state == .idle && gate.pending.isEmpty && executed == 1, "Approval rechecks current terminal capability")
        gate.send("What happened?", mode: .ask)
        await waitFor("Cancelled proposal history remains usable", { gate.state == .idle })
        check(toolResults(gateClient.requests[1]).map { $0["tool_call_id"] as? String } == ["gate_call"], "Revoked action closes its pending tool ID exactly once")
        try settings.update { $0.terminalEnabled = true }
        let (changedRoot, _) = await pendingSession("root_call")
        let otherRoot = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        try settings.update { $0.workRoot = otherRoot.path }
        changedRoot.approveNext()
        check(changedRoot.state == .idle && changedRoot.error.contains("settings changed") && executed == 1, "A changed working root invalidates approval")
        try settings.update { $0.workRoot = root.path }

        let multipleClient = AgentSessionMockClient()
        multipleClient.handler = { index in index == 1 ? reply("", calls: [call("first"), call("second")]) : reply() }
        let multiple = AgentSession(settings: settings, client: multipleClient, loadKey: { "test" }, executeAction: neverRun)
        multiple.send("Two actions", mode: .act)
        await waitFor("Multiple actions await review", { multiple.state == .reviewing })
        multiple.approveNext()
        await waitFor("Second action awaits its own approval", { multiple.state == .reviewing && multiple.pending.count == 1 })
        check(executed == 2 && multipleClient.requests.count == 1, "Approving one action does not approve the following action")
        multiple.cancel()
        multiple.send("Explain", mode: .ask)
        await waitFor("Partial approval history remains usable", { multiple.state == .idle })
        check(toolResults(multipleClient.requests[1]).map { $0["tool_call_id"] as? String } == ["first", "second"], "Executed and cancelled calls each receive one tool result")

        let lateClient = AgentSessionMockClient()
        var late: CheckedContinuation<AgentReply, Error>?
        lateClient.handler = { _ in try await withCheckedThrowingContinuation { late = $0 } }
        let lateSession = AgentSession(settings: settings, client: lateClient, loadKey: { "test" }, executeAction: neverRun)
        lateSession.send("Slow question", mode: .ask)
        await waitFor("Slow request starts", { late != nil })
        lateSession.cancel()
        late?.resume(returning: reply("Stale answer")); late = nil
        for _ in 0..<10 { await Task.yield() }
        check(lateSession.state == .idle && !lateSession.turns.contains { $0.text == "Stale answer" }, "Late network replies cannot resurrect a cancelled request")
        lateSession.newChat()
        check(lateSession.turns.isEmpty && lateSession.error.isEmpty && lateSession.liveOutput.isEmpty, "New chat clears only in-memory conversation state")

        let failingClient = AgentSessionMockClient()
        failingClient.handler = { _ in throw AgentClientError.timeout }
        let failing = AgentSession(settings: settings, client: failingClient, loadKey: { "test" }, executeAction: neverRun)
        failing.send("Timeout", mode: .ask)
        await waitFor("Network failure returns idle", { failing.state == .idle })
        check(failing.error.contains("too long"), "Network failures are visible and recoverable")
        failingClient.handler = { _ in throw CancellationError() }
        failing.send("Interrupted", mode: .ask)
        await waitFor("Unexpected request cancellation returns idle", { failing.state == .idle })
        check(!failing.isBusy, "Unexpected cancellation cannot leave the spinner stuck")

        let boundedClient = AgentSessionMockClient()
        boundedClient.handler = { index in index == 1 ? reply("", calls: [call("bounded")]) : reply() }
        let bounded = AgentSession(settings: settings, client: boundedClient, loadKey: { "test" }, executeAction: { _, _, _, _ in success(String(repeating: "😀", count: 40_000)) })
        bounded.send("Produce output", mode: .act)
        await waitFor("Large output proposal reaches review", { bounded.state == .reviewing })
        bounded.approveNext()
        await waitFor("Large output action finishes", { bounded.state == .idle })
        let boundedResult = toolResults(boundedClient.requests[1])[0]["content"] as! String
        check(boundedResult.utf8.count <= 32_000 && boundedResult.contains("truncated"), "Tool output is bounded by bytes and marked truncated")

        let stoppedClient = AgentSessionMockClient()
        stoppedClient.handler = { _ in reply("", calls: [call("stopped")]) }
        let stopped = AgentSession(settings: settings, client: stoppedClient, loadKey: { "test" }, executeAction: { _, _, _, _ in success("", cancelled: true) })
        stopped.send("Cancelled action", mode: .act)
        await waitFor("Cancellable action awaits review", { stopped.state == .reviewing })
        stopped.approveNext()
        await waitFor("Executor cancellation returns idle", { stopped.state == .idle })
        check(stopped.error.contains("stopped") && stoppedClient.requests.count == 1, "A cancelled executor result is never reported as success or auto-continued")

        let actionErrorClient = AgentSessionMockClient()
        actionErrorClient.handler = { index in index == 1 ? reply("", calls: [call("failed_action")]) : reply("The action failed.") }
        let actionError = AgentSession(settings: settings, client: actionErrorClient, loadKey: { "test" }, executeAction: { _, _, _, _ in throw LocalActionError.launchFailed })
        actionError.send("An action that fails", mode: .act)
        await waitFor("Failing action awaits review", { actionError.state == .reviewing })
        actionError.approveNext()
        await waitFor("Execution failure returns idle", { actionError.state == .idle })
        check((toolResults(actionErrorClient.requests[1])[0]["content"] as? String)?.contains("Action failed") == true, "Execution errors become an honest result for the same tool call")

        let runningClient = AgentSessionMockClient()
        runningClient.handler = { index in index == 1 ? reply("", calls: [call("running_action")]) : reply() }
        var runningContinuation: CheckedContinuation<LocalActionResult, Error>?
        var lateOutput: (@Sendable (String) -> Void)?
        let running = AgentSession(settings: settings, client: runningClient, loadKey: { "test" }, executeAction: { _, _, _, output in
            lateOutput = output
            return try await withCheckedThrowingContinuation { runningContinuation = $0 }
        })
        running.send("Slow action", mode: .act)
        await waitFor("Slow action awaits review", { running.state == .reviewing })
        running.approveNext()
        await waitFor("Slow executor starts", { runningContinuation != nil })
        running.cancel()
        lateOutput?("Stale terminal output")
        runningContinuation?.resume(returning: success("Stale completion")); runningContinuation = nil
        for _ in 0..<10 { await Task.yield() }
        check(running.state == .idle && running.pending.isEmpty && running.liveOutput.isEmpty, "Cancel ignores late executor output and completion")
        check(runningClient.requests.count == 1 && !running.turns.contains { $0.text.contains("Stale completion") }, "Cancelled execution cannot continue the agent loop")
        running.send("What happened?", mode: .ask)
        await waitFor("Chat after running cancellation finishes", { running.state == .idle })
        check(toolResults(runningClient.requests[1]).map { $0["tool_call_id"] as? String } == ["running_action"], "Cancellation closes the running call without duplicating its late result")

        let disappearing = root.appendingPathComponent("disappearing")
        try FileManager.default.createDirectory(at: disappearing, withIntermediateDirectories: true)
        try settings.update { $0.workRoot = disappearing.path }
        let (missingFolder, _) = await pendingSession("missing_folder")
        try FileManager.default.removeItem(at: disappearing)
        missingFolder.approveNext()
        check(missingFolder.state == .idle && missingFolder.pending.isEmpty && !missingFolder.error.isEmpty, "A disappeared working folder fails approval cleanly without execution")
        try settings.update { $0.workRoot = root.path }

        let loopClient = AgentSessionMockClient()
        loopClient.handler = { index in reply("", calls: [call("disabled_\(index)", name: "unknown_tool")]) }
        let loop = AgentSession(settings: settings, client: loopClient, loadKey: { "test" }, executeAction: neverRun)
        loop.send("Looping tool", mode: .act)
        await waitFor("Repeated invalid tools hit the round limit", { loop.state == .idle })
        check(loopClient.requests.count == 6 && loop.error.contains("limit"), "Agent loops have a hard round bound")
        check(executed == 2, "Unknown or disabled tools never execute")

        let historyClient = AgentSessionMockClient()
        historyClient.handler = { _ in reply("Short answer") }
        let history = AgentSession(settings: settings, client: historyClient, loadKey: { "test" }, executeAction: neverRun)
        for index in 0..<12 {
            history.send("Question \(index)", mode: .ask)
            await waitFor("History round \(index) finishes", { history.state == .idle })
        }
        check(historyClient.requests.last!.messages.filter { $0["role"] as? String == "user" }.count == 8, "History retains at most eight whole user exchanges")
        let (settingsStop, _) = await pendingSession("settings_stop")
        settingsStop.settingsChanged()
        check(settingsStop.state == .idle && settingsStop.pending.isEmpty, "Settings updates stop a pending request cleanly")
    }
}
