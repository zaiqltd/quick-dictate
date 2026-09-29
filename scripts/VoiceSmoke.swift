import AppKit
import Foundation

@MainActor private final class MeasuredSpeech: SpeechOutput {
    let output = CloudSpeechOutput()
    let started: Date
    var firstSpeech: TimeInterval?
    var states: [String] = []
    var calls = 0
    var synthesisMetrics: [[String: Double]] = []
    var playbackStarts: [Double] = []
    var playbackFinishes: [Double] = []
    init(started: Date) { self.started = started }
    func speak(_ text: String, key: String, onState: @escaping @MainActor (SpeechOutputState) -> Void) async throws {
        calls += 1
        try await output.speak(text, key: key) { state in
            self.states.append(String(describing: state))
            if state == .speaking, self.firstSpeech == nil { self.firstSpeech = Date().timeIntervalSince(self.started) }
            if state == .speaking { self.playbackStarts.append(Date().timeIntervalSince(self.started)) }
            onState(state)
        }
        playbackFinishes.append(Date().timeIntervalSince(started))
        if let metrics = output.lastMetrics {
            synthesisMetrics.append(["first_byte_seconds": metrics.firstByteSeconds,
                                     "request_seconds": metrics.requestSeconds, "audio_seconds": metrics.audioSeconds])
        }
    }
    func prefetch(_ text: String, key: String) { output.prefetch(text, key: key) }
    func stop() { output.stop() }
}

@main struct VoiceSmoke {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3, ["--live-audio", "--live-text"].contains(args[1]) else { print("Usage: VoiceSmoke --live-audio public-question.wav | --live-text public-question"); return }
        let key = Credentials.load() ?? ""
        let started = Date()
        let text: String
        if args[1] == "--live-audio" {
            text = try await TranscriptionClient().transcribe(audio: Data(contentsOf: URL(fileURLWithPath: args[2])), format: "wav", key: key, vocabulary: []).text
        } else { text = args[2] }
        let transcriptionSeconds = Date().timeIntervalSince(started)
        let suite = "quick-dictate-voice-smoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = FeatureSettings(defaults: defaults)
        try settings.update { $0.askEnabled = true; $0.webSearchEnabled = true; $0.speakReplies = true }
        let speech = MeasuredSpeech(started: started)
        let session = AgentSession(settings: settings, loadKey: { key }, speech: speech)
        guard session.send(text, mode: .ask, spoken: true) else { throw DictationError(message: session.error) }
        let deadline = Date().addingTimeInterval(90)
        while (session.isBusy || session.speechState != .idle), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard !session.isBusy, session.speechState == .idle, session.error.isEmpty, speech.firstSpeech != nil else {
            session.cancel(); throw DictationError(message: "Voice smoke failed: \(session.error)")
        }
        let payload: [String: Any] = ["transcript": text, "model": settings.options.model,
            "tts_model": "qwen/qwen-audio-3.0-tts-plus", "transcription_seconds": transcriptionSeconds,
            "first_audio_seconds_from_upload": speech.firstSpeech!, "full_playback_seconds_from_upload": Date().timeIntervalSince(started),
            "speech_requests": speech.calls, "playback_states": speech.states,
            "synthesis_metrics": speech.synthesisMetrics,
            "playback_starts": speech.playbackStarts, "playback_finishes": speech.playbackFinishes,
            "search_sources": session.turns.flatMap(\.sources).map { $0.url.absoluteString },
            "answer": session.turns.last(where: { $0.role == .assistant })?.text ?? "", "activity": session.activityLog]
        print(String(data: try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
}
