import Foundation

@MainActor private final class ProgressFixtureClock {
    var date = Date(timeIntervalSince1970: 1_000)
    func set(_ seconds: TimeInterval) { date = Date(timeIntervalSince1970: 1_000 + seconds) }
}

@MainActor private final class ProgressFixtureClient: AgentStreaming {
    private(set) var count = 0
    private var callbacks: [@MainActor (String) -> Void] = []
    private var continuations: [Int: CheckedContinuation<AgentReply, Error>] = [:]
    func respond(messages: [[String: Any]], model: String, key: String, tools: [[String: Any]]) async throws -> AgentReply {
        try await stream(messages: messages, model: model, key: key, tools: tools) { _ in }
    }
    func stream(messages: [[String: Any]], model: String, key: String, tools: [[String: Any]], onText: @escaping @MainActor (String) -> Void) async throws -> AgentReply {
        let index = count; count += 1; callbacks.append(onText)
        return try await withCheckedThrowingContinuation { continuations[index] = $0 }
    }
    func emit(_ text: String, at index: Int = 0) { callbacks[index](text) }
    func complete(_ reply: AgentReply, at index: Int = 0) { continuations.removeValue(forKey: index)?.resume(returning: reply) }
    func fail(_ error: Error, at index: Int = 0) { continuations.removeValue(forKey: index)?.resume(throwing: error) }
}

@MainActor private final class ProgressFixtureSpeech: SpeechOutput {
    private(set) var count = 0
    private var callbacks: [@MainActor (SpeechOutputState) -> Void] = []
    private var continuations: [Int: CheckedContinuation<Void, Error>] = [:]
    func speak(_ text: String, key: String, onState: @escaping @MainActor (SpeechOutputState) -> Void) async throws {
        let index = count; count += 1; callbacks.append(onState)
        onState(.preparing)
        try await withCheckedThrowingContinuation { continuations[index] = $0 }
    }
    func emit(_ state: SpeechOutputState, at index: Int = 0) { callbacks[index](state) }
    func complete(at index: Int = 0) { continuations.removeValue(forKey: index)?.resume() }
    func fail(_ error: Error, at index: Int = 0) { continuations.removeValue(forKey: index)?.resume(throwing: error) }
    func stop() {}
}

