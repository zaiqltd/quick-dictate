import Foundation

// Separate transport from the transcription tests: neither test suite changes
// the other's handler, and these requests never leave the process.
final class AgentMockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        do {
            let (status, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}

    static func body(_ request: URLRequest) throws -> [String: Any] {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            var data = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(bytes, count: count)
            }
            body = data
        }
        return try JSONSerialization.jsonObject(with: body ?? Data()) as! [String: Any]
    }
}

extension CoreTests {
    static func agentClientChecks() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentMockProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = AgentClient(session: session)
        let messages: [[String: Any]] = [["role": "system", "content": "Be helpful."], ["role": "user", "content": "Hello."]]
        let tool: [String: Any] = ["type": "function", "function": [
            "name": "run_terminal", "description": "Run the command after review.",
            "parameters": ["type": "object", "properties": ["command": ["type": "string"]], "required": ["command"], "additionalProperties": false]
        ]]
        func response(_ message: [String: Any], finish: String = "stop", usage: [String: Any]? = nil) throws -> Data {
            var envelope: [String: Any] = ["choices": [["index": 0, "message": message, "finish_reason": finish]]]
            if let usage { envelope["usage"] = usage }
            return try JSONSerialization.data(withJSONObject: envelope)
        }
        func answer(_ text: String = "Ready.") throws -> Data {
            try response(["role": "assistant", "content": text])
        }
        func call(_ id: String = "call_fixture", name: String = "run_terminal", arguments: String = "{\"command\":\"pwd\"}") -> [String: Any] {
            ["id": id, "type": "function", "function": ["name": name, "arguments": arguments]]
        }
        func fail(_ expected: String, body: Data, tools: [[String: Any]] = []) async {
            AgentMockProtocol.handler = { _ in (200, body) }
            await expectError(expected) { _ = try await client.respond(messages: messages, model: AgentModel.defaultID, key: "test-key", tools: tools) }
        }

