import Foundation

struct AgentModel: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String

    static let defaultID = "openai/gpt-6-luna"
    static let presets = [
        AgentModel(id: defaultID, title: "Luna", detail: "GPT-6 Luna · fast voice answers"),
        AgentModel(id: "anthropic/claude-haiku-4.5", title: "Haiku", detail: "Claude Haiku 4.5 · $1 / $5 per million tokens"),
        AgentModel(id: "anthropic/claude-sonnet-5", title: "Sonnet", detail: "Claude Sonnet 5 · $2 / $10 per million tokens"),
        AgentModel(id: "anthropic/claude-opus-5", title: "Opus", detail: "Claude Opus 5 · $5 / $25 per million tokens")
    ]
}

struct AgentToolCall {
    let id: String
    let name: String
    let argumentsJSONString: String
    let arguments: [String: Any]
}

struct AgentReply {
    let text: String
    let toolCalls: [AgentToolCall]
    // Keep the original message, including provider reasoning metadata and
    // exact tool arguments, so subsequent tool rounds remain valid.
    let assistantMessage: [String: Any]
    let usage: [String: Any]?

    init(text: String, toolCalls: [AgentToolCall], assistantMessage: [String: Any], usage: [String: Any]? = nil) {
        self.text = text
        self.toolCalls = toolCalls
        self.assistantMessage = assistantMessage
        self.usage = usage
    }
}

protocol AgentResponding {
    func respond(messages: [[String: Any]], model: String, key: String, tools: [[String: Any]]) async throws -> AgentReply
}

enum AgentClientError: LocalizedError {
    case missingKey, unsupportedModel, invalidConversation, invalidTools, requestTooLarge
    case timeout, connection, unexpectedResponse, unreadableResponse, emptyResponse
    case invalidToolCall, incompleteResponse, filteredResponse, http(Int)

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Add your OpenRouter key in Settings."
        case .unsupportedModel: return "Choose an assistant model from Settings."
        case .invalidConversation: return "This conversation couldn't be sent. Start a new chat and try again."
        case .invalidTools: return "The assistant's actions couldn't be configured. Turn actions off and try again."
        case .requestTooLarge: return "This conversation is too large. Start a new chat."
        case .timeout: return "The assistant took too long. Try again."
        case .connection: return "Couldn't reach OpenRouter. Check your connection, then try again."
        case .unexpectedResponse: return "OpenRouter sent an unexpected response. Try again."
        case .unreadableResponse: return "OpenRouter sent an unreadable assistant response. Try again."
        case .emptyResponse: return "The assistant returned no answer. Try again."
        case .invalidToolCall: return "The assistant returned an invalid action. Nothing was run. Try again."
        case .incompleteResponse: return "The assistant's response was cut short. Nothing was run. Try a smaller request."
        case .filteredResponse: return "The model couldn't answer that request. Try rephrasing it."
        case .http(let status):
            switch status {
            case 401, 403: return "OpenRouter rejected the key. Check it in Settings."
            case 402: return "Your OpenRouter account needs credit. Add credit, then try again."
            case 413: return "This conversation is too large. Start a new chat."
            case 429: return "OpenRouter is busy. Wait a moment, then try again."
            case 500...599: return "The assistant service is unavailable. Try again shortly."
            default: return "OpenRouter couldn't answer this request (HTTP \(status)). Try again."
            }
        }
    }
}