@MainActor private final class ProgressFixtureSearch: WebSearching {
    private(set) var count = 0
    private var continuation: CheckedContinuation<WebSearchResult, Error>?
    func search(_ query: String, key: String) async throws -> WebSearchResult {
        count += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func complete() {
        let reply = WebSearchResult(summary: "Fixture fact.", sources: [AgentSource(title: "Fixture", url: URL(string: "https://example.com")!)])
        continuation?.resume(returning: reply); continuation = nil
    }
}

extension CoreTests {
    @MainActor static func requestProgressChecks() async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        func at(_ offset: TimeInterval) -> Date { start.addingTimeInterval(offset) }
        var snapshot = RequestProgress(at: start)
        check(snapshot.kind == .thinking && snapshot.isActive && snapshot.finishedAt == nil, "Progress begins with an observed active stage")
        check(snapshot.requestStartedAt == start && snapshot.stageStartedAt == start && snapshot.lastActivityAt == start, "Initial timestamps share the real request start")
        check(snapshot.elapsed(at: at(11)) == 11 && snapshot.stageElapsed(at: at(11)) == 11, "Total and stage clocks advance from timestamps")
        check(!snapshot.isWaitingForData(at: at(11.999)) && snapshot.isWaitingForData(at: at(12)), "Network waiting begins at exactly twelve seconds without activity")
        let beforeRead = snapshot
        _ = snapshot.elapsed(at: at(500)); _ = snapshot.isWaitingForData(at: at(500))
        check(snapshot == beforeRead, "Timeline rendering never mutates progress or manufactures an event")
        snapshot.record(.thinking, at: at(4))
        check(snapshot.stageStartedAt == start && snapshot.lastActivityAt == at(4), "Real activity refreshes the wait clock without restarting a stage")
        check(!snapshot.isWaitingForData(at: at(15)) && snapshot.isWaitingForData(at: at(16)), "Fresh data resets the stale-data threshold")
        snapshot.record(.searching, at: at(20))
        check(snapshot.requestStartedAt == start && snapshot.stageStartedAt == at(20), "A search transition preserves total request time")
        snapshot.record(.searching, at: at(25))
        check(snapshot.stageElapsed(at: at(30)) == 10 && snapshot.secondsSinceActivity(at: at(30)) == 5, "Stage time and time since data remain separate")
        snapshot.record(.replying, at: at(35))
        check(snapshot.elapsed(at: at(36)) == 36 && snapshot.stageElapsed(at: at(36)) == 1, "An internal follow-up keeps full-request elapsed time")
        snapshot.record(.speaking, at: at(40))
        snapshot.record(.speaking, at: at(45))
        check(snapshot.stageStartedAt == at(40) && !snapshot.isWaitingForData(at: at(100)), "Audible speech never displays a network-stall warning")
        snapshot.record(.preparingVoice, at: at(50))
        check(snapshot.isWaitingForData(at: at(62)), "Cloud voice preparation can report a real wait for data")
        snapshot.record(.reviewing, at: at(65))
        check(!snapshot.isWaitingForData(at: at(1_000)), "Waiting for user review never becomes a false network stall")
        snapshot.record(.running, at: at(70))
        check(!snapshot.isWaitingForData(at: at(1_000)), "A quiet terminal command is not labelled a stalled network request")
        snapshot.record(.complete, at: at(90))
        check(!snapshot.isActive && snapshot.finishedAt == at(90) && snapshot.elapsed(at: at(500)) == 90, "Completed elapsed time freezes at the actual finish")
        let completed = snapshot
        snapshot.record(.replying, at: at(100))
        check(snapshot == completed, "Late events cannot reopen a finished progress snapshot")
        for terminal in [RequestProgress.Kind.stopped, .failed] {
            var progress = RequestProgress(at: start)
            progress.record(terminal, at: at(8))
            check(!progress.isActive && progress.elapsed(at: at(1_000)) == 8 && !progress.isWaitingForData(at: at(1_000)), "\(terminal.title) freezes time and clears network waiting")
        }
        var clockChange = RequestProgress(at: start)
        clockChange.record(.replying, at: at(10)); clockChange.record(.replying, at: at(5))
        check(clockChange.lastActivityAt == at(10), "A backward wall-clock correction does not move activity backwards")
        check(clockChange.elapsed(at: at(-1)) == 0 && clockChange.secondsSinceActivity(at: at(-1)) == 0, "Clock corrections never render negative elapsed values")

