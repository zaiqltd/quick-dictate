import Foundation

// A shared presentation of real capture, request and playback state. Nothing
// here advances on a timer or guesses that a search ran because it was enabled.
enum VoiceActivity: String, CaseIterable, Equatable {
    case idle, requestingMicrophone, listening, transcribing, polishing
    case thinking, searching, replying, preparingVoice, speaking, reviewing, running

    enum Capture: Equatable { case idle, requestingMicrophone, listening, transcribing, polishing }
    enum Assistant: Equatable { case idle, thinking, searching, replying, reviewing, running }
    enum Speech: Equatable { case idle, preparing, speaking }
    enum PipelineStage: String, CaseIterable, Identifiable {
        case microphone, transcription, assistant, voice
        var id: String { rawValue }
        var title: String {
            switch self {
            case .microphone: return "Mic"
            case .transcription: return "MAI"
            case .assistant: return "Luna"
            case .voice: return "Voice"
            }
        }
        var symbol: String {
            switch self {
            case .microphone: return "mic"
            case .transcription: return "text.alignleft"
            case .assistant: return "sparkles"
            case .voice: return "speaker.wave.2"
            }
        }
    }

    static func resolve(capture: Capture, assistant: Assistant, speech: Speech) -> VoiceActivity {
        switch capture {
        case .requestingMicrophone: return .requestingMicrophone
        case .listening: return .listening
        case .transcribing: return .transcribing
        case .polishing: return .polishing
        case .idle: break
        }
        // With streamed answers, more text may be generated while earlier
        // audio is playing. Show what the user can actually hear.
        if speech == .speaking { return .speaking }
        switch assistant {
        case .thinking: return .thinking
        case .searching: return .searching
        case .replying: return .replying
        case .reviewing: return .reviewing
        case .running: return .running
        case .idle: break
        }
        return speech == .preparing ? .preparingVoice : .idle
    }

    var title: String {
        switch self {
        case .idle: return "Ready"
        case .requestingMicrophone: return "Allow microphone"
        case .listening: return "Listening"
        case .transcribing: return "Transcribing"
        case .polishing: return "Polishing"
        case .thinking: return "Thinking"
        case .searching: return "Searching"
        case .replying: return "Replying"
        case .preparingVoice: return "Preparing voice"
        case .speaking: return "Speaking"
        case .reviewing: return "Reviewing"
        case .running: return "Running"
        }
    }
    var symbol: String {
        switch self {
        case .idle: return "waveform"
        case .requestingMicrophone: return "mic.badge.plus"
        case .listening: return "mic.fill"
        case .transcribing: return "text.alignleft"
        case .polishing: return "sparkles"
        case .thinking: return "sparkles"
        case .searching: return "globe"
        case .replying: return "text.bubble"
        case .preparingVoice: return "waveform"
        case .speaking: return "speaker.wave.2.fill"
        case .reviewing: return "hand.raised"
        case .running: return "terminal"
        }
    }
    var isActive: Bool { self != .idle }
    var showsSpinner: Bool {
        switch self {
        case .transcribing, .polishing, .thinking, .searching, .replying, .preparingVoice, .running: return true
        default: return false
        }
    }
    var stopLabel: String {
        switch self {
        case .idle: return "Stop"
        case .requestingMicrophone: return "Cancel microphone request"
        case .listening: return "Cancel recording"
        case .transcribing: return "Cancel transcription"
        case .polishing: return "Cancel polishing"
        case .thinking, .searching, .replying: return "Stop request"
        case .preparingVoice: return "Cancel voice preparation"
        case .speaking: return "Stop speaking"
        case .reviewing: return "Cancel pending action"
        case .running: return "Stop action"
        }
    }
    var pipelineStage: PipelineStage? {
        switch self {
        case .idle: return nil
        case .requestingMicrophone, .listening: return .microphone
        case .transcribing: return .transcription
        case .polishing, .thinking, .searching, .replying, .reviewing, .running: return .assistant
        case .preparingVoice, .speaking: return .voice
        }
    }
}
