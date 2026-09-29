import Foundation

@MainActor private final class VoiceFlowStreamingClient: AgentStreaming {
    struct Request { let messages: [[String: Any]]; let tools: [[String: Any]]; let model: String }
    private(set) var requests: [Request] = []
    private var callbacks: [@MainActor (String) -> Void] = []
    private var replies: [Int: CheckedContinuation<AgentReply, Error>] = [:]
    func respond(messages: [[String: Any]], model: String, key: String, tools: [[String: Any]]) async throws -> AgentReply {
        try await stream(messages: messages, model: model, key: key, tools: tools) { _ in }
    }
    func stream(messages: [[String: Any]], model: String, key: String, tools: [[String: Any]],
                onText: @escaping @MainActor (String) -> Void) async throws -> AgentReply {
        let index = requests.count
        requests.append(Request(messages: messages, tools: tools, model: model))
        callbacks.append(onText)
        // Deliberately ignores cancellation until completed by the test, to
        // exercise the production session's generation guards.
        return try await withCheckedThrowingContinuation { replies[index] = $0 }
    }
    func emit(_ text: String, at index: Int = 0) { callbacks[index](text) }
    func complete(_ reply: AgentReply, at index: Int = 0) { replies.removeValue(forKey: index)?.resume(returning: reply) }
    func fail(_ error: Error, at index: Int = 0) { replies.removeValue(forKey: index)?.resume(throwing: error) }
}

@MainActor private final class VoiceFlowSpeech: SpeechOutput {
    private(set) var texts: [String] = []
    private(set) var stopCount = 0
    private(set) var prefetched: [String] = []
    private(set) var prefetchStates: [SpeechOutputState] = []
    private var currentState: SpeechOutputState = .idle
    private var callbacks: [@MainActor (SpeechOutputState) -> Void] = []
    private var replies: [Int: CheckedContinuation<Void, Error>] = [:]
    var automatic = true
    var nextError: Error?
    func speak(_ text: String, key: String, onState: @escaping @MainActor (SpeechOutputState) -> Void) async throws {
        let index = texts.count
        texts.append(text); callbacks.append(onState)
        currentState = .preparing; onState(.preparing)
        if let error = nextError { nextError = nil; throw error }
        currentState = .speaking; onState(.speaking)
        if !automatic { try await withCheckedThrowingContinuation { replies[index] = $0 } }
        currentState = .idle; onState(.idle)
    }
    func prefetch(_ text: String, key: String) { prefetched.append(text); prefetchStates.append(currentState) }
    func stop() { stopCount += 1; currentState = .idle }
    func emit(_ state: SpeechOutputState, at index: Int = 0) { callbacks[index](state) }
    func complete(at index: Int = 0) { replies.removeValue(forKey: index)?.resume() }
}

@MainActor private final class VoiceFlowSearch: WebSearching {
    private(set) var queries: [String] = []
    private var replies: [Int: CheckedContinuation<WebSearchResult, Error>] = [:]
    var automatic: WebSearchResult?
    func search(_ query: String, key: String) async throws -> WebSearchResult {
        let index = queries.count
        queries.append(query)
        if let automatic { return automatic }
        return try await withCheckedThrowingContinuation { replies[index] = $0 }
    }
    func complete(_ result: WebSearchResult, at index: Int = 0) { replies.removeValue(forKey: index)?.resume(returning: result) }
    func fail(_ error: Error, at index: Int = 0) { replies.removeValue(forKey: index)?.resume(throwing: error) }
}

@MainActor private final class VoiceFlowFixture {
    let suite = "quick-dictate-voice-flow-\(UUID().uuidString)"
    let defaults: UserDefaults
    let settings: FeatureSettings
    let client = VoiceFlowStreamingClient()
    let speech = VoiceFlowSpeech()
    let search = VoiceFlowSearch()
    private(set) var actions = 0
    lazy var session = AgentSession(settings: settings, client: client, loadKey: { "fixture-only-key" }, executeAction: { [weak self] _, _, _, _ in
        self?.actions += 1
        return LocalActionResult(output: "fixture action", exitCode: 0, timedOut: false, cancelled: false, truncated: false)
    }, speech: speech, search: search)
    init() throws {
        defaults = UserDefaults(suiteName: suite)!
        settings = FeatureSettings(defaults: defaults)
        try settings.update { $0.askEnabled = true; $0.workRoot = FileManager.default.temporaryDirectory.path }
    }
    func cleanup() { session.cancel(); defaults.removePersistentDomain(forName: suite) }
}

