import Foundation

extension CoreTests {
    static func voiceActivityChecks() {
        check(VoiceActivity.resolve(capture: .idle, assistant: .idle, speech: .idle) == .idle, "No work leaves voice feedback ready")
        check(VoiceActivity.resolve(capture: .listening, assistant: .thinking, speech: .idle) == .listening, "A new dictation owns feedback over a background answer")
        check(VoiceActivity.resolve(capture: .listening, assistant: .idle, speech: .preparing) == .listening, "Preparing old audio cannot hide active microphone capture")
        check(VoiceActivity.resolve(capture: .requestingMicrophone, assistant: .thinking, speech: .speaking) == .requestingMicrophone, "Permission stage remains visible when microphone access is needed")
        check(VoiceActivity.resolve(capture: .transcribing, assistant: .thinking, speech: .preparing) == .transcribing, "MAI feedback persists until current audio transcription finishes")
        check(VoiceActivity.resolve(capture: .polishing, assistant: .thinking, speech: .speaking) == .polishing, "Polish work owns its visible processing stage")
        check(VoiceActivity.polishing.pipelineStage == .assistant && VoiceActivity.polishing.showsSpinner && VoiceActivity.polishing.stopLabel == "Cancel polishing", "Polish exposes a running stage and cancellation without voice playback")
        check(VoiceActivity.resolve(capture: .idle, assistant: .thinking, speech: .speaking) == .speaking, "Audible streamed speech is visible while more text is generated")
        check(VoiceActivity.resolve(capture: .idle, assistant: .replying, speech: .speaking) == .speaking, "Streaming more tokens does not hide current playback")
        check(VoiceActivity.resolve(capture: .idle, assistant: .searching, speech: .preparing) == .searching, "Actual search activity stays visible during pipelined preparation")
        check(VoiceActivity.resolve(capture: .idle, assistant: .thinking, speech: .preparing) == .thinking, "Preparing an audio chunk does not falsely finish ongoing reasoning")
        check(VoiceActivity.resolve(capture: .idle, assistant: .replying, speech: .preparing) == .replying, "Streaming text keeps its own stage until audio is audible")
        check(VoiceActivity.resolve(capture: .idle, assistant: .idle, speech: .preparing) == .preparingVoice, "Finished answer exposes the cloud voice wait")
        check(VoiceActivity.resolve(capture: .idle, assistant: .idle, speech: .speaking) == .speaking, "Playback remains active after assistant generation has completed")
        check(VoiceActivity.resolve(capture: .idle, assistant: .reviewing, speech: .idle) == .reviewing, "Review is visible without pretending an action is running")
        check(VoiceActivity.resolve(capture: .idle, assistant: .running, speech: .idle) == .running, "Actual action execution has its own activity")
        check(VoiceActivity.resolve(capture: .idle, assistant: .thinking, speech: .idle) == .thinking, "Reasoning alone never claims a search occurred")
        check(VoiceActivity.idle.pipelineStage == nil && !VoiceActivity.idle.isActive, "An idle pipeline does not mark past steps completed")
        check(VoiceActivity.listening.pipelineStage == .microphone && VoiceActivity.transcribing.pipelineStage == .transcription, "Capture and MAI highlight separate stages")
        check(VoiceActivity.searching.pipelineStage == .assistant && VoiceActivity.searching.symbol == "globe", "Only observed search feedback uses the search branch icon")
        check(VoiceActivity.preparingVoice.pipelineStage == .voice && VoiceActivity.speaking.pipelineStage == .voice, "Preparation and playback share the voice stage")
        check(!VoiceActivity.reviewing.showsSpinner && !VoiceActivity.requestingMicrophone.showsSpinner, "Waiting for the user is not represented as ongoing computation")
        check(VoiceActivity.preparingVoice.showsSpinner && !VoiceActivity.speaking.showsSpinner, "Playback does not masquerade as a buffering spinner")
        check(VoiceActivity.transcribing.stopLabel == "Cancel transcription" && VoiceActivity.speaking.stopLabel == "Stop speaking", "Stop actions identify the work they will interrupt")
        check(VoiceActivity.reviewing.stopLabel == "Cancel pending action" && VoiceActivity.running.stopLabel == "Stop action", "Review cancellation and running action interruption remain distinct")
    }
}
