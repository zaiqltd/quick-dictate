import Foundation

/// Demo input for filming and testing. When QUICK_DICTATE_DEMO_AUDIO names a 16 kHz, mono,
/// 16-bit PCM WAV file, dictation "records" that file instead of the microphone: the level meter
/// follows the file's own loudness and the file is what gets transcribed. Everything after the
/// recording (transcription, polishing, copy and paste) runs exactly as normal. When the variable
/// is not set, nothing changes and the microphone is used.
enum DemoAudio {
    static let environmentKey = "QUICK_DICTATE_DEMO_AUDIO"

    static func recorder(environment: [String: String] = ProcessInfo.processInfo.environment) -> FileAudioRecording? {
        guard let path = environment[environmentKey], !path.isEmpty else { return nil }
        return FileAudioRecording(url: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }
}

final class FileAudioRecording: AudioRecording {
    var onFailure: ((String) -> Void)?
    private let data: Data
    private let samples: [Int16]
    private let sampleRate: Double
    private var startedAt: Date?

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url), let parsed = Self.parseWAV(data) else { return nil }
        self.data = data
        self.samples = parsed.samples
        self.sampleRate = parsed.sampleRate
    }

    var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    /// Same scale as the microphone meter: average power in dB, mapped from -55…0 dB to 0…1.
    var level: Double {
        guard startedAt != nil else { return 0 }
        return Self.level(of: samples, at: elapsed, sampleRate: sampleRate)
    }

    func start() throws { startedAt = Date() }

    func finish() throws -> Data {
        guard startedAt != nil else { throw DictationError(message: "There isn't a recording to transcribe.") }
        startedAt = nil
        return data
    }

    func discard() { startedAt = nil }

    static func level(of samples: [Int16], at time: TimeInterval, sampleRate: Double) -> Double {
        let center = Int(time * sampleRate), half = Int(sampleRate * 0.05)
        let lower = max(0, center - half), upper = min(samples.count, center + half)
        guard upper > lower else { return 0 }
        var sum = 0.0
        for index in lower..<upper { let value = Double(samples[index]) / 32768; sum += value * value }
        let decibels = 20 * log10(max((sum / Double(upper - lower)).squareRoot(), 1e-6))
        return max(0, min(1, (decibels + 55) / 55))
    }

    /// Reads a canonical RIFF/WAVE file: PCM, mono, 16-bit. Returns nil for anything else.
    static func parseWAV(_ data: Data) -> (samples: [Int16], sampleRate: Double)? {
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> UInt32 { UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24 }
        func u16(_ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
        guard bytes.count >= 12, bytes[0..<4] == [0x52, 0x49, 0x46, 0x46], bytes[8..<12] == [0x57, 0x41, 0x56, 0x45] else { return nil }
        var offset = 12, rate: Double?, pcm16mono = false
        while offset + 8 <= bytes.count {
            let id = String(bytes: bytes[offset..<offset + 4], encoding: .ascii) ?? ""
            let size = Int(u32(offset + 4)), body = offset + 8
            guard body + size <= bytes.count else { return nil }
            if id == "fmt ", size >= 16 {
                pcm16mono = u16(body) == 1 && u16(body + 2) == 1 && u16(body + 14) == 16
                rate = Double(u32(body + 4))
            } else if id == "data", pcm16mono, let rate {
                var samples = [Int16](repeating: 0, count: size / 2)
                for index in 0..<samples.count { samples[index] = Int16(bitPattern: u16(body + index * 2)) }
                return (samples, rate)
            }
            offset = body + size + (size & 1)
        }
        return nil
    }
}
