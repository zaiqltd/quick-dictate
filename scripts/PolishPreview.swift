import AppKit
import SwiftUI

// Render the production UI in this process's own off-screen window. All
// external services are local fixtures; no system events or clipboard access.
private final class PolishPreviewRecorder: AudioRecording {
    var onFailure: ((String) -> Void)?
    let elapsed: TimeInterval = 0
    let level = 0.0
    func start() throws { fatalError("Preview cannot record") }
    func finish() throws -> Data { fatalError("Preview cannot record") }
    func discard() {}
}
private struct PolishPreviewTranscriber: SpeechTranscribing {
    func transcribe(audio: Data, format: String, key: String, vocabulary: [String]) async throws -> Transcript { fatalError("Preview cannot transcribe") }
}
private struct PolishPreviewRewriter: TextPolishing {
    func polish(_ text: String, key: String) async throws -> String {
        "Can we move the meeting to Friday? Thursday is looking hectic. I'd still like to review the budget together before we send it over."
    }
}
private struct PolishPreviewAgent: AgentResponding {
    func respond(messages: [[String: Any]], model: String, key: String, tools: [[String: Any]]) async throws -> AgentReply { fatalError("Preview cannot call an assistant") }
}
private struct PolishPreviewSearch: WebSearching {
    func search(_ query: String, key: String) async throws -> WebSearchResult { fatalError("Preview cannot search") }
}
@MainActor private final class PolishPreviewSpeech: SpeechOutput {
    func speak(_ text: String, key: String, onState: @escaping @MainActor (SpeechOutputState) -> Void) async throws { fatalError("Preview cannot speak") }
    func stop() {}
}
@MainActor private struct PolishPreviewCodex: CodexRunning {
    func run(prompt: String, workingDirectory: URL, screenControl: Bool, onEvent: @escaping @MainActor (CodexRunEvent) -> Void) async throws -> CodexRunResult { fatalError("Preview cannot run Codex") }
}

@main private struct PolishPreview {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "local.chad.quick-dictate.polish-preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = FeatureSettings(defaults: defaults)
        try settings.update {
            $0.polishEnabled = true; $0.askEnabled = true; $0.actEnabled = true; $0.fullControlEnabled = true
        }
        let session = AgentSession(settings: settings, client: PolishPreviewAgent(), loadKey: { "preview-fixture" },
                                   executeAction: { _, _, _, _ in fatalError("Preview cannot run actions") },
                                   speech: PolishPreviewSpeech(), search: PolishPreviewSearch(), codex: PolishPreviewCodex())
        let services = DictationServices(loadKey: { "preview-fixture" }, microphoneStatus: { .authorized },
                                        requestMicrophone: { _ in fatalError("Preview cannot request permissions") },
                                        captureTarget: { fatalError("Preview cannot inspect focus") },
                                        insert: { _, _ in fatalError("Preview cannot paste") },
                                        copy: { _ in fatalError("Preview cannot copy") })
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quick-dictate-polish-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = DictationApp(recorder: PolishPreviewRecorder(), client: PolishPreviewTranscriber(), polisher: PolishPreviewRewriter(),
                              services: services, dictionary: PersonalDictionary(url: folder.appendingPathComponent("dictionary.json")),
                              features: settings, agent: session)
        app.micAllowed = true; app.pasteAllowed = true; app.keyPresent = true; app.autoPaste = false
        app.selectMode(.polish)
        app.polishDraft = "Yeah so basically I was thinking maybe we should move the meeting to Friday because Thursday is gonna be a bit hectic. And I still want to, you know, look at the budget together before we send it over."
        app.polishTypedText()
        let deadline = Date().addingTimeInterval(3)
        while app.phase != .idle && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        guard !app.polishedText.isEmpty else { throw DictationError(message: "Preview fixture did not complete") }

        let window = NSWindow(contentRect: NSRect(x: 100_000, y: 100_000, width: 480, height: 638),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: MainView(app: app))
        window.contentView = host
        window.orderFront(nil)
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        func save(_ path: String, view: NSView? = nil) throws {
            settle()
            let view = view ?? host
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw DictationError(message: "Could not make preview bitmap") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw DictationError(message: "Could not encode preview PNG") }
            try data.write(to: URL(fileURLWithPath: path))
            print(path)
        }
        let output = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath + "/build/polish-preview.png"
        try save(output)

        // Original button sits at the bottom of the production MainView. These
        // events go directly to our own NSWindow, never the system event stream.
        let point = NSPoint(x: 70, y: 32)
        for (number, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: number + 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            window.sendEvent(event); settle()
        }
        let expanded = URL(fileURLWithPath: output).deletingPathExtension().path + "-expanded.png"
        try save(expanded)
        if let popover = NSApplication.shared.windows.first(where: { $0 !== window && $0.isVisible && $0.contentView != nil }),
           let view = popover.contentView {
            func hostingSubview(_ candidate: NSView) -> NSView? {
                if String(describing: type(of: candidate)).contains("HostingView") { return candidate }
                return candidate.subviews.compactMap(hostingSubview).first
            }
            let rendered = hostingSubview(view) ?? view
            print("Original popover preview: \(type(of: rendered)) \(rendered.bounds)")
            try save(URL(fileURLWithPath: output).deletingPathExtension().path + "-original.png", view: rendered)
            popover.close()
        } else {
            print("Off-screen popover did not open; main view snapshot still saved.")
        }
        window.close()
    }
}