        let suite = "quick-dictate-request-progress-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = FeatureSettings(defaults: defaults)
        try settings.update { $0.askEnabled = true; $0.actEnabled = true; $0.terminalEnabled = true; $0.workRoot = FileManager.default.temporaryDirectory.path }
        let clock = ProgressFixtureClock()
        let client = ProgressFixtureClient()
        let speech = ProgressFixtureSpeech()
        let search = ProgressFixtureSearch()
        var actionOutput: (@Sendable (String) -> Void)?
        var actionReply: CheckedContinuation<LocalActionResult, Error>?
        let session = AgentSession(settings: settings, client: client, loadKey: { "fixture-key" }, executeAction: { _, _, _, output in
            actionOutput = output
            return try await withCheckedThrowingContinuation { actionReply = $0 }
        }, speech: speech, search: search, now: { clock.date })
        defer { session.cancel() }
        func waitFor(_ label: String, _ condition: () -> Bool) async {
            for _ in 0..<2_000 {
                if condition() { check(true, label); return }
                await Task.yield()
            }
            check(false, "Request progress did not reach: \(label)")
        }
        func reply(_ text: String, calls: [AgentToolCall] = []) -> AgentReply {
            var message: [String: Any] = ["role": "assistant", "content": text]
            if !calls.isEmpty { message["tool_calls"] = calls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.argumentsJSONString]] } }
            return AgentReply(text: text, toolCalls: calls, assistantMessage: message)
        }
        func call(_ id: String, _ name: String, _ arguments: [String: Any]) throws -> AgentToolCall {
            AgentToolCall(id: id, name: name, argumentsJSONString: String(data: try JSONSerialization.data(withJSONObject: arguments), encoding: .utf8)!, arguments: arguments)
        }

        check(session.progress == nil, "Idle sessions do not show a phantom request timer")
        session.send("Fixture search", mode: .ask)
        await waitFor("Initial request is scheduled", { client.count == 1 })
        check(session.progress?.requestStartedAt == start && session.progress?.kind == .thinking, "Production session starts progress from its injected clock")
        clock.set(13)
        check(session.progress?.isWaitingForData(at: clock.date) == true, "A model with no first token exposes a real data wait")
        client.complete(reply("", calls: [try call("s1", "web_search", ["query": "public fixture"])]))
        await waitFor("Search starts", { search.count == 1 && session.state == .searching })
        check(session.progress?.kind == .searching && session.progress?.stageStartedAt == at(13), "Actual search call records its stage start")
        clock.set(19); search.complete()
        await waitFor("Search follow-up is scheduled", { client.count == 2 })
        check(session.progress?.kind == .thinking && session.progress?.requestStartedAt == start && session.progress?.stageStartedAt == at(19), "Follow-up resets stage time but preserves the entire request timer")
        check(session.activityDetail == AgentModel.presets.first(where: { $0.id == settings.options.model })?.detail,
              "Internal follow-up restores model-wait detail instead of leaving the previous source count")
        clock.set(22); client.emit("A fixture answer", at: 1)
        check(session.progress?.kind == .replying && session.progress?.lastActivityAt == at(22), "Visible model deltas record real activity")
        clock.set(24); client.emit(" arrives.", at: 1)
        check(session.progress?.stageStartedAt == at(22) && session.progress?.lastActivityAt == at(24), "Later deltas do not restart the reply-stage timer")
        clock.set(27); client.complete(reply("A fixture answer arrives."), at: 1)
        await waitFor("Text-only request completes", { session.progress?.kind == .complete })
        check(session.progress?.elapsed(at: at(200)) == 27, "Full elapsed includes model, search and follow-up rather than only the final round")

        clock.set(30); session.replayLast()
        await waitFor("Replay prepares its own speech", { speech.count == 1 })
        check(session.progress?.requestStartedAt == at(30) && session.progress?.kind == .preparingVoice, "Explicit replay gets an independent preparation timer")
        clock.set(34); speech.emit(.speaking)
        check(session.progress?.kind == .speaking && session.progress?.stageStartedAt == at(34), "Actual playback callback starts the speaking stage")
        clock.set(39); speech.complete()
        await waitFor("Replay completes only after speech ends", { session.progress?.kind == .complete })
        check(session.progress?.elapsed(at: at(200)) == 9, "Replay elapsed measures its own preparation and playback")

        clock.set(40); session.send("Streamed voice fixture", mode: .ask, spoken: true)
        await waitFor("Streamed voice request starts", { client.count == 3 })
        clock.set(43); client.emit("This is a full sentence long enough to start speaking. ", at: 2)
        await waitFor("Voice preparation overlaps generation", { speech.count == 2 })
        check(session.progress?.kind == .replying, "Preparing audio does not hide continuing reply generation")
        clock.set(45); speech.emit(.speaking, at: 1)
        clock.set(46); client.emit("A final phrase", at: 2)
        check(session.progress?.kind == .speaking && session.progress?.stageStartedAt == at(45) && session.progress?.lastActivityAt == at(46),
              "More model text refreshes activity without replacing the audible speech stage")
        clock.set(48); speech.complete(at: 1)
        await waitFor("Audio completes while model is still replying", { session.speechState == .idle })
        check(session.progress?.kind == .replying && session.progress?.isActive == true, "Audio idle cannot finish an in-flight assistant request")
        clock.set(50); client.complete(reply("This is a full sentence long enough to start speaking. A final phrase"), at: 2)
        await waitFor("Final voice remainder starts preparing", { speech.count == 3 })
        check(session.state == .idle && session.progress?.kind == .preparingVoice && session.progress?.isActive == true,
              "Model completion cannot finish a request with remaining audio")
        clock.set(52); speech.emit(.speaking, at: 2)
        clock.set(56); speech.complete(at: 2)
        await waitFor("Both model and audio finish", { session.progress?.kind == .complete })
        check(session.progress?.elapsed(at: at(300)) == 16, "Spoken-request total time ends after the last audio chunk")

        clock.set(60); session.send("Reviewed action fixture", mode: .act)
        await waitFor("Action request starts", { client.count == 4 })
        clock.set(62); client.complete(reply("", calls: [try call("a1", "run_terminal", ["command": "printf fixture"])]), at: 3)
        await waitFor("Action waits for review", { session.state == .reviewing })
        check(session.progress?.kind == .reviewing && session.progress?.isWaitingForData(at: at(200)) == false, "Review stays active without a false stale-data alert")
        clock.set(70); session.approveNext()
        await waitFor("Reviewed action starts executing", { actionOutput != nil })
        check(session.progress?.kind == .running && session.progress?.stageStartedAt == at(70), "Run click starts the actual action stage")
        clock.set(75); actionOutput?("fixture output")
        await waitFor("Actual tool output updates its activity timestamp", { session.progress?.lastActivityAt == at(75) })
        clock.set(76); actionReply?.resume(returning: LocalActionResult(output: "fixture output", exitCode: 0, timedOut: false, cancelled: false, truncated: false)); actionReply = nil
        await waitFor("Action follow-up starts", { client.count == 5 })
        check(session.progress?.requestStartedAt == at(60) && session.progress?.kind == .thinking, "Action follow-up retains the original start through review and execution")
        clock.set(78); client.complete(reply("Action complete."), at: 4)
        await waitFor("Action request completes", { session.progress?.kind == .complete })

        clock.set(80); session.send("Cancellation fixture", mode: .ask)
        await waitFor("Cancellable progress begins", { client.count == 6 })
        clock.set(83); session.cancel()
        let stopped = session.progress
        check(stopped?.kind == .stopped && stopped?.elapsed(at: at(200)) == 3, "User cancellation freezes progress as stopped")
        clock.set(90); client.emit("Late token", at: 5); client.complete(reply("Late answer."), at: 5)
        for _ in 0..<20 { await Task.yield() }
        check(session.progress == stopped, "Cancelled generation callbacks cannot change finished progress")

        clock.set(100); session.send("Failure fixture", mode: .ask)
        await waitFor("Failing request begins", { client.count == 7 })
        clock.set(104); client.fail(AgentClientError.timeout, at: 6)
        await waitFor("Transport error finishes progress", { session.progress?.kind == .failed })
        check(session.progress?.elapsed(at: at(200)) == 4 && session.state == .idle, "Error progress freezes while leaving the session usable")
        clock.set(120); session.send("Stop while the model is still replying", mode: .ask, spoken: true)
        await waitFor("Voice request for partial-audio stop begins", { client.count == 8 })
        clock.set(122); client.emit("A complete spoken sentence while more words are coming. ", at: 7)
        await waitFor("Partial streamed speech starts preparing", { speech.count == 4 })
        clock.set(124); speech.emit(.speaking, at: 3)
        clock.set(126); speech.complete(at: 3)
        await waitFor("Partial speech finishes before model completion", { session.speechState == .idle && session.state == .replying })
        check(session.progress?.kind == .replying && session.progress?.isActive == true,
              "Finished partial audio leaves the model's request active")
        clock.set(130); session.cancel()
        let interruptedStream = session.progress
        check(interruptedStream?.kind == .stopped && interruptedStream?.elapsed(at: at(200)) == 10,
              "Stop after partial speech ends still stops the unfinished model request")
        clock.set(135); client.emit("Late ending", at: 7); client.complete(reply("Late complete answer."), at: 7)
        for _ in 0..<20 { await Task.yield() }
        check(session.progress == interruptedStream, "Late model data cannot turn a partial-speech stop into completion")

        session.newChat()
        check(session.progress == nil, "New chat clears the old progress snapshot")
    }
}
