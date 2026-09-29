import Foundation

/// Opt-in authenticated check. Creates only its own temporary fixture. Never
/// loads an alternate account or logs raw CLI events/hidden reasoning.
@main struct FullControlSmoke {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.contains("--live") else {
            print("Use --live to run an authenticated Codex fixture through the production client.")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quick-dictate-codex-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = """
        This is a narrow integration test in a new temporary folder. Create index.html in the current directory, containing a complete standalone HTML page with title 'Quick Dictate Full Control Check' and visible heading 'Codex full control works'. Use no dependencies, network, external content, or other files. Read it back to verify both strings. Do not open a browser or inspect other files. Finish with 'Created and verified index.html.' Do this directly without asking for approval.
        """
        let prompt = FullControlPrompt.make(messages: [["role": "user", "content": request]], screenControl: false)
        var events: [String] = []
        let began = Date()
        let result = try await CodexCLI(timeout: 180).run(prompt: prompt, workingDirectory: root, screenControl: false) { event in
            let name: String
            switch event {
            case .started: name = "started"
            case .thinking: name = "thinking"
            case .message: name = "public_message"
            case .commandStarted: name = "command_started"
            case .commandFinished: name = "command_finished"
            case .filesChanged: name = "files_changed"
            case .toolStarted: name = "tool_started"
            case .toolFinished: name = "tool_finished"
            case .status: name = "status"
            case .completed: name = "completed"
            }
            events.append(name)
            print("Event: \(name)")
        }
        let html = try String(contentsOf: root.appendingPathComponent("index.html"), encoding: .utf8)
        guard html.contains("Quick Dictate Full Control Check"), html.contains("Codex full control works"), result.exitCode == 0 else {
            throw NSError(domain: "QuickDictateSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Codex fixture verification failed."])
        }
        let evidence: [String: Any] = [
            "checked_at": ISO8601DateFormatter().string(from: Date()),
            "model": CodexCLI.model, "reasoning": CodexCLI.reasoningEffort,
            "permissions": "bypass approvals and sandbox", "account": "primary saved Codex login",
            "screen_control": false, "fixture": "Standalone HTML in an isolated temporary folder; readback checked two required strings.",
            "verified": true, "exit_code": result.exitCode, "seconds": Date().timeIntervalSince(began),
            "event_types": events, "answer": result.finalText
        ]
        let destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("docs/codex-full-control-smoke.json")
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: destination)
        print("PASS: \(destination.path)")
    }
}
