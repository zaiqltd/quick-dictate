import AppKit
import AVFoundation
import Foundation

private final class TestRecorder: AudioRecording {
    var onFailure: ((String) -> Void)?
    var elapsed: TimeInterval = 1
    var level = 0.5
    var starts = 0
    var finishes = 0
    var discards = 0
    var startError = false
    var finishError = false
    let bytes = Data([82, 73, 70, 70, 1, 2, 3])
    func start() throws {
        starts += 1
        if startError { throw DictationError(message: "Test microphone unavailable") }
    }
    func finish() throws -> Data {
        finishes += 1
        if finishError { throw DictationError(message: "Test recording unreadable") }
        return bytes
    }
    func discard() { discards += 1 }
}

private final class TestTranscriber: SpeechTranscribing {
    struct Request { let audio: Data; let format: String; let vocabulary: [String] }
    var requests: [Request] = []
    private var pending: [CheckedContinuation<Transcript, Error>] = []
    func transcribe(audio: Data, format: String, key: String, vocabulary: [String]) async throws -> Transcript {
        requests.append(Request(audio: audio, format: format, vocabulary: vocabulary))
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func succeed(_ text: String) { pending.removeFirst().resume(returning: Transcript(text: text, usage: nil)) }
    func fail(_ error: Error = DictationError(message: "Test network unavailable")) { pending.removeFirst().resume(throwing: error) }
}

private final class FlowTestPolisher: TextPolishing {
    struct Request { let text: String; let key: String }
    var requests: [Request] = []
    private var pending: [CheckedContinuation<String, Error>] = []
    func polish(_ text: String, key: String) async throws -> String {
        requests.append(Request(text: text, key: key))
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func succeed(_ text: String) { pending.removeFirst().resume(returning: text) }
    func fail(_ error: Error = DictationError(message: "Test polish unavailable")) { pending.removeFirst().resume(throwing: error) }
}

@MainActor private final class FlowTestSpeech: SpeechOutput {
    var spoken: [String] = []
    func speak(_ text: String, key: String, onState: @escaping @MainActor (SpeechOutputState) -> Void) async throws {
        spoken.append(text)
        onState(.preparing); onState(.speaking); onState(.idle)
    }
    func stop() {}
}

private final class FlowTestSearch: WebSearching {
    var queries: [String] = []
    func search(_ query: String, key: String) async throws -> WebSearchResult {
        queries.append(query)
        return WebSearchResult(summary: "Fixture search result.", sources: [])
    }
}

private final class FlowTestAgent: AgentResponding {
    var requests: [[[String: Any]]] = []
    var delayed = false
    var continuation: CheckedContinuation<Void, Never>?
    func finish() { continuation?.resume(); continuation = nil }
    func respond(messages: [[String: Any]], model: String, key: String, tools: [[String: Any]]) async throws -> AgentReply {
        requests.append(messages)
        if delayed { await withCheckedContinuation { continuation = $0 } }
        return AgentReply(text: "Test reply.", toolCalls: [], assistantMessage: ["role": "assistant", "content": "Test reply."])
    }
}

@MainActor private final class FlowTestCodex: CodexRunning {
    var prompts: [String] = []
    func run(prompt: String, workingDirectory: URL, screenControl: Bool,
             onEvent: @escaping @MainActor (CodexRunEvent) -> Void) async throws -> CodexRunResult {
        prompts.append(prompt); onEvent(.started)
        return CodexRunResult(finalText: "Codex fixture reply.", exitCode: 0, truncated: false)
    }
}

@MainActor private final class ControllerFixture {
    let recorder = TestRecorder()
    let client = TestTranscriber()
    let polisher = FlowTestPolisher()
    let speech = FlowTestSpeech()
    let search = FlowTestSearch()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quick-dictate-controller-tests-\(UUID().uuidString)")
    var key: String? = "test-only-key"
    var authorization: AVAuthorizationStatus = .authorized
    var permissionCompletion: (@Sendable (Bool) -> Void)?
    var target = DictationTarget(pid: 77, element: nil)
    var pasteSucceeds = true
    var copies: [String] = []
    var insertions: [(text: String, pid: pid_t?)] = []
    var app: DictationApp!
    let suite = "quick-dictate-flow-tests.\(UUID().uuidString)"
    let agentClient = FlowTestAgent()
    let codex = FlowTestCodex()
    var defaults: UserDefaults!
    var features: FeatureSettings!
    var contextReads = 0
    var targetReads = 0
    var context = "Selected test paragraph"

