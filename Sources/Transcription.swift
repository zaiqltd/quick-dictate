import Foundation

struct DictationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Transcript: Decodable {
    let text: String
    let usage: Usage?
    struct Usage: Decodable { let seconds: Double?; let cost: Double? }
}

final class TranscriptionClient: SpeechTranscribing {
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!
    static let model = "microsoft/mai-transcribe-2"
    private let session: URLSession

    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 75
        config.urlCache = nil
        self.session = session ?? URLSession(configuration: config)
    }

    func transcribe(audio: Data, format: String, key: String, vocabulary: [String] = []) async throws -> Transcript {
        guard !key.isEmpty else { throw DictationError(message: "Add your OpenRouter key in Settings.") }
        guard !audio.isEmpty else { throw DictationError(message: "The recording was empty. Please try again.") }
        guard audio.count <= 24_000_000 else { throw DictationError(message: "That recording is too large. Try a shorter one.") }
        guard ["wav", "mp3", "flac"].contains(format) else {
            throw DictationError(message: "That audio format isn't supported.")
        }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Quick Dictate", forHTTPHeaderField: "X-Title")
        var body: [String: Any] = [
            "model": Self.model,
            "input_audio": ["data": audio.base64EncodedString(), "format": format],
            "response_format": "json"
        ]
        let phrases = try PersonalDictionary.validatedHints(vocabulary)
        if !phrases.isEmpty {
            body["provider"] = ["options": ["azure": ["phraseList": ["phrases": phrases]]]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw DictationError(message: "OpenRouter took too long. Your audio is ready to retry.") }
            throw DictationError(message: "Couldn't reach OpenRouter. Check your connection, then Retry.")
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw DictationError(message: "OpenRouter sent an unexpected response. Please retry.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message: String
            switch http.statusCode {
            case 401, 403: message = "OpenRouter rejected the key. Check it in Settings. Your audio is ready to retry."
            case 402: message = "Your OpenRouter account needs credit. Add credit, then Retry."
            case 413: message = "That recording is too large for OpenRouter. Try a shorter one."
            case 429: message = "OpenRouter is busy. Wait a moment, then Retry."
            case 500...599: message = "The transcription service is unavailable. Your audio is ready to retry."
            default: message = "OpenRouter couldn't transcribe this recording (HTTP \(http.statusCode)). Try again."
            }
            // Never surface arbitrary provider responses: they can contain request details.
            throw DictationError(message: message)
        }
        guard let result = try? JSONDecoder().decode(Transcript.self, from: data) else {
            throw DictationError(message: "OpenRouter sent an unreadable transcript. Your audio is ready to retry.")
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DictationError(message: "No speech was detected. Check your microphone and try again.") }
        return Transcript(text: text, usage: result.usage)
    }
}
