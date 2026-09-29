import Foundation
import AppKit

final class MockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct CoreTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ description: String) {
        guard condition() else { fputs("FAIL: \(description)\n", stderr); exit(1) }
        checks += 1
    }
    static func expectError(_ contains: String, operation: () async throws -> Void) async {
        do { try await operation(); check(false, "Expected error: \(contains)") }
        catch { check(error.localizedDescription.contains(contains), "Expected \(contains), got \(error.localizedDescription)") }
    }
    static func main() async throws {
        // Push-to-talk starts on press, ends on either key release, and cancels other shortcuts.
        func signals(_ sequence: [NSEvent.ModifierFlags], keyAt: Int? = nil) -> [ModifierChord.Signal] {
            var chord = ModifierChord()
            var result: [ModifierChord.Signal] = []
            for (index, flags) in sequence.enumerated() {
                let signal = chord.flagsChanged(flags)
                if signal != .none { result.append(signal) }
                if index == keyAt {
                    let keySignal = chord.keyDown(flags)
                    if keySignal != .none { result.append(keySignal) }
                }
            }
            return result
        }
        check(signals([.option, [.option, .command]]) == [.begin], "Start while keys are down")
        check(signals([.command, [.option, .command]]) == [.begin], "Either key order starts")
        check(signals([[.option, .command], .option]) == [.begin, .end], "Release Command finishes immediately")
        check(signals([[.option, .command], .command]) == [.begin, .end], "Release Option finishes immediately")
        check(signals([[.option, .command], []]) == [.begin, .end], "Release both finishes")
        check(signals([[.option, .command], [.option, .command], [], []]) == [.begin, .end], "No repeated start or stop")
        check(signals([[.option, .command], [], [.option, .command], []]) == [.begin, .end, .begin, .end], "Two separate holds")
        check(signals([.option, []]).isEmpty, "Option alone does nothing")
        check(signals([.command, []]).isEmpty, "Command alone does nothing")
        check(signals([.option, [.option, .command], .option, []], keyAt: 1) == [.begin, .cancel], "Extra key discards instead of uploading")
        check(signals([.option, [.option, .command], .option, []], keyAt: 0).isEmpty, "Earlier modified key suppresses recording")
        check(signals([[.option, .command], [.option, .command, .shift], []]) == [.begin, .cancel], "Shift cancels")
        check(signals([[.option, .command], [.option, .command, .control], []]) == [.begin, .cancel], "Control cancels")
        check(signals([[.option, .command], [.option, .command, .function], []]) == [.begin, .cancel], "Function cancels")
        check(signals([[.option, .command, .control], [.option, .command], []]).isEmpty, "Three modifiers never start")
        check(signals([[.option, .command, .capsLock], .capsLock]) == [.begin, .end], "Caps Lock is ignored")
        check(signals([[.option, .command], .option, [.option, .command], []]) == [.begin, .end], "No restart until fully released")
        check(signals([[.option, .command], [], [.option, .command], []], keyAt: 0) == [.begin, .cancel, .begin, .end], "Clean next hold recovers")
        check(Credentials.parseEnv("# ignored\nOPENROUTER_MODEL=other\nexport OPENROUTER_API_KEY='sk-or-test'\n") == "sk-or-test", "Quoted env parsing")
        check(Credentials.parseEnv("OPENROUTER_API_KEY=sk-or-test # comment") == "sk-or-test", "Unquoted env comments")
        check(Credentials.parseEnv("OPENROUTER_API_KEY=\"sk-or-test\"") == "sk-or-test", "Double quoted env")
        check(Credentials.parseEnv("ANOTHER_API_KEY=sk-or-wrong") == nil, "Does not load a different service key")
        check(Credentials.parseEnv("OPENROUTER_API_KEY=$(touch /tmp/nope)") == nil, "Does not evaluate shell content")
        check(Credentials.parseEnv("OPENROUTER_API_KEY='sk-or-unterminated") == nil, "Rejects malformed credentials")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        let client = TranscriptionClient(session: URLSession(configuration: config))
        let audio = Data([0, 1, 2, 3, 4])
        MockProtocol.handler = { request in
            check(request.url == TranscriptionClient.endpoint, "Only OpenRouter endpoint")
            check(request.httpMethod == "POST", "POST method")
            check(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key", "Authentication")
            check(request.value(forHTTPHeaderField: "Content-Type") == "application/json", "JSON audio request")
            var body = request.httpBody
            if body == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096); var collected = Data()
                while stream.hasBytesAvailable { let read = stream.read(&bytes, maxLength: bytes.count); if read <= 0 { break }; collected.append(bytes, count: read) }
                body = collected
            }
            let json = try JSONSerialization.jsonObject(with: body!) as! [String: Any]
            check(json["model"] as? String == "microsoft/mai-transcribe-2", "Exact requested model")
            check(json["response_format"] as? String == "json", "Supported response format")
            check(json["provider"] == nil, "Only live-verified transcription parameters")
            let input = json["input_audio"] as! [String: String]
            check(input["format"] == "wav", "Audio format")
            check(Data(base64Encoded: input["data"]!) == audio, "Audio bytes round trip")
            return (200, Data("{\"text\":\"  Hello, world. \",\"usage\":{\"seconds\":1.2,\"cost\":0.0001}}".utf8))
        }
        let result = try await client.transcribe(audio: audio, format: "wav", key: "test-key")
        check(result.text == "Hello, world.", "Trim surrounding whitespace")
        check(result.usage?.cost == 0.0001, "Decode measured usage")
        for (status, message) in [(401,"rejected the key"),(403,"rejected the key"),(402,"needs credit"),(429,"busy"),(503,"unavailable"),(400,"HTTP 400"),(413,"too large")] {
            MockProtocol.handler = { _ in (status, Data("{\"error\":\"secret request detail\"}".utf8)) }
            await expectError(message) { _ = try await client.transcribe(audio: audio, format: "wav", key: "test") }
        }
        MockProtocol.handler = { _ in (200, Data("{\"text\":\"  \"}".utf8)) }
        await expectError("No speech") { _ = try await client.transcribe(audio: audio, format: "wav", key: "test") }
        MockProtocol.handler = { _ in (200, Data("<html>not json</html>".utf8)) }
        await expectError("unreadable") { _ = try await client.transcribe(audio: audio, format: "wav", key: "test") }
        MockProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await expectError("connection") { _ = try await client.transcribe(audio: audio, format: "wav", key: "test") }
        MockProtocol.handler = { _ in throw URLError(.timedOut) }
        await expectError("too long") { _ = try await client.transcribe(audio: audio, format: "wav", key: "test") }
        MockProtocol.handler = { _ in throw URLError(.cancelled) }
        do { _ = try await client.transcribe(audio: audio, format: "wav", key: "test"); check(false,"Cancellation") }
        catch { check(error is CancellationError, "Cancellation preserved") }
        await expectError("Add your") { _ = try await client.transcribe(audio: audio, format: "wav", key: "") }
        await expectError("empty") { _ = try await client.transcribe(audio: Data(), format: "wav", key: "test") }
        await expectError("isn't supported") { _ = try await client.transcribe(audio: audio, format: "exe", key: "test") }
        await expectError("isn't supported") { _ = try await client.transcribe(audio: audio, format: "m4a", key: "test") }
        await expectError("too large") { _ = try await client.transcribe(audio: Data(count: 24_000_001), format: "wav", key: "test") }
        try await dictionaryChecks(client: client, audio: audio)
        try await controllerChecks()
        try await modeFlowChecks()
        try await polishControllerChecks()
        try await polishClientChecks()
        try await shortcutChecks()
        try await localActionChecks()
        try await agentClientChecks()
        try await agentSessionChecks()
        try await voiceSettingsChecks()
        voiceActivityChecks()
        try await agentStreamChecks()
        try await cloudSpeechChecks()
        try await webSearchChecks()
        try await voiceFlowChecks()
        try await requestProgressChecks()
        try await codexCLIChecks()
        try await fullControlSessionChecks()
        print("PASS: \(checks) checks — dictation and agent controllers, recording, paste, dictionary, shortcuts, API contracts, reviewed actions and cancellation.")
    }
}
