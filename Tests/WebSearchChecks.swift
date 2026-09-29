import Foundation

private final class SearchResponseFixture: AgentResponding {
    var requests: [[[String: Any]]] = []
    var tools: [[String: Any]] = []
    var reply = AgentReply(text: "Python release. [Python](https://python.org/downloads/)", toolCalls: [], assistantMessage: ["role": "assistant", "content": "[Python](https://python.org/downloads/)", "annotations": [["type": "url_citation", "url_citation": ["title": "Python", "url": "https://python.org/downloads/"]]]])
    func respond(messages: [[String: Any]], model: String, key: String, tools: [[String: Any]]) async throws -> AgentReply {
        CoreTests.check(model == AgentModel.defaultID, "Search helper uses the requested GPT-6 Luna model")
        self.requests.append(messages); self.tools = tools
        return reply
    }
}
extension CoreTests {
    static func webSearchChecks() async throws {
        let annotations: [[String: Any]] = [
            ["type": "url_citation", "url_citation": ["title": "Official", "url": "https://example.com/official"]],
            ["type": "url_citation", "url_citation": ["title": "Duplicate", "url": "https://example.com/official"]],
            ["type": "url_citation", "url_citation": ["url": "file:///private/test"]],
            ["type": "url_citation", "url_citation": ["url": "https://user:pass@example.com/"]]
        ]
        let sources = AgentSource.parse(["annotations": annotations])
        check(sources.count == 1 && sources[0].title == "Official", "Sources reject unsafe schemes, credentials and duplicates")
        let links = AgentSource.parse(["content": "Read [Docs](https://example.com/docs) and [more](https://example.com/docs)."])
        check(links.count == 1 && links[0].url.path == "/docs", "Markdown citation fallback is deduplicated")
        check(AgentSource.parse(["content": "No evidence."]).isEmpty, "No invented source links")
        let mock = SearchResponseFixture()
        let client = WebSearchClient(client: mock)
        let result = try await client.search("  current Python release  ", key: "fake")
        check(result.sources.count == 1 && result.summary.contains("Python"), "Search returns summary and usable citations")
        check(mock.requests[0].last?["content"] as? String == "current Python release", "Only explicit query goes to search helper")
        check(mock.tools.count == 1 && mock.tools[0]["type"] as? String == "openrouter:web_search", "Search uses OpenRouter server tool")
        let config = mock.tools[0]["parameters"] as! [String: Any]
        check(config["engine"] as? String == "parallel" && config["mode"] as? String == "fast", "Search selects latency-conscious provider mode")
        check(config["max_uses"] as? Int == 1 && config["max_results"] as? Int == 3, "Search caps work and results")
        await expectError("shorter") { _ = try await client.search(" ", key: "fake") }
        await expectError("shorter") { _ = try await client.search(String(repeating: "q", count: 401), key: "fake") }
        mock.reply = AgentReply(text: "Unsupported assertion", toolCalls: [], assistantMessage: ["role": "assistant", "content": "Unsupported assertion"])
        await expectError("verifiable sources") { _ = try await client.search("query", key: "fake") }
        mock.reply = AgentReply(text: "[Invented](https://example.com/)", toolCalls: [], assistantMessage: ["role": "assistant", "content": "[Invented](https://example.com/)"])
        await expectError("verifiable sources") { _ = try await client.search("query", key: "fake") }
        let request = try AgentClient().makeRequest(messages: [["role":"user", "content":"test"]], model: AgentModel.defaultID, key: "fake", tools: mock.tools, stream: true)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        check((body["reasoning"] as? [String: String])?["effort"] == "none", "Luna disables reasoning for fast replies")
        check(body["max_tool_calls"] as? Int == 2, "Server search outer step budget is bounded")
        check((body["stream_options"] as? [String: Bool])?["include_usage"] == true, "Streaming retains usage metadata")
        check(SpokenText.clean("**Hello** [source](https://example.com).") == "Hello source.", "Speech strips Markdown and URLs")
        check(!SpokenText.clean("Here is code: ```swift\nprint(1)\n```").contains("print(1)"), "Speech avoids reading complete code blocks")

        let citationMessage: [String: Any] = ["role": "assistant", "content": NSNull(), "annotations": [
            ["type": "url_citation", "url_citation": ["title": "Official fixture", "url": "https://example.com/releases", "content": "The fixture release is version 7."]]
        ]]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentMockProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let realClient = AgentClient(session: transport)
        let realSearch = WebSearchClient(client: realClient)
        func serverResponse(_ message: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["choices": [["message": message, "finish_reason": "tool_calls"]]])
        }
        AgentMockProtocol.handler = { _ in (200, try serverResponse(citationMessage)) }
        let recovered = try await realSearch.search("public fixture release", key: "fake")
        check(recovered.sources.count == 1 && recovered.summary.contains("The fixture release is version 7.") && recovered.summary.contains("https://example.com/releases"),
              "Citation-only server-search response recovers actual provider excerpts without another request")
        check(!recovered.summary.contains("Nothing was run"), "Retrieved citations are not misreported as a failed local action")
        await expectError("invalid action") {
            _ = try await realClient.respond(messages: [["role": "user", "content": "fixture"]], model: AgentModel.defaultID, key: "fake", tools: [])
        }
        let localTool: [String: Any] = ["type": "function", "function": ["name": "run_terminal", "parameters": ["type": "object"]]]
        await expectError("invalid action") {
            _ = try await realClient.respond(messages: [["role": "user", "content": "fixture"]], model: AgentModel.defaultID, key: "fake", tools: mock.tools + [localTool])
        }
        var actualCall = citationMessage
        actualCall["tool_calls"] = [["id": "unadvertised", "type": "function", "function": ["name": "run_terminal", "arguments": "{\"command\":\"must not execute\"}"]]]
        AgentMockProtocol.handler = { _ in (200, try serverResponse(actualCall)) }
        await expectError("invalid action") { _ = try await realSearch.search("public fixture", key: "fake") }
        for badAnnotations: [[String: Any]] in [[], [["type": "url_citation", "url_citation": ["url": "file:///private/fixture", "content": "must not use"]]], [["type": "url_citation", "url_citation": ["url": "https://user:pass@example.com/", "content": "must not use"]]], [["type": "url_citation", "url_citation": ["url": "https://example.com/", "content": " "]]]] {
            let message: [String: Any] = ["role": "assistant", "content": NSNull(), "annotations": badAnnotations]
            AgentMockProtocol.handler = { _ in (200, try serverResponse(message)) }
            await expectError("invalid action") { _ = try await realSearch.search("public fixture", key: "fake") }
        }
        let longExcerpts: [String: Any] = ["annotations": (0..<10).map { index in
            ["type": "url_citation", "url_citation": ["title": "Fixture \(index)", "url": "https://example.com/\(index)", "content": String(repeating: "x", count: 20_000)]]
        }]
        check(AgentSource.citationExcerpts(longExcerpts).count <= 12_000, "Citation recovery remains bounded across large provider excerpts")
    }
}
