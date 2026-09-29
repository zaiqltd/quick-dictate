import Foundation

protocol AgentStreaming: AgentResponding {
    /// Emits visible answer deltas only. Reasoning and tool arguments are never
    /// sent to this callback; actions are returned only after a complete stream.
    func stream(messages: [[String: Any]], model: String, key: String, tools: [[String: Any]],
                onText: @escaping @MainActor (String) -> Void) async throws -> AgentReply
}

extension AgentClient: AgentStreaming {
    func stream(messages: [[String: Any]], model: String, key: String, tools: [[String: Any]],
                onText: @escaping @MainActor (String) -> Void) async throws -> AgentReply {
        let request = try makeRequest(messages: messages, model: model, key: key, tools: tools, stream: true)
        let allowed = try Self.validateTools(tools)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw AgentClientError.unexpectedResponse }
            guard (200..<300).contains(http.statusCode) else { throw AgentClientError.http(http.statusCode) }
            var decoder = AgentSSEDecoder()
            var assembler = AgentStreamAssembler(allowedTools: allowed)
            for try await byte in bytes {
                try Task.checkCancellation()
                if let event = try decoder.feed(byte) {
                    if let text = try assembler.consume(event), !text.isEmpty { await onText(text) }
                    if assembler.isDone { break }
                }
            }
            try Task.checkCancellation()
            if !assembler.isDone, let event = try decoder.finish() {
                if let text = try assembler.consume(event), !text.isEmpty { await onText(text) }
            }
            return try assembler.reply()
        } catch is CancellationError { throw CancellationError() }
        catch let error as AgentClientError { throw error }
        catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw AgentClientError.timeout }
            throw AgentClientError.connection
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw AgentClientError.connection
        }
    }
}

/// Bounded SSE framing handles UTF-8 split across arbitrary byte boundaries,
/// comments, LF / CRLF / CR, and multi-line data without buffering the response.
struct AgentSSEDecoder {
    private var byteCount = 0
    private var line = Data()
    private var dataLines: [String] = []
    private var previousWasCR = false
    private var firstLine = true
    let maximumBytes: Int

    init(maximumBytes: Int = AgentClient.maximumResponseBytes) { self.maximumBytes = maximumBytes }

    mutating func feed(_ byte: UInt8) throws -> String? {
        byteCount += 1
        guard byteCount <= maximumBytes else { throw AgentClientError.unreadableResponse }
        if byte == 10, previousWasCR { previousWasCR = false; return nil }
        previousWasCR = byte == 13
        if byte == 10 || byte == 13 { return try processLine() }
        line.append(byte)
        return nil
    }

    mutating func finish() throws -> String? {
        if !line.isEmpty, let event = try processLine() { return event }
        guard !dataLines.isEmpty else { return nil }
        let event = dataLines.joined(separator: "\n")
        dataLines = []
        return event
    }

    private mutating func processLine() throws -> String? {
        guard var value = String(data: line, encoding: .utf8) else { throw AgentClientError.unreadableResponse }
        line.removeAll(keepingCapacity: true)
        if firstLine { firstLine = false; if value.hasPrefix("\u{FEFF}") { value.removeFirst() } }
        if value.isEmpty {
            guard !dataLines.isEmpty else { return nil }
            let event = dataLines.joined(separator: "\n")
            dataLines = []
            return event
        }
        if value.hasPrefix(":") { return nil }
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.first == "data" else { return nil }
        var data = parts.count == 2 ? String(parts[1]) : ""
        if data.hasPrefix(" ") { data.removeFirst() }
        dataLines.append(data)
        return nil
    }
}

/// Reassembles one assistant message, including exact tool metadata and opaque
/// reasoning signatures required for a later tool round. It never runs a tool.
struct AgentStreamAssembler {
    private let allowedTools: Set<String>
    private var message: [String: Any] = ["role": "assistant"]
    private var calls: [Int: [String: Any]] = [:]
    private var reasoning: [[String: Any]] = []
    private var reasoningPositions: [String: Int] = [:]
    private var finishReason: String?
    private var usage: [String: Any]?
    private var eventBytes = 0
    private(set) var isDone = false

