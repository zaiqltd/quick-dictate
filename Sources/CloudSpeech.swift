import AVFoundation
import Foundation

enum SpeechOutputState: Equatable, Sendable { case preparing, speaking, idle }

@MainActor
protocol SpeechOutput: AnyObject {
    func speak(_ text: String, key: String, onState: @escaping @MainActor (SpeechOutputState) -> Void) async throws
    func prefetch(_ text: String, key: String)
    func stop()
}

extension SpeechOutput {
    func prefetch(_ text: String, key: String) {}
}

struct SpeechPCMFormat: Equatable, Sendable {
    let sampleRate: Int
    let channels: Int
    var bytesPerFrame: Int { channels * 2 }

    init(sampleRate: Int, channels: Int = 1) throws {
        guard (8_000...48_000).contains(sampleRate), (1...2).contains(channels) else { throw CloudSpeechError.unsupportedAudio }
        self.sampleRate = sampleRate
        self.channels = channels
    }

    // OpenRouter documents signed 16-bit little-endian PCM. Rate/channels are
    // read from the response, never inferred from the byte count or text.
    static func response(_ response: HTTPURLResponse, fallback: SpeechPCMFormat? = nil) throws -> SpeechPCMFormat {
        let fields = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.first == "audio/pcm" else { throw CloudSpeechError.unsupportedAudio }
        var parameters: [String: String] = [:]
        for field in fields.dropFirst() {
            let pair = field.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
            if pair.count == 2 { parameters[pair[0]] = pair[1] }
        }
        let rateText = parameters["rate"] ?? parameters["sample_rate"] ?? response.value(forHTTPHeaderField: "X-Audio-Sample-Rate")
        let channelsText = parameters["channels"] ?? response.value(forHTTPHeaderField: "X-Audio-Channels")
        if let encoding = parameters["encoding"], !["pcm_s16le", "s16le"].contains(encoding) { throw CloudSpeechError.unsupportedAudio }
        let rate: Int
        if let rateText {
            guard let value = Int(rateText) else { throw CloudSpeechError.unsupportedAudio }
            rate = value
        } else if let fallback { rate = fallback.sampleRate }
        else { throw CloudSpeechError.missingAudioRate }
        let channels: Int
        if let channelsText {
            guard let value = Int(channelsText) else { throw CloudSpeechError.unsupportedAudio }
            channels = value
        } else { channels = fallback?.channels ?? 1 }
        return try SpeechPCMFormat(sampleRate: rate, channels: channels)
    }
}

struct SpeechPCMChunk: Sendable {
    let format: SpeechPCMFormat
    /// Interleaved, normalized samples. A chunk always contains whole frames.
    let samples: [Float]
    var frameCount: Int { samples.count / format.channels }
}

struct SpeechSynthesisMetrics: Equatable, Sendable {
    let firstByteSeconds: TimeInterval
    let requestSeconds: TimeInterval
    let audioSeconds: TimeInterval
    let byteCount: Int
}

protocol SpeechSynthesizing {
    func synthesize(text: String, key: String, onChunk: @escaping @Sendable (SpeechPCMChunk) async throws -> Void) async throws -> SpeechSynthesisMetrics
}

enum CloudSpeechError: LocalizedError, Equatable {
    case emptyText, textTooLong, missingKey, authentication, credits, rateLimited, serviceUnavailable, rejected(Int)
    case invalidResponse, unsupportedAudio, missingAudioRate, incompleteAudio, emptyAudio, audioTooLong, timedOut, network, playback
    var errorDescription: String? {
        switch self {
        case .emptyText: return "There is no reply to speak."
        case .textTooLong: return "This reply is too long to read aloud."
        case .missingKey: return "Add your OpenRouter key to hear spoken replies."
        case .authentication: return "OpenRouter did not accept the key for spoken replies."
        case .credits: return "OpenRouter needs more credits for spoken replies."
        case .rateLimited: return "Spoken replies are busy. Try again shortly."
        case .serviceUnavailable: return "The voice service is temporarily unavailable."
        case .rejected(let status): return "The voice service declined this request (HTTP \(status))."
        case .invalidResponse: return "The voice service returned an invalid response."
        case .unsupportedAudio: return "The voice service returned an unsupported audio format."
        case .missingAudioRate: return "The voice service did not identify its audio sample rate."
        case .incompleteAudio: return "The voice stream ended with an incomplete audio frame."
        case .emptyAudio: return "The voice service returned no audio."
        case .audioTooLong: return "The spoken reply exceeded the audio limit."
        case .timedOut: return "The voice service took too long. Try again."
        case .network: return "Could not connect to the voice service. Check your connection."
        case .playback: return "Could not play the spoken reply. Check your sound output."
        }
    }
}