final class AgentClient: AgentResponding {
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    static let maximumRequestBytes = 512_000
    static let maximumResponseBytes = 1_048_576
    let session: URLSession

    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 90
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = session ?? URLSession(configuration: config)
    }

    func respond(messages: [[String: Any]], model: String, key: String, tools: [[String: Any]]) async throws -> AgentReply {
        let request = try makeRequest(messages: messages, model: model, key: key, tools: tools)
        let toolNames = try Self.validateTools(tools)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw AgentClientError.timeout }
            throw AgentClientError.connection
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // Never include arbitrary transport errors: they can contain URLs,
            // headers, provider payloads, or request content.
            throw AgentClientError.connection
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw AgentClientError.unexpectedResponse }
        guard (200..<300).contains(http.statusCode) else { throw AgentClientError.http(http.statusCode) }
        guard data.count <= Self.maximumResponseBytes,
              let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              envelope["error"] == nil,
              let choices = envelope["choices"] as? [[String: Any]], choices.count == 1,
              let choice = choices.first,
              let message = choice["message"] as? [String: Any],
              message["role"] as? String == "assistant" else { throw AgentClientError.unreadableResponse }
        if choice["finish_reason"] as? String == "length" { throw AgentClientError.incompleteResponse }
        if choice["finish_reason"] as? String == "content_filter" { throw AgentClientError.filteredResponse }
        if let reason = choice["finish_reason"] as? String, !["stop", "tool_calls"].contains(reason) {
            throw AgentClientError.unreadableResponse
        }
        let text = try Self.contentText(message)
        let calls = try Self.parseToolCalls(message, allowed: toolNames)
        // OpenRouter can exhaust its server-search loop with real citation
        // excerpts but no summary/call. This is retrieval data, not an action.
        // Ordinary chat, mixed tools, or any unadvertised call remain rejected.
        let citationOnlySearch = tools.count == 1 && tools[0]["type"] as? String == "openrouter:web_search"
            && choice["finish_reason"] as? String == "tool_calls" && text.isEmpty && calls.isEmpty
            && !AgentSource.citationExcerpts(message).isEmpty
        guard choice["finish_reason"] as? String != "tool_calls" || !calls.isEmpty || citationOnlySearch else { throw AgentClientError.invalidToolCall }
        guard !text.isEmpty || !calls.isEmpty || citationOnlySearch else { throw AgentClientError.emptyResponse }
        return AgentReply(text: text, toolCalls: calls, assistantMessage: message, usage: envelope["usage"] as? [String: Any])
    }

    func makeRequest(messages: [[String: Any]], model: String, key: String, tools: [[String: Any]], stream: Bool = false) throws -> URLRequest {
        try Task.checkCancellation()
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty, !cleanKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AgentClientError.missingKey
        }
        guard AgentModel.presets.contains(where: { $0.id == model }) else { throw AgentClientError.unsupportedModel }
        try Self.validateMessages(messages)
        _ = try Self.validateTools(tools)
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": 4096,
            "stream": stream,
            // Sonnet 5 does not advertise temperature support. Do not send it.
            "provider": ["require_parameters": true, "sort": "latency"]
        ]
        if model == AgentModel.defaultID { body["reasoning"] = ["effort": "none"] }
        if stream { body["stream_options"] = ["include_usage": true] }
        if tools.contains(where: { $0["type"] as? String == "openrouter:web_search" }) { body["max_tool_calls"] = 2 }
        // A follow-up can contain earlier calls after its search allowance or
        // capabilities have been removed. Explicitly disable new calls rather
        // than relying on providers to infer that from an absent tools array.
        body["tool_choice"] = tools.isEmpty ? "none" : "auto"
        if !tools.isEmpty { body["tools"] = tools }
        guard JSONSerialization.isValidJSONObject(body),
              let encoded = try? JSONSerialization.data(withJSONObject: body) else { throw AgentClientError.invalidConversation }
        guard encoded.count <= Self.maximumRequestBytes else { throw AgentClientError.requestTooLarge }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Quick Dictate", forHTTPHeaderField: "X-OpenRouter-Title")
        request.httpBody = encoded

        return request
    }

    static func validateMessages(_ messages: [[String: Any]]) throws {
        guard !messages.isEmpty, messages.count <= 100,
              messages.contains(where: { $0["role"] as? String == "user" }) else { throw AgentClientError.invalidConversation }
        for message in messages {
            guard let role = message["role"] as? String, ["system", "user", "assistant", "tool"].contains(role) else {
                throw AgentClientError.invalidConversation
            }
            if role == "assistant" {
                guard message["content"] is String || message["content"] is NSNull || message["content"] == nil else {
                    throw AgentClientError.invalidConversation
                }
                if let calls = message["tool_calls"], !(calls is [[String: Any]]) { throw AgentClientError.invalidConversation }
            } else {
                guard let content = message["content"] as? String,
                      role == "tool" || !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AgentClientError.invalidConversation
                }
            }
            if role == "tool" {
                guard let id = message["tool_call_id"] as? String, !id.isEmpty else { throw AgentClientError.invalidConversation }
            }
        }
    }

    static func validateTools(_ tools: [[String: Any]]) throws -> Set<String> {
        guard tools.count <= 16 else { throw AgentClientError.invalidTools }
        var names = Set<String>()
        for tool in tools {
            if tool["type"] as? String == "openrouter:web_search" { continue }
            guard tool["type"] as? String == "function",
                  let function = tool["function"] as? [String: Any],
                  let name = function["name"] as? String,
                  validToolName(name), names.insert(name).inserted,
                  let parameters = function["parameters"] as? [String: Any],
                  parameters["type"] as? String == "object" else { throw AgentClientError.invalidTools }
        }
        return names
    }

    static func validToolName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
        }
    }

    static func contentText(_ message: [String: Any]) throws -> String {
        if let text = message["content"] as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard message["content"] == nil || message["content"] is NSNull else { throw AgentClientError.unreadableResponse }
        if let refusal = message["refusal"] as? String { return refusal.trimmingCharacters(in: .whitespacesAndNewlines) }
        return ""
    }

    static func parseToolCalls(_ message: [String: Any], allowed: Set<String>) throws -> [AgentToolCall] {
        guard let raw = message["tool_calls"], !(raw is NSNull) else { return [] }
        guard let calls = raw as? [[String: Any]], calls.count <= 8 else { throw AgentClientError.invalidToolCall }
        var identifiers = Set<String>()
        return try calls.map { call in
            guard call["type"] as? String == "function",
                  let id = call["id"] as? String, !id.isEmpty, id.utf8.count <= 256,
                  identifiers.insert(id).inserted,
                  let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String, allowed.contains(name),
                  let encoded = function["arguments"] as? String, encoded.utf8.count <= 32_768,
                  let arguments = (try? JSONSerialization.jsonObject(with: Data(encoded.utf8))) as? [String: Any] else {
                throw AgentClientError.invalidToolCall
            }
            return AgentToolCall(id: id, name: name, argumentsJSONString: encoded, arguments: arguments)
        }
    }
}
