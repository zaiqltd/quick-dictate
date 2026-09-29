import AppKit
import Foundation
import SwiftUI

// A separate native UI verification app. Compile with production Sources/*.swift
// excluding Main.swift. The real AgentPanelView embeds RequestProgressView; only
// its external services are replaced. No credentials, audio or network are used.

@MainActor private final class PreviewStreamingClient: AgentStreaming {
    enum Scenario { case delayed, search }
    var scenario = Scenario.delayed
    var round = 0

    func respond(messages: [[String: Any]], model: String, key: String, tools: [[String: Any]]) async throws -> AgentReply {
        try await stream(messages: messages, model: model, key: key, tools: tools) { _ in }
    }

    func stream(messages: [[String: Any]], model: String, key: String, tools: [[String: Any]],
                onText: @escaping @MainActor (String) -> Void) async throws -> AgentReply {
        let scenario = self.scenario
        round += 1
        let currentRound = round
        if scenario == .search && currentRound == 1 {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            try Task.checkCancellation()
            let arguments = #"{"query":"deterministic progress preview fixture"}"#
            let call = AgentToolCall(id: "preview-search-call", name: "web_search", argumentsJSONString: arguments,
                                     arguments: ["query": "deterministic progress preview fixture"])
            return AgentReply(text: "", toolCalls: [call], assistantMessage: [
                "role": "assistant", "content": NSNull(), "tool_calls": [[
                    "id": call.id, "type": "function", "function": ["name": call.name, "arguments": arguments]
                ]]
            ])
        }
        let initialDelay: UInt64 = scenario == .delayed ? 25 : 12
        let finalDelay: UInt64 = scenario == .delayed ? 20 : 6
        try await Task.sleep(nanoseconds: initialDelay * 1_000_000_000)
        try Task.checkCancellation()
        let first = scenario == .delayed
            ? "The first answer text has arrived. This is a local preview, and the response is deliberately paused again to check the receiving state. "
            : "The simulated search finished and the assistant's answer is now arriving. "
        onText(first)
        try await Task.sleep(nanoseconds: finalDelay * 1_000_000_000)
        try Task.checkCancellation()
        let last = "The preview is complete. No network request was made."
        onText(last)
        let text = first + last
        return AgentReply(text: text, toolCalls: [], assistantMessage: ["role": "assistant", "content": text])
    }
}

private struct PreviewSearch: WebSearching {
    func search(_ query: String, key: String) async throws -> WebSearchResult {
        try await Task.sleep(nanoseconds: 8_000_000_000)
        try Task.checkCancellation()
        let source = AgentSource(title: "Local preview source (fixture)", url: URL(string: "https://example.com/preview-fixture")!)
        return WebSearchResult(summary: "This is simulated source material for checking progress transitions.", sources: [source])
    }
}

@MainActor private final class PreviewSilentSpeech: SpeechOutput {
    func speak(_ text: String, key: String, onState: @escaping @MainActor (SpeechOutputState) -> Void) async throws {
        throw DictationError(message: "Sound output is disabled in this local progress preview.")
    }
    func stop() {}
}

@MainActor private final class ProgressPreviewModel: ObservableObject {
    let session: AgentSession
    private let client: PreviewStreamingClient
    private let defaults: UserDefaults
    private let suite: String

    init() throws {
        suite = "local.chad.quick-dictate.progress-preview.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw DictationError(message: "Could not create the preview's isolated settings.")
        }
        self.defaults = defaults
        defaults.removePersistentDomain(forName: suite)
        let settings = FeatureSettings(defaults: defaults)
        try settings.update {
            $0.askEnabled = true
            $0.actEnabled = false
            $0.speakReplies = false
            $0.webSearchEnabled = true
            $0.useSelectedText = false
            $0.workRoot = FileManager.default.temporaryDirectory.path
        }
        let client = PreviewStreamingClient()
        self.client = client
        session = AgentSession(settings: settings, client: client, loadKey: { "preview-fixture-only" }, executeAction: { _, _, _, _ in
            throw DictationError(message: "Actions are disabled in the progress preview.")
        }, speech: PreviewSilentSpeech(), search: PreviewSearch())
    }

    func start(_ scenario: PreviewStreamingClient.Scenario) {
        session.newChat()
        client.scenario = scenario
        client.round = 0
        let prompt = scenario == .delayed
            ? "Show me what happens while an answer takes a while to arrive."
            : "Show a simulated search, then prepare an answer from its fixture result."
        session.send(prompt, mode: .ask)
    }

    func cleanup() {
        session.cancel()
        defaults.removePersistentDomain(forName: suite)
    }
}

private struct ProgressPreviewRoot: View {
    @ObservedObject var model: ProgressPreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Dictate Progress Check").font(.system(size: 17, weight: .semibold))
            Text("Production UI · local fixtures · no audio or network")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Delayed reply") { model.start(.delayed) }
                    .help("First text at 25 seconds; final text 20 seconds later")
                Button("Search then reply") { model.start(.search) }
                    .help("Search starts at 2 seconds and lasts 8 seconds, then the answer waits 12 seconds")
                Spacer()
            }.controlSize(.small)
            Divider()
            AgentPanelView(session: model.session, mode: .ask)
                .frame(height: 380)
        }
        .padding(20)
        .frame(width: 520, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor private final class ProgressPreviewDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var model: ProgressPreviewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let model = try ProgressPreviewModel()
            self.model = model
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 540),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Quick Dictate Progress Check"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ProgressPreviewRoot(model: model))
            window.center()
            self.window = window
            let menu = NSMenu()
            let application = NSMenu()
            let item = NSMenuItem()
            item.submenu = application
            menu.addItem(item)
            application.addItem(withTitle: "Quit Quick Dictate Progress Check", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            NSApp.mainMenu = menu
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            fputs("Progress preview could not start: \(error.localizedDescription)\n", stderr)
            NSApp.terminate(nil)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { model?.cleanup() }
}

@main private struct ProgressPreviewMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = ProgressPreviewDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