    init() {
        defaults = UserDefaults(suiteName: suite)!
        features = FeatureSettings(defaults: defaults)
        let services = DictationServices(
            loadKey: { [weak self] in self?.key },
            microphoneStatus: { [weak self] in self?.authorization ?? .denied },
            requestMicrophone: { [weak self] in self?.permissionCompletion = $0 },
            captureTarget: { [weak self] in self?.targetReads += 1; return self?.target ?? DictationTarget(pid: nil, element: nil) },
            insert: { [weak self] text, target in
                guard let self else { return false }
                self.copies.append(text)
                self.insertions.append((text, target.pid))
                return self.pasteSucceeds && target.pid != nil
            },
            copy: { [weak self] in self?.copies.append($0) },
            selectedContext: { [weak self] in self?.contextReads += 1; return self?.context }
        )
        app = DictationApp(recorder: recorder, client: client, polisher: polisher, services: services,
                           dictionary: PersonalDictionary(url: directory.appendingPathComponent("dictionary.json")),
                           features: features, agent: AgentSession(settings: features, client: agentClient, loadKey: { "test-only-key" }, speech: speech, search: search, codex: codex))
        app.autoPaste = true
    }
    func close() { app.cancel(); app.agent.cancel(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
}

extension CoreTests {
    @MainActor static func eventually(_ label: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        check(predicate(), label)
    }

    @MainActor static func modeFlowChecks() async throws {
        do {
            let f = ControllerFixture(); defer { f.close() }
            f.app.beginHold(.shortcut, mode: .ask)
            check(f.recorder.starts == 0, "Disabled Ask never starts microphone")
            f.app.beginHold(.shortcut, mode: .act)
            check(f.recorder.starts == 0, "Disabled Do never starts microphone")
            f.app.beginHold(.shortcut, mode: .fullControl)
            check(f.recorder.starts == 0, "Disabled Full Control never starts microphone")
            f.app.beginHold(.shortcut, mode: .dictation); f.app.endHold(.shortcut)
            try await eventually("Dictation transcribes with modes off") { f.client.requests.count == 1 }
            f.client.succeed("Only dictation.")
            try await eventually("Dictation pastes") { f.app.phase == .idle }
            check(f.agentClient.requests.isEmpty, "Dictation never invokes assistant")
            check(f.contextReads == 0, "Default dictation never reads selected context")
        }
        for mode in [VoiceMode.ask, .act, .fullControl] {
            let f = ControllerFixture(); defer { f.close() }
            try f.features.update { $0.askEnabled = true; $0.actEnabled = true; $0.fullControlEnabled = true }
            f.app.lastText = "Prior dictation."
            f.app.beginHold(.shortcut, mode: mode)
            check(f.app.activeMode == mode && f.app.phase == .recording, "Enabled mode routes microphone")
            f.app.endHold(.shortcut)
            try await eventually("Agent voice uses transcription") { f.client.requests.count == 1 }
            f.client.succeed("Explain this test.")
            try await eventually("Voice reaches assistant") {
                (mode == .fullControl ? f.codex.prompts.count == 1 : f.agentClient.requests.count == 1) && !f.app.agent.isBusy
            }
            check(mode == .fullControl ? f.agentClient.requests.isEmpty : f.codex.prompts.isEmpty, "Transcription reaches only the selected assistant provider")
            check(f.copies.isEmpty && f.insertions.isEmpty, "Agent voice never writes to clipboard or pastes")
            check(f.app.lastText == "Prior dictation.", "Assistant keeps last dictation")
            check(f.contextReads == 0, "Selected context requires explicit opt-in")
            check(f.app.agent.turns.first?.text == "Explain this test.", "Recognized text becomes visible user request")
        }
        do {
            let f = ControllerFixture(); defer { f.close() }
            try f.features.update { $0.askEnabled = true; $0.useSelectedText = true }
            f.app.beginHold(.shortcut, mode: .ask)
            check(f.contextReads == 1, "Selected context captured at press with opt-in")
            f.context = "Later selection must not leak"
            f.app.endHold(.shortcut)
            try await eventually("Selection voice request started") { f.client.requests.count == 1 }
            f.client.succeed("Summarize selection.")
            try await eventually("Selection voice reached assistant") { f.agentClient.requests.count == 1 }
            let message = f.agentClient.requests[0].last?["content"] as? String ?? ""
            check(message.contains("Selected test paragraph") && !message.contains("Later selection"), "Request snapshots original selection")
        }
        do {
            let f = ControllerFixture(); defer { f.close() }
            try f.features.update { $0.askEnabled = true }
            f.app.beginHold(.shortcut, mode: .ask); f.app.endHold(.shortcut)
            try await eventually("Transcription pending before disabling mode") { f.client.requests.count == 1 }
            try f.features.update { $0.askEnabled = false }
            f.client.succeed("Stale request")
            try await Task.sleep(nanoseconds: 10_000_000)
            check(f.app.activeMode == .dictation && f.app.phase == .idle, "Disabled active mode returns to dictation")
            check(f.agentClient.requests.isEmpty && f.copies.isEmpty, "Disabling mode ignores delayed transcription")
        }
        do {
            let f = ControllerFixture(); defer { f.close() }
            try f.features.update { $0.askEnabled = true }
            f.app.beginHold(.shortcut, mode: .ask); f.app.endHold(.shortcut)
            try await eventually("Voice pending before other request") { f.client.requests.count == 1 }
            f.agentClient.delayed = true
            f.app.agent.send("Typed question.", mode: .ask)
            try await eventually("Typed question starts") { f.agentClient.requests.count == 1 }
            f.client.succeed("Spoken question.")
            try await eventually("Busy handoff completes without losing audio") { f.app.phase == .idle }
            check(f.app.retryAvailable && f.app.error.contains("busy"), "Busy assistant preserves spoken recording for retry")
            f.app.retry()
            check(f.client.requests.count == 1, "Busy Retry avoids another transcription charge")
            f.agentClient.delayed = false; f.agentClient.finish()
            try await eventually("Typed answer completes") { !f.app.agent.isBusy }
            f.app.retry()
            try await eventually("Voice can retry after assistant completes") { f.client.requests.count == 2 }
            f.client.succeed("Spoken question.")
            try await eventually("Retried voice reaches assistant") { f.agentClient.requests.count == 2 }
            check(f.app.agent.turns.contains(where: { $0.text == "Spoken question." }), "No spoken request lost during busy race")
        }
        do {
            let f = ControllerFixture(); defer { f.close() }
            try f.features.update { $0.askEnabled = true }
            f.app.beginHold(.shortcut, mode: .ask); f.app.endHold(.shortcut)
            try await eventually("Failed assistant voice upload starts") { f.client.requests.count == 1 }
            f.client.fail()
            try await eventually("Failed assistant audio can retry") { f.app.retryAvailable }
            try f.features.update { $0.askEnabled = false }
            f.app.retry()
            check(!f.app.retryAvailable && f.client.requests.count == 1, "Disabling mode discards its retry audio")
        }
    }

    @MainActor static func polishControllerChecks() async throws {
        do {
            let f = ControllerFixture(); defer { f.close() }
            f.app.beginHold(.shortcut, mode: .polish)
            f.app.polishDraft = "A rough draft."
            f.app.polishTypedText()
            check(f.recorder.starts == 0 && f.polisher.requests.isEmpty && f.client.requests.isEmpty,
                  "Disabled Polish cannot record, transcribe or rewrite")
            check(f.copies.isEmpty && f.insertions.isEmpty, "Disabled Polish cannot alter another app or clipboard")
        }
        do {
            let f = ControllerFixture(); defer { f.close() }
            try f.features.update { $0.polishEnabled = true; $0.useSelectedText = true }
            try f.app.dictionary.remember(preferred: "CueLoom")
            f.app.lastText = "Previous literal dictation."
            f.app.beginHold(.shortcut, mode: .polish)
            check(f.app.activeMode == .polish && f.app.phase == .recording, "Polish hold starts the selected mode")
            f.app.endHold(.shortcut)
            try await eventually("Polish first requests MAI transcription") { f.client.requests.count == 1 }
            check(f.client.requests[0].audio == f.recorder.bytes && f.client.requests[0].vocabulary == ["CueLoom"],
                  "Polish transcribes the recording with the existing personal vocabulary")
            check(f.polisher.requests.isEmpty, "Polish waits for MAI before rewriting")
            f.target = DictationTarget(pid: 99, element: nil)
            f.client.succeed("Um CueLoom is, like, ready for Friday.")
            try await eventually("MAI result starts the polishing stage") { f.polisher.requests.count == 1 }
            check(f.app.phase == .polishing, "A pending rewrite exposes a distinct polishing stage")
            check(f.app.polishOriginal == "Um CueLoom is, like, ready for Friday.", "Polish retains the exact MAI original")
            check(f.polisher.requests[0].text == f.app.polishOriginal && f.polisher.requests[0].key == "test-only-key",
                  "Polisher receives only the transcribed text and injected credential")
            check(f.copies.isEmpty && f.insertions.isEmpty, "Raw MAI text is never delivered before Polish completes")
            check(f.contextReads == 0, "Polish never captures selected-text context even when assistant context is enabled")
            f.polisher.succeed("CueLoom is ready for Friday.")
            try await eventually("Polished voice result completes") { f.app.phase == .idle }
            check(f.app.polishedText == "CueLoom is ready for Friday." && f.app.polishOriginal == "Um CueLoom is, like, ready for Friday.",
                  "Original and polished voice result remain separately recoverable")
            check(f.insertions.count == 1 && f.insertions[0].pid == 77 && f.copies == ["CueLoom is ready for Friday."],
                  "Polish pastes only the rewritten result once into the original target")
            check(f.agentClient.requests.isEmpty && f.codex.prompts.isEmpty && f.app.agent.turns.isEmpty && f.speech.spoken.isEmpty && f.search.queries.isEmpty,
                  "Polish does not start chat, Codex, assistant history, speech or web search")
            check(f.app.lastText == "Previous literal dictation.", "Polish preserves the separate literal dictation result")
        }
        do {
            let f = ControllerFixture(); defer { f.close() }
            try f.features.update { $0.polishEnabled = true }
            f.app.autoPaste = false
            f.app.beginHold(.shortcut, mode: .polish); f.app.endHold(.shortcut)
            try await eventually("Copy-only Polish requests transcription") { f.client.requests.count == 1 }
            f.client.succeed("It is like ready.")
            try await eventually("Copy-only Polish requests rewrite") { f.polisher.requests.count == 1 }
            f.polisher.succeed("It is ready.")
            try await eventually("Copy-only Polish completes") { f.app.phase == .idle }
            check(f.insertions.isEmpty && f.copies == ["It is ready."], "Polish respects the copy-only delivery setting")
        }
        do {
            let f = ControllerFixture(); defer { f.close() }
            try f.features.update { $0.polishEnabled = true }
            f.app.polishDraft = "Can we, um, move the thing to Friday?"
            f.app.polishTypedText()
            try await eventually("Typed draft starts Polish") { f.polisher.requests.count == 1 }
            check(f.app.activeMode == .polish && f.app.phase == .polishing, "Typed Polish selects its own mode and visible stage")
            check(f.recorder.starts == 0 && f.client.requests.isEmpty && f.targetReads == 0 && f.contextReads == 0,
                  "Typed Polish reads no microphone, target app or selection")
            f.app.polishDraft = "A draft written while the first one processes."
            f.app.polishTypedText()
            check(f.polisher.requests.count == 1, "A second typed submission cannot overlap a pending rewrite")
            f.polisher.succeed("Can we move it to Friday?")
            try await eventually("Typed Polish displays result") { f.app.phase == .idle }
            check(f.app.feedbackDetail.isEmpty && f.app.voiceActivity == .idle, "Completed Polish cannot inherit a stopped assistant's status")
            check(f.app.polishOriginal == "Can we, um, move the thing to Friday?", "Typed Polish snapshots the submitted draft")
            check(f.app.polishedText == "Can we move it to Friday?" && f.copies.isEmpty && f.insertions.isEmpty,
                  "Typed result is displayed without automatic copy or paste")
            f.app.copyPolishedText()
            f.app.restorePolishOriginal()
            check(f.copies == ["Can we move it to Friday?", "Can we, um, move the thing to Friday?"] && f.insertions.isEmpty,
                  "Explicit result and original buttons copy their own text without replacing another app's content")
            check(f.app.polishedText == "Can we move it to Friday?", "Recovering the original preserves the polished result")
            check(f.agentClient.requests.isEmpty && f.codex.prompts.isEmpty && f.speech.spoken.isEmpty,
                  "Typed Polish is not treated as an assistant question")
        }
        do {
            let f = ControllerFixture(); defer { f.close() }
            try f.features.update { $0.polishEnabled = true }
            f.app.beginHold(.shortcut, mode: .polish); f.app.endHold(.shortcut)
            try await eventually("Failing voice Polish transcribes once") { f.client.requests.count == 1 }
            f.client.succeed("Um keep the original please.")
            try await eventually("Failing voice Polish reaches rewrite") { f.polisher.requests.count == 1 }
            f.polisher.fail()
            try await eventually("Rewrite failure returns usable idle state") { f.app.phase == .idle && !f.app.error.isEmpty }
            check(f.app.polishOriginal == "Um keep the original please." && f.app.polishedText.isEmpty,
                  "Failed rewrite retains the original without inventing a result")
            check(f.copies.isEmpty && f.insertions.isEmpty, "Failed rewrite never silently delivers the raw transcript")
            f.target = DictationTarget(pid: 99, element: nil)
            f.app.retryPolish()
            try await eventually("Rewrite retry reuses the original") { f.polisher.requests.count == 2 }
            check(f.client.requests.count == 1 && f.polisher.requests[1].text == "Um keep the original please.",
                  "Rewrite retry avoids another MAI request and retains exact input")
            f.polisher.succeed("Keep the original, please.")
            try await eventually("Rewrite retry completes") { f.app.phase == .idle }
            check(f.copies == ["Keep the original, please."] && f.insertions.isEmpty,
                  "Voice rewrite retry copies without pasting into the old or current app")
        }
        do {
            let f = ControllerFixture(); defer { f.close() }
            try f.features.update { $0.polishEnabled = true }
            f.app.polishDraft = "Please, like, move it."
            f.app.polishTypedText()
            try await eventually("Typed failure reaches rewrite") { f.polisher.requests.count == 1 }
            f.polisher.fail(CancellationError())
            try await eventually("Unexpected rewrite interruption returns idle") { f.app.phase == .idle && !f.app.error.isEmpty }
            f.app.retryPolish()
            try await eventually("Typed rewrite can retry after interruption") { f.polisher.requests.count == 2 }
            f.polisher.succeed("Please move it.")
            try await eventually("Typed retry completes") { f.app.phase == .idle }
            check(f.app.polishedText == "Please move it." && f.copies.isEmpty && f.insertions.isEmpty,
                  "Typed retry still only displays the result")
        }
        do {
            let f = ControllerFixture(); defer { f.close() }
            try f.features.update { $0.polishEnabled = true }
            f.app.beginHold(.shortcut, mode: .polish); f.app.endHold(.shortcut)
            try await eventually("Polish transcription can be cancelled") { f.client.requests.count == 1 }
            f.app.cancel(); f.client.succeed("A cancelled transcription.")
            try await Task.sleep(nanoseconds: 10_000_000)
            check(f.app.phase == .idle && f.polisher.requests.isEmpty && f.app.polishOriginal.isEmpty && f.copies.isEmpty,
                  "Cancelled MAI response cannot begin polishing or change the original")
        }
        do {
            let f = ControllerFixture(); defer { f.close() }
            try f.features.update { $0.polishEnabled = true }
            f.app.polishDraft = "An old um draft."
            f.app.polishTypedText()
            try await eventually("Old rewrite starts") { f.polisher.requests.count == 1 }
            f.app.cancel()
            f.app.polishDraft = "A new um draft."
            f.app.polishTypedText()
            try await eventually("New rewrite starts after cancellation") { f.polisher.requests.count == 2 }
            f.polisher.succeed("Old draft.")
            try await Task.sleep(nanoseconds: 10_000_000)
            check(f.app.phase == .polishing && f.app.polishOriginal == "A new um draft." && f.app.polishedText.isEmpty,
                  "Late cancelled rewrite cannot complete or overwrite the newer request")
            check(f.copies.isEmpty && f.insertions.isEmpty, "Late cancelled rewrite cannot deliver text")
            f.polisher.succeed("New draft.")
            try await eventually("Newest rewrite finishes") { f.app.phase == .idle }
            check(f.app.polishedText == "New draft.", "Only the current rewrite updates the result")
        }
        do {
            let f = ControllerFixture(); defer { f.close() }
            try f.features.update { $0.polishEnabled = true }
            f.app.beginHold(.shortcut, mode: .polish); f.app.endHold(.shortcut)
            try await eventually("Disabling test reaches transcription") { f.client.requests.count == 1 }
            f.client.succeed("Do not paste after disabling.")
            try await eventually("Disabling test reaches rewrite") { f.polisher.requests.count == 1 }
            try f.features.update { $0.polishEnabled = false }
            f.polisher.succeed("Do not paste after disabling.")
            try await Task.sleep(nanoseconds: 10_000_000)
            check(f.app.phase == .idle && f.app.activeMode == .dictation && f.app.polishedText.isEmpty,
                  "Disabling Polish cancels its rewrite and restores Dictate")
            check(f.copies.isEmpty && f.insertions.isEmpty, "Disabled Polish ignores pending delivery")
            f.app.retryPolish()
            check(f.polisher.requests.count == 1, "Disabled Polish cannot restart through Retry")
        }
        do {
            let f = ControllerFixture(); defer { f.close() }
            try f.features.update { $0.polishEnabled = true }
            f.app.beginHold(.shortcut, mode: .polish); f.app.endHold(.shortcut)
            try await eventually("Polish transcription failure starts request") { f.client.requests.count == 1 }
            f.client.fail()
            try await eventually("Polish transcription failure retains retry audio") { f.app.phase == .idle && f.app.retryAvailable }
            f.app.selectMode(.dictation)
            f.app.retry()
            try await eventually("Polish audio retry starts after changing tab") { f.client.requests.count == 2 }
            check(f.app.activeMode == .polish, "Retry keeps the original Polish mode visible after tab changes")
            f.client.succeed("Retry um this recording.")
            try await eventually("Retried MAI audio routes to Polish") { f.polisher.requests.count == 1 }
            f.polisher.succeed("Retry this recording.")
            try await eventually("Retried Polish audio completes") { f.app.phase == .idle }
            check(f.copies == ["Retry this recording."] && f.insertions.allSatisfy({ $0.pid == nil }),
                  "Retried Polish audio cannot paste into the original or current app")
            check(f.agentClient.requests.isEmpty && f.codex.prompts.isEmpty,
                  "Polish retry cannot become an assistant request after switching tabs")
        }
        for input in ["", "  \n  "] {
            let f = ControllerFixture(); defer { f.close() }
            try f.features.update { $0.polishEnabled = true }
            f.app.polishDraft = input; f.app.polishTypedText()
            check(f.app.phase == .idle && f.polisher.requests.isEmpty, "Blank typed input never starts a rewrite")
        }
        do {
            let f = ControllerFixture(); defer { f.close() }
            try f.features.update { $0.polishEnabled = true }
            f.key = nil; f.app.polishDraft = "A usable draft."
            f.app.polishTypedText()
            check(f.app.phase == .idle && !f.app.error.isEmpty && f.polisher.requests.isEmpty,
                  "Missing credentials fail visibly without consuming or sending the typed draft")
        }
    }

    @MainActor static func controllerChecks() async throws {
        do {
            let f = ControllerFixture(); defer { f.close() }
            let original = f.app.phaseStartedAt
            f.app.phase = .idle
            check(f.app.phaseStartedAt == original, "Repeated phase assignment does not restart the visible timer")
            let beforeCapture = Date()
            f.app.phase = .transcribing
            check(f.app.phaseStartedAt >= beforeCapture, "A new capture stage starts its own visible timer")
            let transcribing = f.app.phaseStartedAt
            f.app.phase = .transcribing
            check(f.app.phaseStartedAt == transcribing, "Transcription status refresh preserves its elapsed wait")
            f.app.phase = .idle
            f.app.status = "Paste sent · also copied"
            f.app.activeMode = .ask
            check(!f.app.statusLine.contains("Paste sent"), "Ask cannot show a previous dictation's paste status")
            f.app.status = "Recording kept for Retry."; f.app.retryAvailable = true
            check(f.app.statusLine == f.app.status, "Assistant retry status remains visible")
            f.app.retryAvailable = false; f.app.error = "Fixture error"
            check(f.app.statusLine == f.app.status, "Assistant error recovery status remains visible")
        }
        do {
            let f = ControllerFixture(); defer { f.close() }
            let hotkey = GlobalHotkey()
            hotkey.onPress = { f.app.beginHold(.shortcut) }
            hotkey.onRelease = { f.app.endHold(.shortcut) }
            hotkey.onCancel = { f.app.cancelHold(.shortcut) }
            hotkey.process(flags: .option, keyDown: false)
            hotkey.process(flags: [.option, .command], keyDown: false)
            check(f.app.phase == .recording, "Shortcut listener reaches the recording controller")
            hotkey.process(flags: .option, keyDown: false)
            hotkey.process(flags: [], keyDown: false)
            try await eventually("Listener release starts upload") { f.client.requests.count == 1 }
            f.client.succeed("First hold.")
            try await eventually("First shortcut completes") { f.app.phase == .idle }
            // Cmd-V has a command flag but does not physically hold that modifier.
            // No OS events are posted here: this is the listener's input boundary.
            hotkey.process(flags: .command, keyDown: true, sourceTag: Paste.eventTag)
            hotkey.process(flags: .option, keyDown: false)
            hotkey.process(flags: [.option, .command], keyDown: false)
            check(f.app.phase == .recording && f.recorder.starts == 2, "Automatic paste cannot block the next shortcut hold")
            hotkey.process(flags: [.option, .command], keyDown: true)
            hotkey.process(flags: [], keyDown: false)
            check(f.app.phase == .idle && f.client.requests.count == 1, "Real extra key still cancels without upload")
        }
        // These exercise the production controller, so putting a sheet guard back
        // into beginHold makes the regression fail even if ModifierChord still passes.
        for screen in ["main", "settings", "words", "correction"] {
            let f = ControllerFixture(); defer { f.close() }
            if screen == "settings" { f.app.showSettings() }
            if screen == "words" { f.app.showDictionary() }
            if screen == "correction" { f.app.lastText = "Open QLume."; f.app.showCorrection() }
            f.app.beginHold(.shortcut)
            check(f.app.phase == .recording && f.recorder.starts == 1, "Hold starts from \(screen)")
            f.app.beginHold(.shortcut)
            check(f.recorder.starts == 1, "Repeated press cannot start a second microphone from \(screen)")
            f.app.endHold(.shortcut)
            check(f.app.phase == .transcribing && f.recorder.finishes == 1, "Release starts transcription from \(screen)")
            try await eventually("One request from \(screen)") { f.client.requests.count == 1 }
            check(f.client.requests[0].audio == f.recorder.bytes && f.client.requests[0].format == "wav", "Actual recorded bytes are submitted from \(screen)")
            f.client.succeed("Test dictation.")
            try await eventually("Returns idle from \(screen)") { f.app.phase == .idle }
            check(f.app.lastText == "Test dictation." && f.insertions.count == 1 && f.insertions[0].pid == 77, "One result and one paste to original target from \(screen)")
            if screen == "words" { check(f.app.dictionarySheet == .words, "Dictation preserves open dictionary") }
            if screen == "correction" {
                try f.app.rememberCorrection(heard: "QLume", preferred: "CueLoom")
                check(f.app.lastText == "Open CueLoom." && f.copies.last == "Open CueLoom.", "Pending correction still applies to its original transcript")
                check(f.app.dictionary.hints == ["CueLoom"], "Controller persists explicit correction")
            }
        }

        do {
            let f = ControllerFixture(); defer { f.close() }
            f.app.beginHold(.button)
            f.app.endHold(.shortcut)
            check(f.app.phase == .recording && f.recorder.finishes == 0, "Shortcut release cannot stop mouse recording")
            f.app.cancelHold(.shortcut)
            check(f.app.phase == .recording, "Unrelated shortcut cancellation cannot stop mouse recording")
            f.app.cancelHold(.button)
            check(f.app.phase == .idle && f.client.requests.isEmpty && f.recorder.discards > 0, "Cancelling discards without upload")
            f.app.beginHold(.shortcut)
            check(f.app.phase == .recording && f.recorder.starts == 2, "Recording works immediately after cancellation")
        }
        do {
            let f = ControllerFixture(); defer { f.close() }
            f.app.beginHold(.accessibility)
            f.app.endHold(.button); f.app.endHold(.shortcut)
            check(f.app.phase == .recording, "Mouse/shortcut release cannot stop an accessibility recording")
            f.app.endHold(.accessibility)
            try await eventually("Accessibility finish submits recording") { f.client.requests.count == 1 }
            f.client.succeed("Accessible dictation.")
            try await eventually("Accessibility recording completes") { f.app.phase == .idle }
        }
        do {
            let f = ControllerFixture(); defer { f.close() }
            f.recorder.elapsed = 0.1
            f.app.beginHold(.shortcut); f.app.endHold(.shortcut)
            check(f.app.phase == .idle && f.client.requests.isEmpty, "Accidental short hold never uploads")
            f.app.endHold(.shortcut)
            check(f.recorder.finishes == 1, "Repeated release cannot finish twice")
        }
        do {
            let f = ControllerFixture(); defer { f.close() }
            f.authorization = .notDetermined
            f.app.beginHold(.shortcut)
            check(f.app.phase == .requestingMic && f.recorder.starts == 0, "First hold waits for microphone permission")
            f.app.endHold(.shortcut)
            f.authorization = .authorized; f.permissionCompletion?(true)
            try await Task.sleep(nanoseconds: 10_000_000)
            check(f.app.phase == .idle && f.recorder.starts == 0, "Late permission after release never starts recording")
            f.app.beginHold(.shortcut)
            check(f.app.phase == .recording, "Next hold works after permission grant")
        }
        do {
            let f = ControllerFixture(); defer { f.close() }
            f.authorization = .notDetermined; f.app.beginHold(.shortcut)
            f.authorization = .authorized; f.permissionCompletion?(true)
            try await eventually("Permission while still held starts recording") { f.app.phase == .recording }
        }
        for failure in ["key", "permission", "secure field", "microphone start", "microphone read"] {
            let f = ControllerFixture(); defer { f.close() }
            if failure == "key" { f.key = nil }
            if failure == "permission" { f.authorization = .denied }
            if failure == "secure field" { f.target.isSecure = true }
            if failure == "microphone start" { f.recorder.startError = true }
            if failure == "microphone read" { f.recorder.finishError = true }
            f.app.beginHold(.shortcut); f.app.endHold(.shortcut)
            check(f.app.phase == .idle && !f.app.error.isEmpty && f.client.requests.isEmpty, "\(failure) fails visibly without upload")
            f.key = "test-only-key"; f.authorization = .authorized; f.target.isSecure = false
            f.recorder.startError = false; f.recorder.finishError = false
            f.app.beginHold(.shortcut)
            check(f.app.phase == .recording, "Next hold recovers after \(failure)")
        }
        do {
            let f = ControllerFixture(); defer { f.close() }
            f.app.beginHold(.shortcut); f.app.endHold(.shortcut)
            try await eventually("Failure request begins") { f.client.requests.count == 1 }
            f.app.beginHold(.shortcut)
            check(f.recorder.starts == 1, "Busy request prevents overlapping recording")
            f.client.fail()
            try await eventually("Failure exposes Retry") { f.app.phase == .idle && f.app.retryAvailable }
            f.app.retry()
            try await eventually("Retry reuses audio") { f.client.requests.count == 2 }
            check(f.client.requests[0].audio == f.client.requests[1].audio, "Retry keeps the original recording")
            f.client.succeed("Recovered.")
            try await eventually("Retry completes") { f.app.phase == .idle }
            check(!f.app.retryAvailable && f.copies.last == "Recovered." && f.insertions.last?.pid == nil, "Retry copies without pasting into a stale app")
        }
        do {
            let f = ControllerFixture(); defer { f.close() }
            f.app.lastText = "Keep this."
            f.app.beginHold(.shortcut); f.app.endHold(.shortcut)
            try await eventually("Cancellable request begins") { f.client.requests.count == 1 }
            f.app.cancel(); f.client.succeed("Late response must be ignored.")
            try await Task.sleep(nanoseconds: 10_000_000)
            check(f.app.lastText == "Keep this." && f.copies.isEmpty && f.insertions.isEmpty, "Cancelled response cannot overwrite text or paste")
            check(f.app.phase == .idle && !f.app.retryAvailable, "Cancellation releases request state and retry audio")
        }
        do {
            let f = ControllerFixture(); defer { f.close() }
            try f.app.dictionary.remember(preferred: "CueLoom")
            f.app.autoPaste = false
            f.app.beginHold(.shortcut); f.app.endHold(.shortcut)
            try await eventually("Hinted request begins") { f.client.requests.count == 1 }
            check(f.client.requests[0].vocabulary == ["CueLoom"], "Saved dictionary reaches controller request")
            f.client.succeed("CueLoom works.")
            try await eventually("Copy-only request finishes") { f.app.phase == .idle }
            check(f.insertions.isEmpty && f.copies == ["CueLoom works."], "Copy-only preference never requests paste")
        }
        do {
            let f = ControllerFixture(); defer { f.close() }
            f.pasteSucceeds = false
            f.app.beginHold(.shortcut); f.app.endHold(.shortcut)
            try await eventually("Paste fallback request begins") { f.client.requests.count == 1 }
            f.client.succeed("Ready to paste.")
            try await eventually("Paste fallback completes") { f.app.phase == .idle }
            check(f.app.status.hasPrefix("Copied") && f.copies.last == "Ready to paste.", "Rejected paste leaves result copied with accurate status")
        }
        do {
            let f = ControllerFixture(); defer { f.close() }
            f.app.beginHold(.shortcut)
            f.recorder.onFailure?("Test microphone disconnected")
            try await eventually("Microphone failure returns idle") { f.app.phase == .idle }
            check(f.app.error == "Test microphone disconnected" && f.client.requests.isEmpty, "Microphone failure is visible and never uploads")
        }
        do {
            let f = ControllerFixture(); defer { f.close() }
            f.app.beginHold(.shortcut); f.app.endHold(.shortcut)
            try await eventually("Old request starts") { f.client.requests.count == 1 }
            f.app.cancel()
            f.app.beginHold(.shortcut); f.app.endHold(.shortcut)
            try await eventually("New request starts after cancellation") { f.client.requests.count == 2 }
            f.client.succeed("Old stale response.")
            try await Task.sleep(nanoseconds: 10_000_000)
            check(f.app.phase == .transcribing && f.copies.isEmpty, "Stale response cannot complete a newer request")
            f.client.succeed("New response.")
            try await eventually("New request finishes") { f.app.phase == .idle }
            check(f.app.lastText == "New response." && f.copies == ["New response."], "Only newest dictation is copied")
        }
        do {
            let f = ControllerFixture(); defer { f.close() }
            f.app.beginHold(.shortcut); f.app.endHold(.shortcut)
            try await eventually("Interrupted request starts") { f.client.requests.count == 1 }
            f.client.fail(CancellationError())
            try await eventually("Unexpected network cancellation exposes Retry instead of getting stuck") { f.app.phase == .idle && f.app.retryAvailable }
            check(f.app.error.contains("interrupted") && f.copies.isEmpty, "Interrupted request retains audio and explains recovery")
        }
        do {
            let f = ControllerFixture(); defer { f.close() }
            f.app.beginHold(.shortcut)
            f.recorder.elapsed = 299; f.app.updateRecording()
            check(f.app.phase == .recording && f.app.seconds == 299, "Recording continues below five-minute limit")
            f.recorder.elapsed = 300; f.app.updateRecording()
            check(f.app.phase == .transcribing && f.recorder.finishes == 1, "Five-minute limit ends recording once")
            f.app.endHold(.shortcut); f.app.updateRecording()
            try await eventually("Five-minute recording uploads once") { f.client.requests.count == 1 }
            f.client.succeed("Long recording.")
            try await eventually("Five-minute recording completes") { f.app.phase == .idle }
            check(f.recorder.finishes == 1, "Release after time limit never finishes twice")
        }
    }
}