extension CoreTests {
    @MainActor static func voiceFlowChecks() async throws {
        func answer(_ text: String = "A concise fixture answer.", calls: [AgentToolCall] = []) -> AgentReply {
            var message: [String: Any] = ["role": "assistant", "content": text]
            if !calls.isEmpty {
                message["tool_calls"] = calls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.argumentsJSONString]] }
            }
            return AgentReply(text: text, toolCalls: calls, assistantMessage: message)
        }
        func searchCall(_ id: String, _ query: String, extra: [String: Any] = [:]) throws -> AgentToolCall {
            var arguments: [String: Any] = ["query": query]
            for (key, value) in extra { arguments[key] = value }
            let json = String(data: try JSONSerialization.data(withJSONObject: arguments), encoding: .utf8)!
            return AgentToolCall(id: id, name: "web_search", argumentsJSONString: json, arguments: arguments)
        }
        func waitFor(_ description: String, _ predicate: () -> Bool) async {
            for _ in 0..<200 {
                if predicate() { check(true, description); return }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            check(false, "Voice flow timed out: \(description)")
        }
        func settle() async { for _ in 0..<5 { await Task.yield() } }
        func toolNames(_ request: VoiceFlowStreamingClient.Request) -> Set<String> {
            Set(request.tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
        }
        func toolResults(_ request: VoiceFlowStreamingClient.Request) -> [[String: Any]] {
            request.messages.filter { $0["role"] as? String == "tool" }
        }
        func systemPrompt(_ request: VoiceFlowStreamingClient.Request) -> String {
            request.messages.first?["content"] as? String ?? ""
        }
        let sentence = "This is a complete first sentence long enough to speak."
        let second = "Here is another full sentence that must wait its turn."
        let remainder = "This final phrase has no ending punctuation"
        let source = AgentSource(title: "Fixture source", url: URL(string: "https://example.com/fixture")!)
        let result = WebSearchResult(summary: "Verified fixture fact. [Fixture source](https://example.com/fixture)", sources: [source])

        do {
            let f = try VoiceFlowFixture(); defer { f.cleanup() }
            check(f.settings.options.speakReplies, "Voice flow starts with the requested spoken-reply default")
            check(f.session.send("Typed question", mode: .ask), "Typed question is accepted")
            await waitFor("Typed request reaches the fake assistant", { f.client.requests.count == 1 })
            f.client.emit(sentence + " ")
            f.client.complete(answer(sentence))
            await waitFor("Typed answer finishes", { f.session.state == .idle })
            await settle()
            check(f.speech.texts.isEmpty, "Typed requests stay silent even when voice replies are enabled")
            check(f.session.turns.last?.text == sentence, "Typed answer remains visible")
            check(f.client.requests[0].model == FeatureOptions.defaultAssistantModel, "Voice pipeline uses the selected Luna model")
            f.session.replayLast()
            await waitFor("Explicit Speak plays the typed answer", { f.speech.texts.count == 1 && f.session.speechState == .idle })
            check(f.speech.texts[0] == SpokenText.clean(sentence), "Explicit replay speaks only the last answer text")
            check(f.client.requests.count == 1 && f.search.queries.isEmpty && f.actions == 0, "Speak replay never repeats chat, search or local actions")
        }
        do {
            let f = try VoiceFlowFixture(); defer { f.cleanup() }
            check(f.session.send("Spoken question", mode: .ask, spoken: true), "Spoken request is accepted")
            await waitFor("Spoken request starts", { f.client.requests.count == 1 })
            f.client.complete(answer("A short spoken answer."))
            await waitFor("Spoken answer automatically reaches TTS", { f.speech.texts.count == 1 && f.session.speechState == .idle })
            check(f.speech.texts == ["A short spoken answer."], "Voice requests automatically speak the final answer")
        }
        do {
            let f = try VoiceFlowFixture(); defer { f.cleanup() }
            try f.settings.update { $0.speakReplies = false }
            f.session.send("Silent voice request", mode: .ask, spoken: true)
            await waitFor("Opted-out voice request starts", { f.client.requests.count == 1 })
            f.client.emit(sentence)
            f.client.complete(answer(sentence))
            await waitFor("Opted-out answer finishes", { f.session.state == .idle })
            await settle()
            check(f.speech.texts.isEmpty, "Turning spoken replies off suppresses both streamed and final TTS")
        }
        do {
            let f = try VoiceFlowFixture(); defer { f.cleanup() }
            f.session.send("Stream a voice answer", mode: .ask, spoken: true)
            await waitFor("Streaming voice request starts", { f.client.requests.count == 1 })
            f.client.emit(sentence + " ")
            await waitFor("First completed sentence reaches TTS before final answer", { f.speech.texts.count == 1 })
            check(f.session.state == .replying && f.session.streamingText == sentence + " ", "Visible streaming and speech begin while the model is still replying")
            f.client.emit(remainder)
            await settle()
            check(f.speech.texts.count == 1, "An unfinished phrase waits for completion instead of speaking partial words")
            f.client.complete(answer(sentence + " " + remainder))
            await waitFor("Final remainder is spoken", { f.speech.texts.count == 2 && f.session.speechState == .idle })
            check(f.speech.texts == [sentence, remainder], "Final flush speaks only the unsaid remainder without duplicate words")
            check(f.session.streamingText.isEmpty && f.session.turns.last?.text == sentence + " " + remainder, "Final answer replaces the transient streaming text")
        }
        do {
            let f = try VoiceFlowFixture(); defer { f.cleanup() }
            f.speech.automatic = false
            f.session.send("Queue a voice answer", mode: .ask, spoken: true)
            await waitFor("Queued voice request starts", { f.client.requests.count == 1 })
            f.client.emit(sentence + " ")
            await waitFor("First speech chunk is playing", { f.speech.texts.count == 1 && f.session.speechState == .speaking })
            f.client.emit(second)
            f.client.complete(answer(sentence + " " + second))
            await waitFor("Answer finishes while speech is still playing", { f.session.state == .idle })
            f.session.stopSpeaking()
            check(f.session.speechState == .idle && f.speech.stopCount > 0, "Stopping speech clears its visible state immediately")
            f.speech.emit(.speaking, at: 0)
            check(f.session.speechState == .idle, "A stale speech callback cannot restart the stopped state")
            f.speech.complete(at: 0)
            await settle()
            check(f.speech.texts.count == 1, "Stopping speech discards queued remaining sentences")

            f.session.send("A new voice request", mode: .ask, spoken: true)
            await waitFor("New voice generation starts", { f.client.requests.count == 2 })
            f.client.complete(answer("The new generation's answer."), at: 1)
            await waitFor("New generation is speaking", { f.speech.texts.count == 2 && f.session.speechState == .speaking })
            f.speech.emit(.idle, at: 0)
            check(f.session.speechState == .speaking, "An old idle callback cannot clear a newer speaking state")
            f.speech.complete(at: 1)
            await waitFor("New speech generation completes", { f.session.speechState == .idle })
        }
        do {
            let f = try VoiceFlowFixture(); defer { f.cleanup() }
            f.speech.automatic = false
            f.session.send("Prefetch the next sentence", mode: .ask, spoken: true)
            await waitFor("Prefetch voice request starts", { f.client.requests.count == 1 })
            f.client.emit(sentence + " ")
            await waitFor("Current sentence begins playback", { f.speech.texts.count == 1 && f.session.speechState == .speaking })
            f.client.emit(second)
            f.client.complete(answer(sentence + " " + second))
            await waitFor("Next sentence is prefetched during current playback", { f.speech.prefetched.contains(second) })
            check(f.speech.prefetchStates.contains(.speaking), "Queued sentence synthesis can begin while the current sentence is speaking")
            check(f.speech.texts == [sentence], "Prefetch does not start overlapping playback of the next sentence")
            f.speech.complete(at: 0)
            await waitFor("Next sentence speaks only after the previous one finishes", { f.speech.texts.count == 2 })
            check(f.speech.texts == [sentence, second], "Prefetch preserves sentence order without duplicating playback")
            f.speech.complete(at: 1)
            await waitFor("Prefetched reply finishes cleanly", { f.session.speechState == .idle })
        }
        do {
            let f = try VoiceFlowFixture(); defer { f.cleanup() }
            let longAnswer = (0..<700).map { String(format: "word%04d", $0) }.joined(separator: " ") + " finalending"
            check(longAnswer.count > 2400 && !longAnswer.contains("."), "Long-answer fixture exceeds one utterance without sentence boundaries")
            f.session.send("Read a long answer", mode: .ask, spoken: true)
            await waitFor("Long spoken reply starts", { f.client.requests.count == 1 })
            f.client.emit(longAnswer)
            f.client.complete(answer(longAnswer))
            await waitFor("All long-answer chunks finish", { f.session.state == .idle && f.session.speechState == .idle && f.speech.texts.count > 1 })
            let firstPlayback = f.speech.texts
            check(firstPlayback.allSatisfy { !$0.isEmpty && $0.count <= 2400 }, "Every spoken chunk stays inside the utterance size limit")
            check(firstPlayback.joined(separator: " ") == longAnswer && firstPlayback.last?.hasSuffix("finalending") == true,
                  "Punctuation-free spoken answers retain every word and the final ending")
            check(f.speech.prefetchStates.contains(.preparing), "Already-queued long-answer chunks prefetch as current speech prepares")
            f.session.replayLast()
            await waitFor("Long-answer replay completes all chunks", { f.speech.texts.count == firstPlayback.count * 2 && f.session.speechState == .idle })
            let replayed = Array(f.speech.texts.dropFirst(firstPlayback.count))
            check(replayed.joined(separator: " ") == longAnswer && replayed == firstPlayback,
                  "Long replay preserves the entire answer instead of truncating after 2400 characters")
            check(f.client.requests.count == 1 && f.actions == 0 && f.search.queries.isEmpty, "Long replay still performs TTS only")
        }
        do {
            let f = try VoiceFlowFixture(); defer { f.cleanup() }
            f.session.send("Old request", mode: .ask, spoken: true)
            await waitFor("Old generation starts", { f.client.requests.count == 1 })
            f.session.cancel()
            f.session.send("Current request", mode: .ask, spoken: true)
            await waitFor("Replacement generation starts", { f.client.requests.count == 2 })
            f.client.emit(sentence, at: 0)
            f.client.complete(answer("Late old answer."), at: 0)
            await settle()
            check(f.session.streamingText.isEmpty && f.speech.texts.isEmpty, "Late deltas from cancelled generation cannot render or speak")
            f.client.complete(answer("Current answer."), at: 1)
            await waitFor("Current answer completes", { f.speech.texts == ["Current answer."] && f.session.state == .idle })
            check(!f.session.turns.contains { $0.text == "Late old answer." }, "Cancelled generation never adds its stale final answer")
        }
        do {
            let f = try VoiceFlowFixture(); defer { f.cleanup() }
            f.session.send("Answer still in flight", mode: .ask, spoken: true)
            await waitFor("In-flight request starts before microphone transition", { f.client.requests.count == 1 })
            f.session.stopSpeaking()
            f.client.emit(sentence)
            f.client.complete(answer(sentence))
            await waitFor("In-flight answer still arrives as text", { f.session.state == .idle })
            await settle()
            check(f.speech.texts.isEmpty && f.session.turns.last?.text == sentence, "Stopping speech before recording prevents the old response from autoplaying later")
        }
        do {
            let f = try VoiceFlowFixture(); defer { f.cleanup() }
            f.speech.nextError = CloudSpeechError.network
            f.session.send("Voice service failure", mode: .ask, spoken: true)
            await waitFor("Speech failure request starts", { f.client.requests.count == 1 })
            f.client.complete(answer("Keep this answer visible."))
            await waitFor("TTS error appears", { f.session.error.contains("Couldn't speak") })
            check(f.session.turns.last?.text == "Keep this answer visible." && f.session.state == .idle && f.session.speechState == .idle,
                  "A TTS failure preserves the completed answer and usable chat")
            f.session.replayLast()
            await waitFor("TTS replay recovers after failure", { f.speech.texts.count == 2 && f.session.speechState == .idle })
            check(f.client.requests.count == 1 && f.session.error.isEmpty, "Successful replay clears the speech error without resending the question")
        }
        do {
            let f = try VoiceFlowFixture(); defer { f.cleanup() }
            var presentations = 0
            f.session.onPresent = { presentations += 1 }
            f.session.send("Find a current public fact", mode: .ask)
            await waitFor("Search-capable request starts", { f.client.requests.count == 1 })
            check(presentations == 1, "A new user request presents the assistant once")
            check(toolNames(f.client.requests[0]) == ["web_search"], "Ask exposes read-only search without computer tools")
            check(systemPrompt(f.client.requests[0]).contains("Searches remaining for this user request: 2."), "Each new question starts with an explicit two-search allowance")
            f.client.complete(answer("", calls: [try searchCall("search-one", "fixture current fact")]))
            await waitFor("Real search service is invoked", { f.search.queries.count == 1 && f.session.state == .searching })
            check(f.session.activityDetail == "fixture current fact" && f.session.activityLog.contains { $0 == "Searching · fixture current fact" },
                  "Searching status reflects the actual query while retrieval is pending")
            f.search.complete(result)
            await waitFor("Search result reaches the next assistant turn", { f.client.requests.count == 2 })
            check(presentations == 1, "Internal search follow-up does not reopen or reposition the assistant window")
            let results = toolResults(f.client.requests[1])
            check(systemPrompt(f.client.requests[1]).contains("Searches remaining for this user request: 1."), "A completed search decrements the next model round's explicit allowance")
            check(results.count == 1 && results[0]["tool_call_id"] as? String == "search-one" && (results[0]["content"] as? String)?.contains("Verified fixture fact") == true,
                  "Actual retrieval output answers the original search tool call")
            f.client.complete(answer("Here is the sourced answer."), at: 1)
            await waitFor("Sourced final answer finishes", { f.session.state == .idle })
            check(f.session.turns.first(where: { $0.role == .search })?.sources == [source] && f.session.turns.last?.sources == [source],
                  "Search and final answer show the actual returned source links")
            check(f.actions == 0 && f.speech.texts.isEmpty, "Read-only search cannot trigger terminal actions or unwanted typed-answer speech")
            f.session.send("A second explicit user request", mode: .ask)
            await waitFor("Next user request starts", { f.client.requests.count == 3 })
            check(presentations == 2, "A later explicit user request can present the assistant again")
            f.client.complete(answer("The next answer."), at: 2)
            await waitFor("Next user answer finishes", { f.session.state == .idle })
        }
        do {
            let f = try VoiceFlowFixture(); defer { f.cleanup() }
            try f.settings.update { $0.webSearchEnabled = false }
            f.session.send("Search is off", mode: .ask)
            await waitFor("Search-disabled request starts", { f.client.requests.count == 1 })
            check(toolNames(f.client.requests[0]).isEmpty, "Disabled search is not advertised to the assistant")
            check(systemPrompt(f.client.requests[0]).contains("Web search is disabled.") && systemPrompt(f.client.requests[0]).contains("Searches remaining for this user request: 0."),
                  "Disabled search removes contradictory instructions to look facts up")
            f.client.complete(answer("", calls: [try searchCall("disabled-search", "must not run")]))
            await waitFor("Unadvertised search gets a blocked result", { f.client.requests.count == 2 })
            check(f.search.queries.isEmpty && (toolResults(f.client.requests[1]).first?["content"] as? String)?.contains("Search failed") == true,
                  "A model cannot bypass the search setting by returning an unsolicited call")
            f.client.complete(answer("Search is disabled."), at: 1)
            await waitFor("Blocked-search chat returns idle", { f.session.state == .idle })
        }
        do {
            let f = try VoiceFlowFixture(); defer { f.cleanup() }
            f.search.automatic = result
            f.session.send("A bounded search task", mode: .ask)
            await waitFor("Bounded search request starts", { f.client.requests.count == 1 })
            f.client.complete(answer("", calls: [try searchCall("s1", "one"), try searchCall("s2", "two"), try searchCall("s3", "three")]))
            await waitFor("Search budget is applied before follow-up", { f.client.requests.count == 2 })
            check(f.search.queries == ["one", "two"], "Only two actual searches can run per user request")
            check(!toolNames(f.client.requests[1]).contains("web_search"), "Exhausted search is removed from later tool declarations")
            check(systemPrompt(f.client.requests[1]).contains("Searches remaining for this user request: 0.") && systemPrompt(f.client.requests[1]).contains("Answer now using the search results already returned") && systemPrompt(f.client.requests[1]).contains("Do not call web_search again."),
                  "The exhausted round explicitly requires an answer from existing evidence with no more search calls")
            check(toolResults(f.client.requests[1]).count == 3, "Every search call gets exactly one result including a budget rejection")
            f.client.complete(answer("", calls: [try searchCall("s4", "four")]), at: 1)
            await waitFor("Later budget bypass is rejected", { f.client.requests.count == 3 })
            check(f.search.queries.count == 2, "A later model round cannot bypass the two-search limit")
            f.client.complete(answer("Bounded answer."), at: 2)
            await waitFor("Bounded task finishes", { f.session.state == .idle })
            f.session.send("Another independent question", mode: .ask)
            await waitFor("New question gets a fresh search allowance", { f.client.requests.count == 4 })
            check(toolNames(f.client.requests[3]).contains("web_search"), "Search budget resets for a new explicit user question")
            check(systemPrompt(f.client.requests[3]).contains("Searches remaining for this user request: 2."), "Conversation history does not exhaust a later question's search allowance")
            f.client.complete(answer("No search needed."), at: 3)
            await waitFor("New independent answer finishes", { f.session.state == .idle })
        }
        // Exercise the production SSE parser as well as AgentSession. A fake
        // AgentReply alone bypasses the advertised-tool validation boundary.
        for unexpectedFinalCall in [false, true] {
            let suite = "quick-dictate-search-budget-wire-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = FeatureSettings(defaults: defaults)
            try settings.update { $0.askEnabled = true }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [AgentMockProtocol.self]
            let transport = URLSession(configuration: config)
            defer { transport.invalidateAndCancel() }
            let speech = VoiceFlowSpeech()
            let search = VoiceFlowSearch(); search.automatic = result
            var requests = 0
            AgentMockProtocol.handler = { request in
                let round = requests; requests += 1
                let body = try AgentMockProtocol.body(request)
                let sent = body["messages"] as! [[String: Any]]
                let prompt = sent[0]["content"] as! String
                check(prompt.contains("Searches remaining for this user request: \(max(0, 2 - round))."),
                      "Production streamed search round carries its actual remaining budget")
                check(body["stream"] as? Bool == true, "Search integration uses the production streaming request")
                check(sent.filter { $0["role"] as? String == "tool" }.count == round,
                      "Production search follow-up retains one result per completed search")
                if round < 2 {
                    check(body["tool_choice"] as? String == "auto" && (body["tools"] as? [[String: Any]])?.count == 1,
                          "Remaining searches are callable through the transport")
                } else {
                    check(body["tool_choice"] as? String == "none" && body["tools"] == nil,
                          "The exhausted streamed round explicitly disables every new call")
                    check(prompt.contains("Answer now using the search results already returned"),
                          "The exhausted streamed round asks for the final evidence-based answer")
                }
                let usesCall = round < 2 || unexpectedFinalCall
                let delta: [String: Any]
                if usesCall {
                    delta = ["tool_calls": [["index": 0, "id": "budget-\(round)", "type": "function",
                        "function": ["name": "web_search", "arguments": "{\"query\":\"public fixture \(round)\"}"]]]]
                } else { delta = ["content": "Both fixture facts are verified."] }
                let event: [String: Any] = ["choices": [["index": 0, "delta": delta, "finish_reason": usesCall ? "tool_calls" : "stop"]]]
                let payload = String(data: try JSONSerialization.data(withJSONObject: event), encoding: .utf8)!
                return (200, Data("data: \(payload)\n\ndata: [DONE]\n\n".utf8))
            }
            let session = AgentSession(settings: settings, client: AgentClient(session: transport), loadKey: { "fixture-key" },
                                       executeAction: { _, _, _, _ in
                                           check(false, "Search wire integration must never execute a local action")
                                           throw DictationError(message: "No local execution")
                                       }, speech: speech, search: search)
            defer { session.cancel() }
            session.send("Look up two public fixture facts separately", mode: .ask)
            await waitFor("Production two-search stream reaches its final state", { !session.isBusy })
            check(requests == 3 && search.queries == ["public fixture 0", "public fixture 1"],
                  "Exactly two real search-service calls and three model rounds complete")
            check(speech.texts.isEmpty && session.pending.isEmpty, "Typed search integration neither speaks nor proposes local actions")
            if unexpectedFinalCall {
                check(session.error.contains("invalid action") && session.progress?.kind == .failed,
                      "A provider that ignores tool_choice still cannot bypass strict call validation")
                check(session.activityLog.last?.hasPrefix("Request failed · ") == true && session.activityDetail == session.error,
                      "Actual provider validation failure is visible in the activity history")
            } else {
                check(session.error.isEmpty && session.turns.last?.text == "Both fixture facts are verified." && session.progress?.kind == .complete,
                      "Production session completes the answer after exhausting two searches")
            }
        }
        do {
            let f = try VoiceFlowFixture(); defer { f.cleanup() }
            f.session.send("Reject malformed search", mode: .ask)
            await waitFor("Malformed search fixture starts", { f.client.requests.count == 1 })
            f.client.complete(answer("", calls: [try searchCall("bad-search", "public fact", extra: ["command": "arbitrary command", "upload": "private fixture"])]))
            await waitFor("Malformed search is answered as a failure", { f.client.requests.count == 2 })
            check(f.search.queries.isEmpty && f.actions == 0, "Unknown search arguments cannot trigger search or local execution")
            f.client.complete(answer("Those arguments were rejected."), at: 1)
            await waitFor("Malformed-search recovery finishes", { f.session.state == .idle })
        }
        do {
            let f = try VoiceFlowFixture(); defer { f.cleanup() }
            f.session.send("Cancel pending search", mode: .ask)
            await waitFor("Cancellable search request starts", { f.client.requests.count == 1 })
            f.client.complete(answer("", calls: [try searchCall("cancel-search", "cancelled public query")]))
            await waitFor("Search is pending before cancellation", { f.search.queries.count == 1 && f.session.state == .searching })
            f.session.cancel()
            f.search.complete(result)
            await settle()
            check(f.session.state == .idle && f.client.requests.count == 1 && !f.session.turns.contains { $0.role == .search },
                  "Cancelling a search ignores its late result and prevents a model follow-up")
            f.session.send("New question after cancellation", mode: .ask)
            await waitFor("Chat recovers after search cancellation", { f.client.requests.count == 2 })
            f.client.complete(answer("A fresh answer."), at: 1)
            await waitFor("Post-cancellation answer finishes", { f.session.state == .idle })
            check(f.session.turns.last?.sources.isEmpty == true, "Cancelled search sources do not leak into a later answer")
        }
    }
}
