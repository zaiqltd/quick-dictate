import Foundation

@MainActor private final class FullControlFixtureRunner: CodexRunning {
    struct Request { let prompt: String; let directory: URL; let screenControl: Bool }
    var requests: [Request] = []
    private var callbacks: [@MainActor (CodexRunEvent) -> Void] = []
    private var continuations: [Int: CheckedContinuation<CodexRunResult, Error>] = [:]
    func run(prompt: String, workingDirectory: URL, screenControl: Bool,
             onEvent: @escaping @MainActor (CodexRunEvent) -> Void) async throws -> CodexRunResult {
        let index = requests.count
        requests.append(Request(prompt: prompt, directory: workingDirectory, screenControl: screenControl))
        callbacks.append(onEvent)
        return try await withCheckedThrowingContinuation { continuations[index] = $0 }
    }
    func emit(_ event: CodexRunEvent, at index: Int = 0) { callbacks[index](event) }
    func complete(_ text: String, at index: Int = 0, exitCode: Int32 = 0) {
        continuations.removeValue(forKey: index)?.resume(returning: CodexRunResult(finalText: text, exitCode: exitCode, truncated: false))
    }
    func fail(_ error: Error, at index: Int = 0) { continuations.removeValue(forKey: index)?.resume(throwing: error) }
}

@MainActor private final class FullControlFixtureSpeech: SpeechOutput {
    var texts: [String] = []
    func speak(_ text: String, key: String, onState: @escaping @MainActor (SpeechOutputState) -> Void) async throws {
        texts.append(text); onState(.speaking); onState(.idle)
    }
    func stop() {}
}

