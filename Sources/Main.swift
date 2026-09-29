import Cocoa
import Foundation

@main struct Main {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.count == 3 && args[1] == "--transcribe-file" {
            let path = args[2]
            Task {
                do {
                    let url = URL(fileURLWithPath: path)
                    let started = Date()
                    let result = try await TranscriptionClient().transcribe(audio: Data(contentsOf: url), format: url.pathExtension.lowercased(), key: Credentials.load() ?? "", vocabulary: PersonalDictionary().hints)
                    let payload: [String: Any] = ["text": result.text, "latency_seconds": Date().timeIntervalSince(started), "audio_seconds": result.usage?.seconds ?? 0, "cost_usd": result.usage?.cost ?? 0, "model": TranscriptionClient.model]
                    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                    print(String(data: data, encoding: .utf8)!)
                    exit(0)
                } catch { fputs("Transcription failed: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            dispatchMain()
        }
        let app = NSApplication.shared
        let bundleID = Bundle.main.bundleIdentifier ?? "local.chad.quick-dictate"
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateAllWindows]); exit(0)
        }
        let delegate = DictationApp()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