/// Retains only an unfinished frame, even when network chunks split a sample.
struct SpeechPCMDecoder {
    let format: SpeechPCMFormat
    private var pending = Data()
    init(format: SpeechPCMFormat) { self.format = format }

    mutating func append(_ data: Data) -> SpeechPCMChunk? {
        pending.append(data)
        let usable = pending.count - pending.count % format.bytesPerFrame
        guard usable > 0 else { return nil }
        var samples = [Float]()
        samples.reserveCapacity(usable / 2)
        pending.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in stride(from: 0, to: usable, by: 2) {
                let bits = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
                samples.append(Float(Int16(bitPattern: bits)) / 32_768)
            }
        }
        pending.removeFirst(usable)
        return SpeechPCMChunk(format: format, samples: samples)
    }

    func finish() throws {
        guard pending.isEmpty else { throw CloudSpeechError.incompleteAudio }
    }
}

final class OpenRouterSpeechClient: SpeechSynthesizing {
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/audio/speech")!
    static let model = "qwen/qwen-audio-3.0-tts-plus"
    static let voice = "longanlingxin"
    static let maximumCharacters = 6_000
    static let maximumAudioSeconds = 180
    private let session: URLSession
    private let fallbackFormat: SpeechPCMFormat?

    /// A fallback is only appropriate for a verified model/provider contract.
    /// Explicit response metadata always takes precedence.
    init(session: URLSession? = nil, fallbackFormat: SpeechPCMFormat? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 25
            configuration.timeoutIntervalForResource = 60
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            self.session = URLSession(configuration: configuration)
        }
        self.fallbackFormat = fallbackFormat
    }

    func synthesize(text: String, key: String, onChunk: @escaping @Sendable (SpeechPCMChunk) async throws -> Void) async throws -> SpeechSynthesisMetrics {
        try Task.checkCancellation()
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CloudSpeechError.emptyText }
        guard text.count <= Self.maximumCharacters, text.utf8.count <= Self.maximumCharacters * 4 else { throw CloudSpeechError.textTooLong }
        guard !key.isEmpty, !key.contains("\n"), !key.contains("\r") else { throw CloudSpeechError.missingKey }
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/pcm", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": Self.model, "input": text, "voice": Self.voice, "response_format": "pcm"])
        let start = ProcessInfo.processInfo.systemUptime
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw CloudSpeechError.invalidResponse }
            switch response.statusCode {
            case 200...299: break
            case 401, 403: throw CloudSpeechError.authentication
            case 402: throw CloudSpeechError.credits
            case 429: throw CloudSpeechError.rateLimited
            case 500...599: throw CloudSpeechError.serviceUnavailable
            default: throw CloudSpeechError.rejected(response.statusCode)
            }
            let format = try SpeechPCMFormat.response(response, fallback: fallbackFormat)
            let maximumBytes = format.sampleRate * format.bytesPerFrame * Self.maximumAudioSeconds
            if response.expectedContentLength > Int64(maximumBytes) { throw CloudSpeechError.audioTooLong }
            var decoder = SpeechPCMDecoder(format: format)
            var firstByte: TimeInterval?
            var byteCount = 0
            var block = Data()
            let blockSize = format.bytesPerFrame * 1024
            block.reserveCapacity(blockSize)
            for try await byte in bytes {
                try Task.checkCancellation()
                if firstByte == nil { firstByte = ProcessInfo.processInfo.systemUptime - start }
                byteCount += 1
                guard byteCount <= maximumBytes else { throw CloudSpeechError.audioTooLong }
                block.append(byte)
                if block.count >= blockSize {
                    if let chunk = decoder.append(block) { try await onChunk(chunk) }
                    block.removeAll(keepingCapacity: true)
                }
            }
            try Task.checkCancellation()
            if let chunk = decoder.append(block) { try await onChunk(chunk) }
            try decoder.finish()
            guard let firstByte, byteCount > 0 else { throw CloudSpeechError.emptyAudio }
            return SpeechSynthesisMetrics(firstByteSeconds: firstByte, requestSeconds: ProcessInfo.processInfo.systemUptime - start,
                                          audioSeconds: Double(byteCount) / Double(format.sampleRate * format.bytesPerFrame), byteCount: byteCount)
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            throw error.code == .timedOut ? CloudSpeechError.timedOut : CloudSpeechError.network
        } catch let error as CloudSpeechError { throw error }
        catch { throw Task.isCancelled ? CancellationError() : CloudSpeechError.network }
    }
}

