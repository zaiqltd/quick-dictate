import AVFoundation
import Foundation

final class Recorder: NSObject, AVAudioRecorderDelegate, AudioRecording {
    private var recorder: AVAudioRecorder?
    private var url: URL?
    var onFailure: ((String) -> Void)?
    override init() {
        super.init()
        // Clean only this app's UUID-named temporary recordings after an interrupted run.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("local.chad.quick-dictate", isDirectory: true)
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            if ["wav", "m4a"].contains(file.pathExtension), UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
    var elapsed: TimeInterval { recorder?.currentTime ?? 0 }
    var level: Double {
        recorder?.updateMeters()
        return max(0, min(1, Double(((recorder?.averagePower(forChannel: 0) ?? -60) + 55) / 55)))
    }
    func start() throws {
        discard()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("local.chad.quick-dictate", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(UUID().uuidString + ".wav")
        url = file
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]
        do {
            let recording = try AVAudioRecorder(url: file, settings: settings)
            recording.delegate = self
            recording.isMeteringEnabled = true
            guard recording.prepareToRecord(), recording.record() else {
                throw DictationError(message: "Couldn't start the microphone. Check your Mac's sound input.")
            }
            recorder = recording
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { discard(); throw error }
    }
    func finish() throws -> Data {
        guard let file = url else { throw DictationError(message: "There isn't a recording to transcribe.") }
        recorder?.stop()
        recorder = nil
        defer { discard() }
        return try Data(contentsOf: file)
    }
    func discard() {
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        if let url { try? FileManager.default.removeItem(at: url) }
        url = nil
    }
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        onFailure?("The microphone stopped unexpectedly. Check your sound input and try again.")
    }
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag { onFailure?("The recording was interrupted. Check your microphone and try again.") }
    }
    deinit { discard() }
}