extension CoreTests {
    @MainActor static func fullControlSessionChecks() async throws {
        let suite = "quick-dictate-full-control-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = FeatureSettings(defaults: defaults)
        let runner = FullControlFixtureRunner()
        let speech = FullControlFixtureSpeech()
        let chat = AgentSessionMockClient()
        chat.handler = { _ in AgentReply(text: "Ask reply", toolCalls: [], assistantMessage: ["role": "assistant", "content": "Ask reply"]) }
        var key: String? = nil
        var executed = 0
        let session = AgentSession(settings: settings, client: chat, loadKey: { key }, executeAction: { _, _, _, _ in
            executed += 1
            return LocalActionResult(output: "unused", exitCode: 0, timedOut: false, cancelled: false, truncated: false)
        }, speech: speech, codex: runner)
        defer { session.cancel() }
        func waitFor(_ label: String, _ condition: () -> Bool) async {
            for _ in 0..<200 {
                if condition() { check(true, label); return }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            check(false, "Timed out: \(label)")
        }
        check(!session.send("Build a page", mode: .fullControl), "Disabled Full Control cannot dispatch a CLI")
        check(runner.requests.isEmpty && session.turns.isEmpty, "Disabled mode has no process or phantom turn")
        try settings.update { $0.fullControlEnabled = true; $0.askEnabled = true; $0.workRoot = "/tmp" }
        check(session.send("Create a fixture", mode: .fullControl, selection: "SECRET-SELECTION"), "Typed Full Control does not require an OpenRouter key")
        check(session.isFullControl && session.isBusy && session.progress?.isActive == true, "Codex starts visible progress immediately")
        await waitFor("CLI receives request", { runner.requests.count == 1 })
        check(runner.requests[0].directory.path == "/tmp" && runner.requests[0].screenControl, "Codex receives folder and screen setting")
        check(!runner.requests[0].prompt.contains("SECRET-SELECTION"), "Selected text stays out of Codex unless enabled")
        check(chat.requests.isEmpty && executed == 0 && session.pending.isEmpty, "Full Control bypasses the separate OpenRouter reviewed-action path")
        runner.emit(.started)
        runner.emit(.message("I am checking the fixture."))
        check(session.turns.last?.role == .activity && session.state == .replying, "Public Codex commentary appears as live activity")
        check(speech.texts.isEmpty, "Progress commentary is never automatically spoken")
        runner.emit(.toolStarted("cua_repl: js"))
        check(session.state == .running && session.activityDetail.contains("Screen"), "Built-in screen tool is visibly identified")
        runner.emit(.commandStarted("overlapping fixture"))
        runner.emit(.message("Another action is still running."))
        check(session.state == .running, "Commentary does not hide an ongoing action")
        runner.emit(.toolFinished("cua_repl: js"))
        check(session.state == .running && session.liveOutput.contains("overlapping fixture"), "Finishing one tool keeps overlapping work visible")
        runner.emit(.commandFinished(command: "overlapping fixture", output: "", exitCode: 0))
        check(session.state == .thinking && session.liveOutput.isEmpty, "Codex returns to thinking after all actions finish")
        runner.emit(.commandStarted("printf fixture"))
        check(session.liveOutput.contains("printf fixture") && session.state == .running, "Actual command appears while running")
        runner.emit(.commandFinished(command: "printf fixture", output: "fixture", exitCode: 0))
        check(session.turns.last?.text.contains("Exit code: 0") == true, "Real command result stays in conversation")
        runner.emit(.filesChanged(["fixture.txt"]))
        runner.emit(.message("Created the fixture."))
        runner.complete("Created the fixture.")
        await waitFor("Codex completes", { !session.isBusy })
        check(session.progress?.kind == .complete && session.turns.last?.role == .assistant, "Successful exit completes the request")
        check(session.turns.filter { $0.text == "Created the fixture." }.count == 1, "Final Codex message is not duplicated as commentary")
        check(speech.texts.isEmpty, "Typed Full Control stays silent")

        check(session.send("Change its title", mode: .fullControl), "Full Control accepts follow-up")
        await waitFor("Follow-up reaches CLI", { runner.requests.count == 2 })
        check(runner.requests[1].prompt.contains("Created the fixture.") && runner.requests[1].prompt.contains("Change its title"), "Follow-up carries only Full Control memory")
        session.cancel()
        let stoppedTurns = session.turns.count
        runner.emit(.commandStarted("late-command"), at: 1)
        runner.complete("Late answer", at: 1)
        try? await Task.sleep(nanoseconds: 20_000_000)
        check(session.progress?.kind == .stopped && session.turns.count == stoppedTurns && !session.liveOutput.contains("late-command"), "Stop rejects stale Codex output and completion")

        key = "fixture-key"
        session.prepareForMode(.ask)
        check(session.turns.isEmpty && !session.isFullControl && session.progress == nil, "Crossing from Codex to OpenRouter clears private local context")
        check(session.send("Ask-only marker", mode: .ask), "Ask remains available")
        await waitFor("Ask finishes after Codex", { !session.isBusy })
        check(chat.requests.count == 1 && !chat.requests[0].messages.description.contains("fixture.txt"), "Codex work is not forwarded to OpenRouter")
        try settings.update { $0.useSelectedText = true; $0.fullControlScreenEnabled = false }
        check(session.send("Voice task", mode: .fullControl, selection: "CHOSEN-CONTEXT", spoken: true), "Voice dispatch routes to Codex")
        await waitFor("Voice request reaches CLI", { runner.requests.count == 3 })
        check(!runner.requests[2].screenControl && runner.requests[2].prompt.contains("Screen control is disabled"), "Screen control opt-out reaches executable and prompt")
        check(runner.requests[2].prompt.contains("CHOSEN-CONTEXT") && !runner.requests[2].prompt.contains("Ask-only marker"), "Explicit selection is included but other-provider chat is excluded")
        runner.emit(.message("Working on it."), at: 2)
        check(speech.texts.isEmpty, "Voice task still keeps progress silent")
        runner.complete("The voice task is complete.", at: 2)
        await waitFor("Final voice answer speaks", { !speech.texts.isEmpty && session.speechState == .idle })
        check(speech.texts.joined().contains("voice task is complete"), "Final Codex answer uses existing Qwen speech path")
        let countBeforeReplay = runner.requests.count
        session.replayLast()
        await waitFor("Replay speaks only", { speech.texts.count == 2 })
        check(runner.requests.count == countBeforeReplay, "Speak never reruns Codex actions")

        check(session.send("Fail fixture", mode: .fullControl), "Another Codex request accepted")
        await waitFor("Failure fixture starts", { runner.requests.count == 4 })
        runner.fail(CodexCLIError.failed("fixture error"), at: 3)
        await waitFor("CLI failure returns idle", { !session.isBusy })
        check(session.progress?.kind == .failed && session.error.contains("fixture error"), "CLI failure is visible and freezes progress")
        check(session.send("Disable fixture", mode: .fullControl), "Request accepted before disable")
        await waitFor("Disable fixture starts", { runner.requests.count == 5 })
        try settings.update { $0.fullControlEnabled = false }; session.settingsChanged()
        runner.complete("Must not appear", at: 4)
        try? await Task.sleep(nanoseconds: 20_000_000)
        check(!session.isBusy && session.progress?.kind == .stopped && !session.turns.contains { $0.text == "Must not appear" }, "Disabling Full Control cancels and rejects later completion")
        session.newChat()
        check(session.turns.isEmpty && session.progress == nil && session.error.isEmpty, "New chat clears full-control state")

        let bigHistory = (0..<16).map { ["role": $0 % 2 == 0 ? "user" : "assistant", "content": String(repeating: "x", count: 12_000)] }
        let bounded = FullControlPrompt.make(messages: bigHistory, screenControl: true)
        check(bounded.utf8.count < 65_536 && bounded.contains("built-in Computer Use"), "Codex context is bounded and uses the built-in screen tool")
        check(!bounded.contains("QuickDictateComputer"), "No custom screen-control helper is invoked")
    }
}
