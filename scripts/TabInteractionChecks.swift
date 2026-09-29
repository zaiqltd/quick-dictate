import AppKit
import SwiftUI

// Local native interaction check. Compile with Sources/*.swift excluding Main.
// Events are sent directly to this process's off-screen NSWindow, never posted
// to the system event stream. No microphone, credentials or network are used.
private final class TabCheckRecorder: AudioRecording {
    var onFailure: ((String) -> Void)?
    let elapsed: TimeInterval = 0
    let level = 0.0
    func start() throws { fatalError("Tab checks must not record audio") }
    func finish() throws -> Data { fatalError("Tab checks must not record audio") }
    func discard() {}
}

private struct TabCheckTranscriber: SpeechTranscribing {
    func transcribe(audio: Data, format: String, key: String, vocabulary: [String]) async throws -> Transcript {
        fatalError("Tab checks must not transcribe")
    }
}

private struct TabCheckAgent: AgentResponding {
    func respond(messages: [[String: Any]], model: String, key: String, tools: [[String: Any]]) async throws -> AgentReply {
        fatalError("Tab checks must not make requests")
    }
}

private struct TabCheckPolisher: TextPolishing {
    func polish(_ text: String, key: String) async throws -> String {
        fatalError("Tab checks must not rewrite text")
    }
}

@MainActor private final class TabCheckSpeech: SpeechOutput {
    func speak(_ text: String, key: String, onState: @escaping @MainActor (SpeechOutputState) -> Void) async throws {
        fatalError("Tab checks must not speak")
    }
    func stop() {}
}

@main private struct TabInteractionChecks {
    @MainActor static func main() throws {
        let nsApp = NSApplication.shared
        nsApp.setActivationPolicy(.prohibited)
        let suite = "local.chad.quick-dictate.tab-check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = FeatureSettings(defaults: defaults)
        try settings.update { $0.askEnabled = true; $0.actEnabled = true; $0.fullControlEnabled = true }
        let session = AgentSession(settings: settings, client: TabCheckAgent(), loadKey: { nil }, speech: TabCheckSpeech())
        let services = DictationServices(loadKey: { nil }, microphoneStatus: { .denied },
                                        requestMicrophone: { _ in fatalError("No microphone prompt") },
                                        captureTarget: { DictationTarget(pid: nil, element: nil) },
                                        insert: { _, _ in fatalError("No paste") }, copy: { _ in fatalError("No copy") })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quick-dictate-tab-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = DictationApp(recorder: TabCheckRecorder(), client: TabCheckTranscriber(), polisher: TabCheckPolisher(), services: services,
                              dictionary: PersonalDictionary(url: root.appendingPathComponent("dictionary.json")),
                              features: settings, agent: session)
        let window = NSWindow(contentRect: NSRect(x: 100_000, y: 100_000, width: 360, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ModeTabsView(app: app, features: settings))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        var checks = 0
        var failures: [String] = []
        var eventNumber = 0
        func check(_ condition: Bool, _ description: String) {
            checks += 1
            if !condition { failures.append(description) }
        }
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.015))
        }
        func mouseEvent(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            eventNumber += 1
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: eventNumber, clickCount: 1,
                                      pressure: type == .leftMouseDown ? 1 : 0)!
        }
        func click(_ point: NSPoint) {
            window.sendEvent(mouseEvent(.leftMouseDown, point)); settle()
            window.sendEvent(mouseEvent(.leftMouseUp, point)); settle()
        }
        // Fractions are relative to the individual tab, not a hard-coded four
        // column grid, so edge checks remain inside every five-tab hit target.
        func tabPoint(index: Int, count: Int, width: CGFloat, fraction: CGFloat = 0.5, y: CGFloat = 20) -> NSPoint {
            let padding: CGFloat = 3, spacing: CGFloat = 4
            let tabWidth = (width - 2 * padding - CGFloat(count - 1) * spacing) / CGFloat(count)
            return NSPoint(x: padding + CGFloat(index) * (tabWidth + spacing) + tabWidth * fraction, y: y)
        }
        for polishEnabled in [false, true] {
            try settings.update { $0.polishEnabled = polishEnabled }
            let modes = VoiceMode.allCases.filter { settings.options.enabledModes.contains($0) }
            for width: CGFloat in [360, 440, 480] {
                window.setContentSize(NSSize(width: width, height: 40)); settle()
                for (index, mode) in modes.enumerated() {
                    for fraction: CGFloat in [0.1, 0.5, 0.9] {
                        for y: CGFloat in [10, 20, 30] {
                            app.selectMode(mode == .dictation ? .ask : .dictation); settle()
                            let point = tabPoint(index: index, count: modes.count, width: width, fraction: fraction, y: y)
                            click(point)
                            check(app.activeMode == mode,
                                  "\(modes.count) tabs at \(Int(width))pt: \(mode.title) at (\(Int(point.x)),\(Int(y))) should select tab")
                            check(app.phase == .idle, "Clicking \(mode.title) never starts capture or polishing")
                        }
                    }
                }
                // Busy modes remain inert. Mutate only the observable phase;
                // no audio, model, paste or clipboard service is started.
                for phase: Phase in [.recording, .polishing] {
                    app.selectMode(.dictation); app.phase = phase; settle()
                    for index in 1..<modes.count {
                        click(tabPoint(index: index, count: modes.count, width: width))
                        check(app.activeMode == .dictation, "\(phase) disables \(modes[index].title) with \(modes.count) tabs at \(Int(width))pt")
                    }
                    app.phase = .idle; settle()
                }
                let askIndex = modes.firstIndex(of: .ask)!
                app.selectMode(.ask); session.draft = "Unsent local fixture"; settle()
                click(tabPoint(index: 0, count: modes.count, width: width))
                click(tabPoint(index: askIndex, count: modes.count, width: width))
                check(app.activeMode == .ask && session.draft == "Unsent local fixture",
                      "Ask draft survives Dictate round trip with \(modes.count) tabs at \(Int(width))pt")
                if let polishIndex = modes.firstIndex(of: .polish) {
                    app.polishDraft = "Rough local draft"; settle()
                    click(tabPoint(index: polishIndex, count: modes.count, width: width))
                    click(tabPoint(index: askIndex, count: modes.count, width: width))
                    click(tabPoint(index: polishIndex, count: modes.count, width: width))
                    check(app.activeMode == .polish && app.polishDraft == "Rough local draft" && session.draft == "Unsent local fixture",
                          "Polish and Ask drafts survive mode switches at \(Int(width))pt")
                }
            }
        }
        let firstMouse = mouseEvent(.leftMouseDown, tabPoint(index: 2, count: 5, width: 480))
        let hit = host.hitTest(host.convert(firstMouse.locationInWindow, from: nil))
        print("First-mouse diagnostic only: host=\(host.acceptsFirstMouse(for: firstMouse)), hit=\(hit?.acceptsFirstMouse(for: firstMouse) ?? false); direct local dispatch does not test inactive desktop window activation.")
        print("Native tab checks: \(checks - failures.count)/\(checks) passed")
        for failure in failures { print("FAIL: \(failure)") }
        window.close()
        if !failures.isEmpty { throw DictationError(message: "\(failures.count) native tab checks failed") }
    }
}
