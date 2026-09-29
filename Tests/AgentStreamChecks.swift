import Foundation

private final class SuspendedAgentStreamProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var stops = 0
    private var tail: DispatchWorkItem?
    static var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }
    static func reset() { lock.lock(); defer { lock.unlock() }; stops = 0 }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                             headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        let first = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"First.\"},\"finish_reason\":null}]}\n\n"
        client?.urlProtocol(self, didLoad: Data(first.utf8))
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let final = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\" Late.\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
            self.client?.urlProtocol(self, didLoad: Data(final.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        tail = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 1, execute: work)
    }
    override func stopLoading() {
        tail?.cancel(); tail = nil
        Self.lock.lock(); Self.stops += 1; Self.lock.unlock()
    }
}

extension CoreTests {
    @MainActor static func agentStreamChecks() async throws {
        func payload(_ delta: [String: Any], finish: String? = nil, usage: [String: Any]? = nil) throws -> String {
            var choice: [String: Any] = ["index": 0, "delta": delta, "finish_reason": finish ?? NSNull()]
            if finish == nil { choice["finish_reason"] = NSNull() }
            var body: [String: Any] = ["choices": [choice]]
            if let usage { body["usage"] = usage }
            return String(data: try JSONSerialization.data(withJSONObject: body, options: .sortedKeys), encoding: .utf8)!
        }
        func event(_ delta: [String: Any], finish: String? = nil, usage: [String: Any]? = nil) throws -> String {
            "data: \(try payload(delta, finish: finish, usage: usage))\n\n"
        }
        func decode(_ text: String, tools: Set<String> = []) throws -> (AgentReply, [String]) {
            var framing = AgentSSEDecoder()
            var stream = AgentStreamAssembler(allowedTools: tools)
            var fragments: [String] = []
            for byte in text.utf8 {
                if let data = try framing.feed(byte), let fragment = try stream.consume(data) { fragments.append(fragment) }
            }
            if let data = try framing.finish(), let fragment = try stream.consume(data) { fragments.append(fragment) }
            return (try stream.reply(), fragments)
        }
        func fail(_ expected: String, _ text: String, tools: Set<String> = []) async {
            await expectError(expected) { _ = try decode(text, tools: tools) }
        }
        func call(_ index: Any, id: String? = nil, name: String? = nil, arguments: String? = nil,
                  extra: [String: Any]? = nil) -> [String: Any] {
            var fields: [String: Any] = ["index": index]
            if let id { fields["id"] = id; fields["type"] = "function" }
            var function: [String: Any] = [:]
            if let name { function["name"] = name }
            if let arguments { function["arguments"] = arguments }
            if !function.isEmpty { fields["function"] = function }
            if let extra { fields["extra_content"] = extra }
            return fields
        }

        let plain = try event(["role": "assistant", "content": "Hello "]) + event(["content": "日本語 ☀️."])
            + event([:], finish: "stop") + event(["role": "assistant", "content": ""], finish: "stop", usage: ["cost": 0.00001]) + "data: [DONE]\n\n"
        let result = try decode(plain)
        check(result.0.text == "Hello 日本語 ☀️." && result.1 == ["Hello ", "日本語 ☀️."], "Streaming emits visible UTF-8 answer deltas as they arrive")
        check(result.0.usage?["cost"] as? Double == 0.00001, "Repeated terminal accounting frames preserve final usage")
        check(result.0.assistantMessage["content"] as? String == "Hello 日本語 ☀️.", "Streaming history preserves original content")
        check(result.0.toolCalls.isEmpty, "Ordinary streamed answers create no actions")
        for ending in ["\r\n", "\r", "\n"] {
            let transport = "\u{FEFF}: OPENROUTER PROCESSING\nevent: message\nid: unused\n\n" + plain
            let decoded = try decode(transport.replacingOccurrences(of: "\n", with: ending))
            check(decoded.0.text == result.0.text, "SSE supports comments, BOM and \(ending.debugDescription) line endings")
        }
        let multiPayload = try payload(["content": "Multi-line event."], finish: "stop")
        let multiline = "data: " + multiPayload.replacingOccurrences(of: "{\"choices\":", with: "{\"choices\":\ndata: ") + "\n\ndata: [DONE]"
        let multi = try decode(multiline)
        check(multi.0.text == "Multi-line event.", "Multi-line data fields and DONE without a final newline are accepted")
        let usageOnly = try event(["content": "Usage."], finish: "stop") + "data: {\"choices\":[],\"usage\":{\"total_tokens\":12}}\n\ndata: [DONE]\n\n"
        let counted = try decode(usageOnly)
        check(counted.0.usage?["total_tokens"] as? Int == 12, "Standard empty-choice usage frame is accepted")

        let hidden = try event(["reasoning": "private thought", "reasoning_details": [["index": 0, "id": "r0", "type": "reasoning.text", "format": "google-gemini-v1", "text": "reason ", "signature": NSNull()]]])
            + event(["reasoning_details": [["index": 0, "type": "reasoning.text", "text": "continued", "signature": "signed-"]]])
            + event(["reasoning_details": [["index": 0, "signature": "fixture"]], "content": "Visible answer."], finish: "stop")
            + "data: [DONE]\n\n"
        let hiddenResult = try decode(hidden)
        check(hiddenResult.1 == ["Visible answer."], "Reasoning text and signatures never reach visible-text callbacks")
        check(hiddenResult.0.assistantMessage["reasoning"] as? String == "private thought", "Hidden provider reasoning remains in request history")
        let reasoning = hiddenResult.0.assistantMessage["reasoning_details"] as! [[String: Any]]
        check(reasoning.count == 1 && reasoning[0]["text"] as? String == "reason continued", "Repeated reasoning indexes merge their text fragments")
        check(reasoning[0]["signature"] as? String == "signed-fixture" && reasoning[0]["format"] as? String == "google-gemini-v1", "Opaque Gemini signature fragments and metadata are preserved")
        let encrypted = try event(["reasoning_details": [["index": 0, "type": "reasoning.encrypted", "data": "abc"]]])
            + event(["reasoning_details": [["index": 0, "type": "reasoning.encrypted", "data": "def"]], "content": "Done."], finish: "stop") + "data: [DONE]\n\n"
        let encryptedReply = try decode(encrypted)
        check((encryptedReply.0.assistantMessage["reasoning_details"] as? [[String: Any]])?.first?["data"] as? String == "abcdef", "Encrypted reasoning chunks retain their exact byte sequence")

        let toolStream = try event(["tool_calls": [call(0, id: "first", name: "run_", arguments: "{\"command\":\"", extra: ["google": ["thought_signature": "fixture-signature"]])]])
            + event(["tool_calls": [call(0, name: "terminal", arguments: "printf ok\"}")]])
            + event([:], finish: "tool_calls") + "data: [DONE]\n\n"
        let toolResult = try decode(toolStream, tools: ["run_terminal"])
        check(toolResult.1.isEmpty && toolResult.0.toolCalls.count == 1, "Tool-call deltas are hidden and become proposals only after complete validation")
        check(toolResult.0.toolCalls[0].name == "run_terminal" && toolResult.0.toolCalls[0].arguments["command"] as? String == "printf ok", "Fragmented function name and JSON arguments reassemble correctly")
        let preservedCall = (toolResult.0.assistantMessage["tool_calls"] as! [[String: Any]])[0]
        check(((preservedCall["extra_content"] as? [String: Any])?["google"] as? [String: Any])?["thought_signature"] as? String == "fixture-signature", "Tool-level Gemini thought signatures survive streaming")
        check(preservedCall["index"] == nil, "Stream-only tool index is removed from the completed assistant message")
        let interleaved = try event(["tool_calls": [call(1, id: "second", name: "run_terminal", arguments: "{\"command\":\"b"), call(0, id: "first", name: "run_terminal", arguments: "{\"command\":\"a")]])
            + event(["tool_calls": [call(0, arguments: "\"}"), call(1, arguments: "\"}")]], finish: "tool_calls") + "data: [DONE]\n\n"
        let ordered = try decode(interleaved, tools: ["run_terminal"])
        check(ordered.0.toolCalls.map(\.id) == ["first", "second"], "Interleaved calls are returned in explicit index order")
        let refusal = try decode(event(["refusal": "I cannot help with that."], finish: "stop") + "data: [DONE]\n\n")
        check(refusal.0.text == "I cannot help with that." && refusal.1 == [refusal.0.text], "A refusal remains visible answer text")

        await fail("cut short", try event(["content": "Partial."], finish: "stop"))
        await fail("cut short", try event(["content": "Partial."]) + "data: [DONE]\n\n")
        await fail("cut short", try event(["content": "Partial."], finish: "length") + "data: [DONE]\n\n")
        await fail("rephrasing", try event([:], finish: "content_filter"))
        await fail("unreadable", "data: {bad-json}\n\n")
        await fail("unreadable", "data: {\"error\":{\"message\":\"must not escape\"},\"choices\":[]}\n\n")
        await fail("unreadable", try event(["role": "user", "content": "Spoofed."], finish: "stop"))
        await fail("unreadable", try event(["content": ["not", "a", "string"]], finish: "stop"))
        await fail("unreadable", try event(["content": "Done."], finish: "stop") + event(["content": "Unexpected later text."]) + "data: [DONE]\n\n")
        await fail("no answer", try event([:], finish: "stop") + "data: [DONE]\n\n")
        await fail("invalid action", try event([:], finish: "tool_calls") + "data: [DONE]\n\n")
        await fail("invalid action", toolStream, tools: [])
        let incompleteArguments = try event(["tool_calls": [call(0, id: "bad", name: "run_terminal", arguments: "{\"command\":")]], finish: "tool_calls") + "data: [DONE]\n\n"
        await fail("invalid action", incompleteArguments, tools: ["run_terminal"])
        let sparse = try event(["tool_calls": [call(1, id: "bad", name: "run_terminal", arguments: "{}")]], finish: "tool_calls") + "data: [DONE]\n\n"
        await fail("invalid action", sparse, tools: ["run_terminal"])
        let duplicates = try event(["tool_calls": [call(0, id: "same", name: "run_terminal", arguments: "{}"), call(0, id: "same", name: "run_terminal", arguments: "{}")]], finish: "tool_calls")
        await fail("invalid action", duplicates, tools: ["run_terminal"])
        let changingID = try event(["tool_calls": [call(0, id: "first", name: "run_terminal", arguments: "{")]])
            + event(["tool_calls": [call(0, id: "changed", arguments: "}")]], finish: "tool_calls")
        await fail("unreadable", changingID, tools: ["run_terminal"])
        for index: Any in [-1, 8, 0.5, true] {
            await fail("invalid action", try event(["tool_calls": [call(index, id: "bad", name: "run_terminal", arguments: "{}")]], finish: "tool_calls"), tools: ["run_terminal"])
        }
        await expectError("unreadable") {
            var framing = AgentSSEDecoder(maximumBytes: 32)
            for byte in String(repeating: ":", count: 33).utf8 { _ = try framing.feed(byte) }
        }
        await expectError("unreadable") {
            var framing = AgentSSEDecoder()
            for byte: UInt8 in [0xff, 10] { _ = try framing.feed(byte) }
        }

        // URLProtocol keeps the actual URLSession.bytes request path isolated
        // from credentials, the network and provider charges.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentMockProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = AgentClient(session: session)
        let messages: [[String: Any]] = [["role": "user", "content": "A streaming fixture."]]
        AgentMockProtocol.handler = { request in
            let body = try AgentMockProtocol.body(request)
            check(body["stream"] as? Bool == true, "Streaming request explicitly enables SSE")
            check((body["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true, "Streaming request asks for usage accounting")
            check(body["model"] as? String == AgentModel.defaultID && request.url == AgentClient.endpoint, "Streaming uses the same fixed endpoint and selected model")
            return (200, Data(plain.utf8))
        }
        var liveFragments: [String] = []
        let response = try await client.stream(messages: messages, model: AgentModel.defaultID, key: "fixture-key", tools: []) { liveFragments.append($0) }
        check(response.text == result.0.text && liveFragments == result.1, "Real async-byte transport delivers answer deltas and a completed reply")
        AgentMockProtocol.handler = { _ in (401, Data("private error must not be shown".utf8)) }
        await expectError("rejected the key") { _ = try await client.stream(messages: messages, model: AgentModel.defaultID, key: "fixture-key", tools: []) { _ in } }
        AgentMockProtocol.handler = { _ in throw URLError(.timedOut) }
        await expectError("too long") { _ = try await client.stream(messages: messages, model: AgentModel.defaultID, key: "fixture-key", tools: []) { _ in } }
        AgentMockProtocol.handler = { _ in throw URLError(.cancelled) }
        do {
            _ = try await client.stream(messages: messages, model: AgentModel.defaultID, key: "fixture-key", tools: []) { _ in }
            check(false, "Expected streaming cancellation")
        } catch { check(error is CancellationError, "Transport cancellation stays cancellation rather than an error reply") }
        AgentMockProtocol.handler = { _ in (200, Data("data: {\"error\":{\"message\":\"private-provider-payload\"},\"choices\":[]}\n\n".utf8)) }
        await expectError("unreadable") { _ = try await client.stream(messages: messages, model: AgentModel.defaultID, key: "fixture-key", tools: []) { _ in } }

        let pendingConfiguration = URLSessionConfiguration.ephemeral
        pendingConfiguration.protocolClasses = [SuspendedAgentStreamProtocol.self]
        let pendingSession = URLSession(configuration: pendingConfiguration)
        defer { pendingSession.invalidateAndCancel() }
        SuspendedAgentStreamProtocol.reset()
        let pendingClient = AgentClient(session: pendingSession)
        var partialText = ""
        let requestTask = Task {
            try await pendingClient.stream(messages: messages, model: AgentModel.defaultID, key: "fixture-key", tools: []) { partialText += $0 }
        }
        for _ in 0..<100 where partialText.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        check(partialText == "First.", "A partial answer is delivered while the transport is still open")
        requestTask.cancel()
        do { _ = try await requestTask.value; check(false, "Expected active stream cancellation") }
        catch { check(error is CancellationError, "Cancelling an active streaming Task interrupts the byte sequence") }
        check(partialText == "First.", "Cancelled stream never delivers its delayed answer fragment")
        for _ in 0..<20 where SuspendedAgentStreamProtocol.stopCount == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        check(SuspendedAgentStreamProtocol.stopCount > 0, "Stream cancellation aborts its underlying URLSession task")
    }
}