    init(allowedTools: Set<String>) { self.allowedTools = allowedTools }

    mutating func consume(_ payload: String) throws -> String? {
        guard !isDone else { throw AgentClientError.unreadableResponse }
        eventBytes += payload.utf8.count
        guard eventBytes <= AgentClient.maximumResponseBytes else { throw AgentClientError.unreadableResponse }
        if payload == "[DONE]" {
            guard finishReason != nil else { throw AgentClientError.incompleteResponse }
            isDone = true
            return nil
        }
        guard let event = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any],
              event["error"] == nil,
              let choices = event["choices"] as? [[String: Any]], choices.count <= 1 else {
            throw AgentClientError.unreadableResponse
        }
        if let value = event["usage"], !(value is NSNull) {
            guard let object = value as? [String: Any] else { throw AgentClientError.unreadableResponse }
            usage = object
        }
        // Standard OpenAI accounting frames may have no choices. OpenRouter
        // normally repeats a content-free terminal choice with its usage frame.
        if choices.isEmpty {
            guard event["usage"] is [String: Any] else { throw AgentClientError.unreadableResponse }
            return nil
        }
        let choice = choices[0]
        if let index = choice["index"], strictIndex(index) != 0 { throw AgentClientError.unreadableResponse }
        guard let delta = choice["delta"] as? [String: Any] else { throw AgentClientError.unreadableResponse }
        if let role = delta["role"], !(role is NSNull), role as? String != "assistant" {
            throw AgentClientError.unreadableResponse
        }
        if let reason = choice["finish_reason"], !(reason is NSNull) {
            guard let text = reason as? String else { throw AgentClientError.unreadableResponse }
            if text == "length" { throw AgentClientError.incompleteResponse }
            if text == "content_filter" { throw AgentClientError.filteredResponse }
            guard ["stop", "tool_calls"].contains(text), finishReason == nil || finishReason == text else {
                throw AgentClientError.unreadableResponse
            }
        }
        if finishReason != nil, hasNewContent(delta) { throw AgentClientError.unreadableResponse }
        let visible = try mergeDelta(delta)
        if let reason = choice["finish_reason"] as? String { finishReason = reason }
        return visible
    }

    func reply() throws -> AgentReply {
        guard isDone, let finishReason else { throw AgentClientError.incompleteResponse }
        var completed = message
        if completed["content"] == nil { completed["content"] = NSNull() }
        if !reasoning.isEmpty { completed["reasoning_details"] = reasoning }
        if !calls.isEmpty {
            let indices = calls.keys.sorted()
            guard indices == Array(0..<indices.count) else { throw AgentClientError.invalidToolCall }
            completed["tool_calls"] = indices.map { index in
                var call = calls[index]!
                call.removeValue(forKey: "index")
                return call
            }
        }
        let text = try AgentClient.contentText(completed)
        let parsed = try AgentClient.parseToolCalls(completed, allowed: allowedTools)
        guard finishReason != "tool_calls" || !parsed.isEmpty else { throw AgentClientError.invalidToolCall }
        guard parsed.isEmpty || finishReason == "tool_calls" else { throw AgentClientError.invalidToolCall }
        guard !text.isEmpty || !parsed.isEmpty else { throw AgentClientError.emptyResponse }
        return AgentReply(text: text, toolCalls: parsed, assistantMessage: completed, usage: usage)
    }

    private func hasNewContent(_ delta: [String: Any]) -> Bool {
        delta.contains { key, value in
            if key == "role" || value is NSNull { return false }
            if let value = value as? String { return !value.isEmpty }
            if let value = value as? [Any] { return !value.isEmpty }
            if let value = value as? [String: Any] { return !value.isEmpty }
            return true
        }
    }

    private mutating func mergeDelta(_ delta: [String: Any]) throws -> String? {
        let content = delta["content"] as? String ?? ""
        let visible = !content.isEmpty ? content
            : ((message["content"] as? String ?? "").isEmpty ? (delta["refusal"] as? String ?? "") : "")
        for (key, value) in delta {
            if value is NSNull || key == "role" { continue }
            switch key {
            case "content", "refusal", "reasoning", "reasoning_content":
                guard let fragment = value as? String else { throw AgentClientError.unreadableResponse }
                message[key] = (message[key] as? String ?? "") + fragment
            case "tool_calls":
                guard let fragments = value as? [[String: Any]], fragments.count <= 8 else { throw AgentClientError.invalidToolCall }
                var seen = Set<Int>()
                for fragment in fragments {
                    guard let rawIndex = fragment["index"], let index = strictIndex(rawIndex), (0..<8).contains(index), seen.insert(index).inserted else {
                        throw AgentClientError.invalidToolCall
                    }
                    var call = calls[index] ?? [:]
                    for (field, value) in fragment where field != "index" && !(value is NSNull) {
                        if field == "function" {
                            guard let fields = value as? [String: Any] else { throw AgentClientError.invalidToolCall }
                            var function = call["function"] as? [String: Any] ?? [:]
                            for (name, piece) in fields {
                                if piece is NSNull { continue }
                                if name == "arguments" || name == "name" {
                                    guard let text = piece as? String else { throw AgentClientError.invalidToolCall }
                                    if name == "name", function[name] as? String == text { continue }
                                    let accumulated = (function[name] as? String ?? "") + text
                                    guard accumulated.utf8.count <= (name == "arguments" ? 32_768 : 64) else { throw AgentClientError.invalidToolCall }
                                    function[name] = accumulated
                                } else { function[name] = try mergedMetadata(function[name], piece) }
                            }
                            call[field] = function
                        } else {
                            call[field] = try mergedMetadata(call[field], value)
                        }
                    }
                    calls[index] = call
                }
            case "reasoning_details":
                guard let details = value as? [[String: Any]] else { throw AgentClientError.unreadableResponse }
                for detail in details { try mergeReasoning(detail) }
            case "annotations":
                guard let array = value as? [Any] else { throw AgentClientError.unreadableResponse }
                message[key] = (message[key] as? [Any] ?? []) + array
            case "function_call":
                throw AgentClientError.invalidToolCall
            default:
                message[key] = try mergedMetadata(message[key], value)
            }
        }
        return visible.isEmpty ? nil : visible
    }

    private mutating func mergeReasoning(_ detail: [String: Any]) throws {
        let key: String?
        if let value = detail["index"], !(value is NSNull) {
            guard let index = strictIndex(value), (0..<128).contains(index) else { throw AgentClientError.unreadableResponse }
            key = "index:\(index)"
        } else if let id = detail["id"] as? String, !id.isEmpty { key = "id:\(id)" }
        else { key = nil }
        let position = key.flatMap { reasoningPositions[$0] } ?? reasoning.count
        if position == reasoning.count {
            guard reasoning.count < 128 else { throw AgentClientError.unreadableResponse }
            reasoning.append([:])
            if let key { reasoningPositions[key] = position }
        }
        var current = reasoning[position]
        for (field, value) in detail {
            if value is NSNull { if current[field] == nil { current[field] = value }; continue }
            if ["text", "summary", "data", "signature"].contains(field) {
                guard let piece = value as? String else { throw AgentClientError.unreadableResponse }
                current[field] = (current[field] as? String ?? "") + piece
            } else {
                current[field] = try mergedMetadata(current[field], value)
            }
        }
        reasoning[position] = current
    }

    private func mergedMetadata(_ previous: Any?, _ next: Any) throws -> Any {
        guard let previous, !(previous is NSNull) else { return next }
        if let before = previous as? [String: Any], let after = next as? [String: Any] {
            var merged = before
            for (key, value) in after { merged[key] = try mergedMetadata(merged[key], value) }
            return merged
        }
        if let before = previous as? [Any], let after = next as? [Any] { return before + after }
        guard let before = try? JSONSerialization.data(withJSONObject: previous, options: [.fragmentsAllowed, .sortedKeys]),
              let after = try? JSONSerialization.data(withJSONObject: next, options: [.fragmentsAllowed, .sortedKeys]), before == after else {
            throw AgentClientError.unreadableResponse
        }
        return previous
    }

    private func strictIndex(_ value: Any) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue == Double(number.intValue) else { return nil }
        return number.intValue
    }
}