/// Injectable so tests never initialize a sound device or play user audio.
@MainActor
protocol SpeechPCMSink: AnyObject {
    func prepare(format: SpeechPCMFormat, onStarted: @escaping @MainActor () -> Void) throws
    func enqueue(_ chunk: SpeechPCMChunk) async throws
    func finish() async throws
    func stop()
}

@MainActor
final class EngineSpeechPCMSink: SpeechPCMSink {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: SpeechPCMFormat?
    private var audioFormat: AVAudioFormat?
    private var queuedFrames = 0
    private var started = false
    private var generation = UUID()
    private var onStarted: (@MainActor () -> Void)?

    func prepare(format: SpeechPCMFormat, onStarted: @escaping @MainActor () -> Void) throws {
        stop()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let audioFormat = AVAudioFormat(standardFormatWithSampleRate: Double(format.sampleRate), channels: AVAudioChannelCount(format.channels)) else { throw CloudSpeechError.playback }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: audioFormat)
        self.engine = engine
        self.player = player
        self.format = format
        self.audioFormat = audioFormat
        self.onStarted = onStarted
    }

    func enqueue(_ chunk: SpeechPCMChunk) async throws {
        let token = generation
        guard chunk.format == format, let player, let audioFormat, chunk.frameCount > 0 else { throw CloudSpeechError.playback }
        // Back-pressure keeps the native audio queue bounded even when the
        // provider generates much faster than real-time speech.
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while queuedFrames > chunk.format.sampleRate * 2 {
            try await Task.sleep(nanoseconds: 20_000_000)
            guard generation == token else { throw CancellationError() }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CloudSpeechError.playback }
        }
        try Task.checkCancellation()
        guard generation == token, let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(chunk.frameCount)), let output = buffer.floatChannelData else { throw CloudSpeechError.playback }
        buffer.frameLength = AVAudioFrameCount(chunk.frameCount)
        for channel in 0..<chunk.format.channels {
            for frame in 0..<chunk.frameCount { output[channel][frame] = chunk.samples[frame * chunk.format.channels + channel] }
        }
        queuedFrames += chunk.frameCount
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.queuedFrames = max(0, self.queuedFrames - chunk.frameCount)
            }
        }
        if !started, queuedFrames >= Int(Double(chunk.format.sampleRate) * 0.08) { try start() }
    }

    private func start() throws {
        guard let engine, let player else { throw CloudSpeechError.playback }
        do { try engine.start() } catch { throw CloudSpeechError.playback }
        player.play()
        started = true
        onStarted?()
    }

    func finish() async throws {
        let token = generation
        if queuedFrames > 0, !started { try start() }
        let deadline = ProcessInfo.processInfo.systemUptime + Self.drainTimeout(queuedFrames: queuedFrames, sampleRate: format?.sampleRate ?? 24_000)
        while queuedFrames > 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
            guard generation == token else { throw CancellationError() }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CloudSpeechError.playback }
        }
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }

    static func drainTimeout(queuedFrames: Int, sampleRate: Int) -> TimeInterval {
        Double(max(0, queuedFrames)) / Double(max(1, sampleRate)) + 5
    }

    func stop() {
        generation = UUID()
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
        format = nil
        audioFormat = nil
        queuedFrames = 0
        started = false
        onStarted = nil
    }
}

private struct PrefetchedSpeech: Sendable {
    let chunks: [SpeechPCMChunk]
    let metrics: SpeechSynthesisMetrics
}

/// One next utterance, bounded using decoded audio duration. It never touches
/// the audio engine: only speak() can consume these samples and play them.
actor SpeechPrefetchBuffer {
    private var format: SpeechPCMFormat?
    private var chunks: [SpeechPCMChunk] = []
    private var frames = 0

    func append(_ chunk: SpeechPCMChunk) throws {
        try Task.checkCancellation()
        guard chunk.frameCount > 0, chunk.samples.count % chunk.format.channels == 0,
              format == nil || format == chunk.format else { throw CloudSpeechError.unsupportedAudio }
        guard chunk.frameCount <= chunk.format.sampleRate * OpenRouterSpeechClient.maximumAudioSeconds - frames,
              chunks.count < 10_000 else { throw CloudSpeechError.audioTooLong }
        format = chunk.format
        frames += chunk.frameCount
        chunks.append(chunk)
    }

    func completedChunks() throws -> [SpeechPCMChunk] {
        try Task.checkCancellation()
        guard !chunks.isEmpty else { throw CloudSpeechError.emptyAudio }
        return chunks
    }
}