        AgentMockProtocol.handler = { request in
            check(request.url == AgentClient.endpoint, "Agent requests only the fixed OpenRouter endpoint")
            check(request.httpMethod == "POST", "Agent uses POST")
            check(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key", "Agent authenticates without a key in the URL")
            check(request.value(forHTTPHeaderField: "Content-Type") == "application/json", "Agent request is JSON")
            let body = try AgentMockProtocol.body(request)
            check(body["model"] as? String == AgentModel.defaultID, "Agent sends the selected exact model")
            check(body["max_tokens"] as? Int == 4096 && body["stream"] as? Bool == false, "Agent response size is bounded")
            check((body["reasoning"] as? [String: String])?["effort"] == "none", "Luna answers without a reasoning delay")
            check(body["temperature"] == nil, "No unsupported temperature parameter")
            check(body["tools"] == nil && body["tool_choice"] as? String == "none", "Chat without actions explicitly disables tool calls")
            check((body["provider"] as? [String: Any])?["require_parameters"] as? Bool == true, "Agent requires routing parameter support")
            check((body["messages"] as? [[String: String]])?.last?["content"] == "Hello.", "Agent sends the user's message")
            let encodedBody = try JSONSerialization.data(withJSONObject: body)
            check(!String(data: encodedBody, encoding: .utf8)!.contains("test-key"), "Key is not sent as prompt data")
            return (200, try response(["role": "assistant", "content": "  Hello, there.\n"], usage: ["prompt_tokens": 12, "completion_tokens": 4, "cost": 0.0001]))
        }
        let textReply = try await client.respond(messages: messages, model: AgentModel.defaultID, key: " test-key\n", tools: [])
        check(textReply.text == "Hello, there." && textReply.toolCalls.isEmpty, "Plain assistant text is trimmed for display")
        check(textReply.assistantMessage["content"] as? String == "  Hello, there.\n", "Assistant history preserves the original content")
        check(textReply.usage?["cost"] as? Double == 0.0001, "Agent retains reported usage")

        AgentMockProtocol.handler = { _ in (200, try answer()) }
        for model in AgentModel.presets {
            let reply = try await client.respond(messages: messages, model: model.id, key: "test", tools: [])
            check(reply.text == "Ready.", "Verified model preset is accepted: \(model.title)")
        }

        let arguments = "{\"command\":\"printf '%s' 'Café'\",\"directory\":\"/fixture\"}"
        let reasoning: [[String: Any]] = [["type": "reasoning.encrypted", "data": "fixture-encrypted-reasoning", "id": "reasoning_fixture", "format": "anthropic-claude-v1", "index": 0]]
        let assistant: [String: Any] = ["role": "assistant", "content": NSNull(), "tool_calls": [call(arguments: arguments)], "reasoning_details": reasoning]
        AgentMockProtocol.handler = { request in
            let body = try AgentMockProtocol.body(request)
            check((body["tools"] as? [[String: Any]])?.count == 1 && body["tool_choice"] as? String == "auto", "Enabled tool schema reaches the provider")
            return (200, try response(assistant, finish: "tool_calls"))
        }
        let toolReply = try await client.respond(messages: messages, model: AgentModel.defaultID, key: "test", tools: [tool])
        check(toolReply.text.isEmpty && toolReply.toolCalls.count == 1, "Null text with a valid action is a valid response")
        check(toolReply.toolCalls[0].id == "call_fixture" && toolReply.toolCalls[0].name == "run_terminal", "Action identity is preserved")
        check(toolReply.toolCalls[0].argumentsJSONString == arguments && toolReply.toolCalls[0].arguments["directory"] as? String == "/fixture", "Tool argument bytes and decoded values are retained")
        check((toolReply.assistantMessage["reasoning_details"] as? [[String: Any]])?.first?["data"] as? String == "fixture-encrypted-reasoning", "Provider reasoning metadata survives parsing")

        AgentMockProtocol.handler = { request in
            let body = try AgentMockProtocol.body(request)
            let sent = body["messages"] as! [[String: Any]]
            check((sent[2]["reasoning_details"] as? [[String: Any]])?.first?["data"] as? String == "fixture-encrypted-reasoning", "A follow-up round returns reasoning metadata unchanged")
            check(sent[3]["role"] as? String == "tool" && sent[3]["tool_call_id"] as? String == "call_fixture", "Follow-up tool result has matching ID")
            check((body["tools"] as? [[String: Any]])?.count == 1, "Tools remain present on subsequent rounds")
            return (200, try answer("The directory is /fixture."))
        }
        let followed = try await client.respond(messages: messages + [toolReply.assistantMessage, ["role": "tool", "tool_call_id": "call_fixture", "content": "/fixture"]], model: AgentModel.defaultID, key: "test", tools: [tool])
        check(followed.text == "The directory is /fixture.", "A complete tool round returns a final answer")

        AgentMockProtocol.handler = { request in
            let body = try AgentMockProtocol.body(request)
            check(body["tools"] == nil && body["tool_choice"] as? String == "none", "A tool-less follow-up explicitly forbids calls despite earlier tool history")
            let sent = body["messages"] as! [[String: Any]]
            check((sent[2]["reasoning_details"] as? [[String: Any]])?.first?["data"] as? String == "fixture-encrypted-reasoning" && sent[3]["tool_call_id"] as? String == "call_fixture",
                  "Disabling new calls preserves earlier tool results and opaque signatures")
            return (200, try answer("The reviewed result is ready."))
        }
        let withoutTools = try await client.respond(messages: messages + [toolReply.assistantMessage, ["role": "tool", "tool_call_id": "call_fixture", "content": "/fixture"]], model: AgentModel.defaultID, key: "test", tools: [])
        check(withoutTools.toolCalls.isEmpty && withoutTools.text == "The reviewed result is ready.", "Answer-only follow-up remains a valid conversation")

        let beforeInvalidRequests = AgentMockProtocol.requests
        await expectError("Add your") { _ = try await client.respond(messages: messages, model: AgentModel.defaultID, key: " \n", tools: []) }
        await expectError("Add your") { _ = try await client.respond(messages: messages, model: AgentModel.defaultID, key: "key\r\nInjected: value", tools: []) }
        await expectError("Choose an assistant") { _ = try await client.respond(messages: messages, model: "other/model", key: "test", tools: []) }
        await expectError("conversation") { _ = try await client.respond(messages: [], model: AgentModel.defaultID, key: "test", tools: []) }
        await expectError("conversation") { _ = try await client.respond(messages: [["role": "unknown", "content": "Hello"]], model: AgentModel.defaultID, key: "test", tools: []) }
        await expectError("conversation") { _ = try await client.respond(messages: [["role": "user", "content": ""]], model: AgentModel.defaultID, key: "test", tools: []) }
        await expectError("conversation") { _ = try await client.respond(messages: messages + [["role": "tool", "content": "result"]], model: AgentModel.defaultID, key: "test", tools: [tool]) }
        await expectError("conversation") { _ = try await client.respond(messages: messages + [["role": "assistant", "content": Date()]], model: AgentModel.defaultID, key: "test", tools: []) }
        await expectError("conversation") { _ = try await client.respond(messages: Array(repeating: messages[1], count: 101), model: AgentModel.defaultID, key: "test", tools: []) }
        await expectError("too large") { _ = try await client.respond(messages: [["role": "user", "content": String(repeating: "x", count: AgentClient.maximumRequestBytes)]], model: AgentModel.defaultID, key: "test", tools: []) }
        await expectError("actions couldn't") { _ = try await client.respond(messages: messages, model: AgentModel.defaultID, key: "test", tools: [tool, tool]) }
        await expectError("actions couldn't") { _ = try await client.respond(messages: messages, model: AgentModel.defaultID, key: "test", tools: [["type": "function", "function": ["name": "invalid name", "parameters": ["type": "object"]]]]) }
        await expectError("actions couldn't") { _ = try await client.respond(messages: messages, model: AgentModel.defaultID, key: "test", tools: [["type": "function", "function": ["name": "valid", "parameters": ["type": "array"]]]]) }
        check(AgentMockProtocol.requests == beforeInvalidRequests, "Invalid local inputs never start a network request")

        for (status, fragment) in [(401, "rejected the key"), (403, "rejected the key"), (402, "needs credit"), (413, "too large"), (429, "busy"), (503, "unavailable"), (400, "HTTP 400")] {
            AgentMockProtocol.handler = { _ in (status, Data("provider-secret-and-user-data".utf8)) }
            do {
                _ = try await client.respond(messages: messages, model: AgentModel.defaultID, key: "test", tools: [])
                check(false, "HTTP error should fail")
            } catch {
                check(error is AgentClientError && error.localizedDescription.contains(fragment), "Typed agent HTTP error \(status)")
                check(!error.localizedDescription.contains("provider-secret"), "Provider errors cannot leak request details")
            }
        }
        await fail("unreadable", body: Data("<html>provider-secret</html>".utf8))
        await fail("unreadable", body: Data("{\"error\":{\"message\":\"provider-secret\"}}".utf8))
        await fail("unreadable", body: Data("{\"choices\":[]}".utf8))
        await fail("unreadable", body: try response(["role": "user", "content": "wrong role"]))
        await fail("unreadable", body: try response(["role": "assistant", "content": ["not": "text"]]))
        await fail("unreadable", body: Data(repeating: 32, count: AgentClient.maximumResponseBytes + 1))
        await fail("no answer", body: try response(["role": "assistant", "content": "  "]))
        await fail("no answer", body: try response(["role": "assistant"]))
        await fail("cut short", body: try response(["role": "assistant", "content": "partial", "tool_calls": [call()]], finish: "length"), tools: [tool])
        await fail("couldn't answer", body: try response(["role": "assistant", "content": NSNull()], finish: "content_filter"))
        await fail("unreadable", body: try response(["role": "assistant", "content": "partial"], finish: "error"))
        await fail("invalid action", body: try response(["role": "assistant", "content": NSNull()], finish: "tool_calls"), tools: [tool])
        await fail("invalid action", body: try response(["role": "assistant", "tool_calls": [call()]], finish: "tool_calls"))
        await fail("invalid action", body: try response(["role": "assistant", "tool_calls": [call(name: "unadvertised")]], finish: "tool_calls"), tools: [tool])
        await fail("invalid action", body: try response(["role": "assistant", "tool_calls": [call(arguments: "not JSON")]], finish: "tool_calls"), tools: [tool])
        await fail("invalid action", body: try response(["role": "assistant", "tool_calls": [call(arguments: "[]")]], finish: "tool_calls"), tools: [tool])
        await fail("invalid action", body: try response(["role": "assistant", "tool_calls": [call(), call()]], finish: "tool_calls"), tools: [tool])
        await fail("invalid action", body: try response(["role": "assistant", "tool_calls": [call("")]], finish: "tool_calls"), tools: [tool])
        await fail("invalid action", body: try response(["role": "assistant", "tool_calls": "not an array"]), tools: [tool])
        await fail("invalid action", body: try response(["role": "assistant", "tool_calls": (0..<9).map { call("call_\($0)") }], finish: "tool_calls"), tools: [tool])

        AgentMockProtocol.handler = { _ in (200, try response(["role": "assistant", "content": NSNull(), "refusal": "I can't do that."])) }
        let refusal = try await client.respond(messages: messages, model: AgentModel.defaultID, key: "test", tools: [])
        check(refusal.text == "I can't do that." && refusal.toolCalls.isEmpty, "A model refusal is displayed without fabricating actions")
        AgentMockProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await expectError("connection") { _ = try await client.respond(messages: messages, model: AgentModel.defaultID, key: "test", tools: []) }
        AgentMockProtocol.handler = { _ in throw URLError(.timedOut) }
        await expectError("too long") { _ = try await client.respond(messages: messages, model: AgentModel.defaultID, key: "test", tools: []) }
        AgentMockProtocol.handler = { _ in throw URLError(.cancelled) }
        do { _ = try await client.respond(messages: messages, model: AgentModel.defaultID, key: "test", tools: []); check(false, "Agent cancellation must throw") }
        catch { check(error is CancellationError, "Transport cancellation is preserved as CancellationError") }
        AgentMockProtocol.handler = { _ in throw NSError(domain: "provider-secret", code: 1, userInfo: [NSLocalizedDescriptionKey: "sensitive request content"]) }
        do { _ = try await client.respond(messages: messages, model: AgentModel.defaultID, key: "test", tools: []); check(false, "Transport failure must throw") }
        catch { check(error is AgentClientError && !error.localizedDescription.contains("sensitive"), "Unexpected transport errors are sanitized") }
        let cancelled = Task { try await client.respond(messages: messages, model: AgentModel.defaultID, key: "test", tools: []) }
        cancelled.cancel()
        do { _ = try await cancelled.value; check(false, "Cancelled task must throw") }
        catch { check(error is CancellationError, "An already cancelled agent task stays cancelled") }
    }
}
