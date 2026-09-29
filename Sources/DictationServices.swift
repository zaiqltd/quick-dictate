import AppKit
import AVFoundation

protocol AudioRecording: AnyObject {
    var onFailure: ((String) -> Void)? { get set }
    var elapsed: TimeInterval { get }
    var level: Double { get }
    func start() throws
    func finish() throws -> Data
    func discard()
}

protocol SpeechTranscribing {
    func transcribe(audio: Data, format: String, key: String, vocabulary: [String]) async throws -> Transcript
}

struct DictationTarget {
    var pid: pid_t?
    var element: AXUIElement?
    var isSecure = false
}

// The controller uses the same services in production and in integration tests.
// Tests substitute microphone/network/clipboard effects, not controller logic.
@MainActor struct DictationServices {
    var loadKey: () -> String?
    var microphoneStatus: () -> AVAuthorizationStatus
    var requestMicrophone: (@escaping @Sendable (Bool) -> Void) -> Void
    var captureTarget: () -> DictationTarget
    var insert: (String, DictationTarget) async -> Bool
    var copy: (String) -> Void
    var selectedContext: () -> String? = { nil }

    static var live: Self {
        Self(
            loadKey: Credentials.load,
            microphoneStatus: { AVCaptureDevice.authorizationStatus(for: .audio) },
            requestMicrophone: { completion in AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion) },
            captureTarget: {
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                let trusted = AXIsProcessTrusted()
                return DictationTarget(
                    pid: front == ProcessInfo.processInfo.processIdentifier ? nil : front,
                    element: trusted ? Paste.focusedElement() : nil,
                    isSecure: trusted && Paste.isSecureField()
                )
            },
            insert: { text, target in await Paste.insert(text, targetPID: target.pid, targetElement: target.element) },
            copy: Paste.copy,
            selectedContext: {
                guard AXIsProcessTrusted(), !Paste.isSecureField(), let element = Paste.focusedElement() else { return nil }
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
                      let text = value as? String else { return nil }
                return String(text.prefix(6000))
            }
        )
    }
}