@MainActor
final class CloudSpeechOutput: SpeechOutput {
    private struct Prefetch {
        let text: String
        let key: String
        let task: Task<PrefetchedSpeech, Error>
    }
    private let synthesizer: SpeechSynthesizing
    private let sink: SpeechPCMSink
    private var task: Task<SpeechSynthesisMetrics, Error>?
    private var prefetched: Prefetch?
    private var generation = UUID()
    private var prepared = false
    private var stateCallback: (@MainActor (SpeechOutputState) -> Void)?
    private(set) var lastMetrics: SpeechSynthesisMetrics?

    init(synthesizer: SpeechSynthesizing = OpenRouterSpeechClient(), sink: SpeechPCMSink? = nil) {
        self.synthesizer = synthesizer
        self.sink = sink ?? EngineSpeechPCMSink()
    }

    func speak(_ text: String, key: String, onState: @escaping @MainActor (SpeechOutputState) -> Void) async throws {
        try Task.checkCancellation()
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let ready: Task<PrefetchedSpeech, Error>?
        if let prefetched, prefetched.text == cleanText, prefetched.key == cleanKey {
            ready = prefetched.task
            self.prefetched = nil
        } else {
            discardPrefetch()
            ready = nil
        }
        stopPlayback()
        let token = generation
        stateCallback = onState
        lastMetrics = nil
        let worker = Task { [self] in
            let metrics: SpeechSynthesisMetrics
            if let ready {
                let result = try await withTaskCancellationHandler {
                    try await ready.value
                } onCancel: { ready.cancel() }
                try Task.checkCancellation()
                for chunk in result.chunks { try await receive(chunk, token: token) }
                metrics = result.metrics
            } else {
                // The initial utterance still goes straight from the network to
                // playback; only an explicitly prefetched next utterance waits
                // for its cached result.
                metrics = try await synthesizer.synthesize(text: text, key: key) { [weak self] chunk in
                    guard let self else { throw CancellationError() }
                    try await self.receive(chunk, token: token)
                }
            }
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            try await sink.finish()
            return metrics
        }
        task = worker
        // Install the current worker before notifying observers: they can
        // immediately Stop or prefetch the following utterance in this callback.
        onState(.preparing)
        defer {
            if generation == token {
                sink.stop()
                task = nil
                stateCallback?(.idle)
                stateCallback = nil
            }
        }
        let metrics = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        lastMetrics = metrics
    }

    func prefetch(_ text: String, key: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= OpenRouterSpeechClient.maximumCharacters,
              text.utf8.count <= OpenRouterSpeechClient.maximumCharacters * 4, !key.isEmpty else { return }
        if let prefetched, prefetched.text == text, prefetched.key == key { return }
        discardPrefetch()
        let synthesizer = self.synthesizer
        let worker = Task {
            let buffer = SpeechPrefetchBuffer()
            let metrics = try await synthesizer.synthesize(text: text, key: key) { chunk in
                try await buffer.append(chunk)
            }
            try Task.checkCancellation()
            let chunks = try await buffer.completedChunks()
            return PrefetchedSpeech(chunks: chunks, metrics: metrics)
        }
        prefetched = Prefetch(text: text, key: key, task: worker)
    }

    private func discardPrefetch() {
        prefetched?.task.cancel()
        prefetched = nil
    }

    private func receive(_ chunk: SpeechPCMChunk, token: UUID) async throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        if !prepared {
            try sink.prepare(format: chunk.format) { [weak self] in
                guard let self, self.generation == token else { return }
                self.stateCallback?(.speaking)
            }
            prepared = true
        }
        try await sink.enqueue(chunk)
    }

    func stop() {
        discardPrefetch()
        stopPlayback()
    }

    private func stopPlayback() {
        generation = UUID()
        prepared = false
        task?.cancel()
        task = nil
        sink.stop()
        stateCallback?(.idle)
        stateCallback = nil
    }
}
