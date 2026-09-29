import Foundation

extension CoreTests {
    /// The demo input reads only mono 16-bit PCM WAV, meters like the microphone and hands back the file.
    static func demoAudioChecks() throws {
        func wav(_ samples: [Int16], rate: UInt32 = 16000, channels: UInt16 = 1) -> Data {
            var data = Data()
            func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + samples.count * 2)); data.append(contentsOf: Array("WAVE".utf8))
            data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(channels); u32(rate); u32(rate * 2); u16(2); u16(16)
            data.append(contentsOf: Array("data".utf8)); u32(UInt32(samples.count * 2))
            for sample in samples { u16(UInt16(bitPattern: sample)) }
            return data
        }
        let silence = [Int16](repeating: 0, count: 8000)
        let tone = (0..<8000).map { Int16(16000 * sin(Double($0) * 0.2)) }
        let clip = wav(silence + tone)
        let parsed = FileAudioRecording.parseWAV(clip)
        check(parsed?.samples.count == 16000 && parsed?.sampleRate == 16000, "Demo WAV parses")
        check(FileAudioRecording.parseWAV(wav(tone, channels: 2)) == nil, "Demo WAV rejects stereo")
        check(FileAudioRecording.parseWAV(Data("not audio".utf8)) == nil, "Demo WAV rejects non-WAV data")
        let samples = parsed?.samples ?? []
        check(FileAudioRecording.level(of: samples, at: 0.2, sampleRate: 16000) == 0, "Silent part meters zero")
        check(FileAudioRecording.level(of: samples, at: 0.75, sampleRate: 16000) > 0.7, "Loud part meters high")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qd-demo-\(UUID().uuidString).wav")
        try clip.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        check(DemoAudio.recorder(environment: [:]) == nil, "No demo input unless the variable is set")
        guard let recorder = DemoAudio.recorder(environment: [DemoAudio.environmentKey: url.path]) else { return check(false, "Demo recorder loads the file") }
        try recorder.start()
        let handedBack = try recorder.finish()
        check(handedBack == clip, "Demo recording hands back the file unchanged")
        do { _ = try recorder.finish(); check(false, "Finishing twice must fail") } catch { check(true, "Finishing twice fails") }
    }
}
