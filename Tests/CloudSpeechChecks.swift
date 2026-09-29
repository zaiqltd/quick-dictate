import Foundation

final class SpeechMockURLProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var headers = ["Content-Type": "audio/pcm;rate=24000;channels=1"]
        var chunks: [(Data, UInt64)]
    }
    static var handler: ((URLRequest) throws -> Reply)!
    static var requests = 0
    private var work: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        work = Task {
            do {
                let reply = try Self.handler(request)
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!, cacheStoragePolicy: .notAllowed)
                for (data, delay) in reply.chunks {
                    if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                    try Task.checkCancellation()
                    client?.urlProtocol(self, didLoad: data)
                }
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                if !Task.isCancelled { client?.urlProtocol(self, didFailWithError: error) }
            }
        }
    }
    override func stopLoading() { work?.cancel() }
    static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}

@MainActor private final class SpeechChunkCollector {
    var chunks: [SpeechPCMChunk] = []
    var firstAt: TimeInterval?
    func append(_ chunk: SpeechPCMChunk) {
        if firstAt == nil { firstAt = ProcessInfo.processInfo.systemUptime }
        chunks.append(chunk)
    }
}

private final class SpeechFixtureSynthesizer: SpeechSynthesizing {
    var handler: ((String, String, @escaping @Sendable (SpeechPCMChunk) async throws -> Void) async throws -> SpeechSynthesisMetrics)!
    func synthesize(text: String, key: String, onChunk: @escaping @Sendable (SpeechPCMChunk) async throws -> Void) async throws -> SpeechSynthesisMetrics {
        try await handler(text, key, onChunk)
    }
}

@MainActor private final class SpeechFixtureSink: SpeechPCMSink {
    var formats: [SpeechPCMFormat] = []
    var chunks: [SpeechPCMChunk] = []
    var stops = 0
    var finishes = 0
    var onStarted: (@MainActor () -> Void)?
    var finishHandler: (() async throws -> Void)?
    var prepareError: Error?
    func prepare(format: SpeechPCMFormat, onStarted: @escaping @MainActor () -> Void) throws {
        if let prepareError { throw prepareError }
        formats.append(format)
        self.onStarted = onStarted
    }
    func enqueue(_ chunk: SpeechPCMChunk) async throws {
        chunks.append(chunk)
        onStarted?()
        onStarted = nil
    }
    func finish() async throws {
        finishes += 1
        try await finishHandler?()
    }
    func stop() { stops += 1; onStarted = nil }
}

@MainActor private final class SpeechPrefetchProbe {
    var requests: [(String, String)] = []
    var produced = Set<Int>()
    var released = Set<Int>()
    var completed = Set<Int>()
    var cancelled = Set<Int>()
    var automatic = false
    func started(_ text: String, key: String) -> Int {
        let index = requests.count
        requests.append((text, key))
        return index
    }
    func isReleased(_ index: Int) -> Bool { automatic || released.contains(index) }
}

extension CoreTests {
    @MainActor static func cloudSpeechChecks() async throws {
        func waitFor(_ description: String, _ predicate: () -> Bool) async {
            for _ in 0..<200 {
                if predicate() { check(true, description); return }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            check(false, "Timed out: \(description)")
        }
        let format = try SpeechPCMFormat(sampleRate: 24_000)
        func response(_ type: String?) -> HTTPURLResponse {
            HTTPURLResponse(url: OpenRouterSpeechClient.endpoint, statusCode: 200, httpVersion: nil, headerFields: type.map { ["Content-Type": $0] } ?? [:])!
        }
        let parsed = try SpeechPCMFormat.response(response("audio/pcm;rate=24000;channels=1"))
        check(parsed == format && parsed.bytesPerFrame == 2, "Speech reads live-verified Qwen PCM rate/channel metadata")
        let stereo = try SpeechPCMFormat.response(response("AUDIO/PCM; rate=\"48000\"; channels=\"2\"; encoding=pcm_s16le"))
        check(stereo.sampleRate == 48_000 && stereo.channels == 2 && stereo.bytesPerFrame == 4, "Speech PCM parser handles quoted metadata and stereo")
        for type in [nil, "audio/mpeg", "application/json", "audio/pcm;rate=no", "audio/pcm;rate=0", "audio/pcm;rate=96000", "audio/pcm;rate=24000;channels=3", "audio/pcm;rate=24000;channels=x", "audio/pcm;rate=24000;encoding=pcm_s16be"] as [String?] {
            await expectError("unsupported audio") { _ = try SpeechPCMFormat.response(response(type)) }
        }
        await expectError("sample rate") { _ = try SpeechPCMFormat.response(response("audio/pcm")) }
        let fallback = try SpeechPCMFormat.response(response("audio/pcm"), fallback: format)
        check(fallback == format, "Only an explicitly supplied verified PCM fallback fills absent rate metadata")
        let headerPriority = try SpeechPCMFormat.response(response("audio/pcm;rate=48000;channels=2"), fallback: format)
        check(headerPriority == stereo, "Response metadata always overrides explicit PCM fallback")
        await expectError("unsupported audio") { _ = try SpeechPCMFormat(sampleRate: 7999) }
        await expectError("unsupported audio") { _ = try SpeechPCMFormat(sampleRate: 24_000, channels: 0) }

        var decoder = SpeechPCMDecoder(format: format)
        check(decoder.append(Data([0])) == nil, "An incomplete sample is held without emitting corrupted audio")
        let decoded = decoder.append(Data([128, 255, 255, 0, 0, 255, 127]))!
        check(decoded.samples == [-1, -1.0 / 32768, 0, 32767.0 / 32768], "PCM decoding preserves signed little-endian extrema and silence")
        check(decoded.frameCount == 4, "Mono PCM frame count is correct")
        try decoder.finish()
        check(decoder.append(Data()) == nil, "Empty chunks produce no audio")
        _ = decoder.append(Data([1]))
        await expectError("incomplete audio frame") { try decoder.finish() }
        var stereoDecoder = SpeechPCMDecoder(format: stereo)
        check(stereoDecoder.append(Data([0, 0, 0])) == nil, "Stereo decoder keeps a whole incomplete frame")
        let stereoChunk = stereoDecoder.append(Data([128]))!
        check(stereoChunk.samples == [0, -1] && stereoChunk.frameCount == 1, "Stereo samples retain channel ordering across byte boundaries")
        try stereoDecoder.finish()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpeechMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = OpenRouterSpeechClient(session: session)
        let collector = SpeechChunkCollector()
        SpeechMockURLProtocol.requests = 0
        await expectError("no reply") { _ = try await client.synthesize(text: " \n", key: "test-key") { _ in } }
        await expectError("too long") { _ = try await client.synthesize(text: String(repeating: "x", count: 6001), key: "test-key") { _ in } }
        await expectError("OpenRouter key") { _ = try await client.synthesize(text: "Hi", key: " ") { _ in } }
        await expectError("OpenRouter key") { _ = try await client.synthesize(text: "Hi", key: "bad\nheader") { _ in } }
        check(SpeechMockURLProtocol.requests == 0, "Invalid speech requests never reach the network")

        SpeechMockURLProtocol.handler = { request in
            check(request.url == OpenRouterSpeechClient.endpoint && request.httpMethod == "POST", "Speech uses only OpenRouter's fixed speech endpoint")
            check(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key", "Speech key appears only in the authorization header")
            check(request.value(forHTTPHeaderField: "Accept") == "audio/pcm" && request.value(forHTTPHeaderField: "Content-Type") == "application/json", "Speech requests raw PCM using JSON input")
            check(request.timeoutInterval == 25, "Speech request timeout is bounded")
            let body = try SpeechMockURLProtocol.body(request)
            check(body["model"] as? String == "qwen/qwen-audio-3.0-tts-plus", "Speech uses the exact available Qwen model ID")
            check(body["voice"] as? String == "longanlingxin" && body["response_format"] as? String == "pcm", "Speech uses the verified English-capable voice and PCM format")
            check(body["input"] as? String == "Hello." && body.count == 4, "Speech sends only required input without recording, context, or key data")
            return .init(chunks: [(Data(repeating: 0, count: 2048), 0), (Data([255]), 120_000_000), (Data([127]), 0)])
        }
        let begin = ProcessInfo.processInfo.systemUptime
        let metrics = try await client.synthesize(text: " Hello. ", key: " test-key ") { chunk in await collector.append(chunk) }
        check(collector.chunks.count == 2 && collector.chunks[0].frameCount == 1024 && collector.chunks[1].samples == [32767.0 / 32768], "Speech streams bounded sample blocks and a complete trailing frame")
        check(collector.firstAt! - begin < metrics.requestSeconds - 0.05, "Speech emits the first audio block before the delayed remainder finishes")
        check(metrics.byteCount == 2050 && abs(metrics.audioSeconds - 2050.0 / 48000) < 0.00001, "Speech reports measured byte count and PCM duration")
        check(metrics.firstByteSeconds >= 0 && metrics.firstByteSeconds < metrics.requestSeconds && metrics.requestSeconds >= 0.10, "Speech reports separate first-byte and total request latency")

        for (status, message) in [(401, "did not accept"), (403, "did not accept"), (402, "credits"), (429, "busy"), (503, "unavailable"), (400, "HTTP 400")] {
            SpeechMockURLProtocol.handler = { _ in .init(status: status, headers: ["Content-Type": "application/json"], chunks: [(Data("PRIVATE-KEY private request details".utf8), UInt64(0))]) }
            await expectError(message) { _ = try await client.synthesize(text: "Hi", key: "test-key") { _ in check(false, "An HTTP error never becomes audio") } }
        }
        for (headers, bytes, message) in [(["Content-Type": "audio/pcm"], Data([0, 0]), "sample rate"),
                                         (["Content-Type": "audio/mpeg"], Data([0, 0]), "unsupported audio"),
                                         (["Content-Type": "audio/pcm;rate=24000"], Data([1]), "incomplete audio frame"),
                                         (["Content-Type": "audio/pcm;rate=24000"], Data(), "no audio"),
                                         (["Content-Type": "audio/pcm;rate=8000", "Content-Length": "2880001"], Data([0, 0]), "audio limit")] {
            SpeechMockURLProtocol.handler = { _ in .init(headers: headers, chunks: [(bytes, UInt64(0))]) }
            await expectError(message) { _ = try await client.synthesize(text: "Hi", key: "test-key") { _ in } }
        }
        SpeechMockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        await expectError("took too long") { _ = try await client.synthesize(text: "Hi", key: "test-key") { _ in } }
        SpeechMockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await expectError("Check your connection") { _ = try await client.synthesize(text: "Hi", key: "test-key") { _ in } }
        SpeechMockURLProtocol.handler = { _ in .init(chunks: [(Data(repeating: 0, count: 4096), 0)]) }
        await expectError("sound output") { _ = try await client.synthesize(text: "Hi", key: "test-key") { _ in throw CloudSpeechError.playback } }
        do {
            _ = try await client.synthesize(text: "Hi", key: "test-key") { _ in throw CancellationError() }
            check(false, "Cancelled audio consumer must stop streaming")
        } catch { check(error is CancellationError, "Audio consumer cancellation propagates without a network error") }
        let requestCount = SpeechMockURLProtocol.requests
        let cancelled = Task {
            try await Task.sleep(nanoseconds: 10_000_000)
            return try await client.synthesize(text: "Hi", key: "test-key") { _ in }
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; check(false, "Cancelled speech request must fail") }
        catch { check(error is CancellationError, "Pre-request cancellation remains cancellation") }
        check(SpeechMockURLProtocol.requests == requestCount, "Pre-cancelled speech does not make a request")
        let streamingCollector = SpeechChunkCollector()
        SpeechMockURLProtocol.handler = { _ in .init(chunks: [(Data(repeating: 0, count: 2048), 0), (Data(repeating: 0, count: 2048), 5_000_000_000)]) }
        let networkStream = Task { try await client.synthesize(text: "Hi", key: "test-key") { chunk in await streamingCollector.append(chunk) } }
        for _ in 0..<100 where streamingCollector.chunks.isEmpty { try await Task.sleep(nanoseconds: 2_000_000) }
        check(streamingCollector.chunks.count == 1, "Network stream delivers its first audio before cancellation")
        networkStream.cancel()
        do { _ = try await networkStream.value; check(false, "An in-flight cancelled stream must fail") }
        catch { check(error is CancellationError, "Cancellation interrupts waiting for additional network bytes") }
        check(streamingCollector.chunks.count == 1, "Cancelled network stream does not deliver later chunks")

        let synth = SpeechFixtureSynthesizer()
        let sink = SpeechFixtureSink()
        let output = CloudSpeechOutput(synthesizer: synth, sink: sink)
        let chunk = SpeechPCMChunk(format: format, samples: [0, 0.25, -0.25])
        let fixtureMetrics = SpeechSynthesisMetrics(firstByteSeconds: 0.1, requestSeconds: 0.2, audioSeconds: 0.3, byteCount: 6)
        var states: [SpeechOutputState] = []
        synth.handler = { text, key, receive in
            check(text == "Hello" && key == "fixture-key", "Speech output forwards only current reply text and supplied key")
            try await receive(chunk)
            try await receive(chunk)
            return fixtureMetrics
        }
        try await output.speak("Hello", key: "fixture-key") { states.append($0) }
        check(states == [.preparing, .speaking, .idle], "Voice states reflect actual sink startup and completion")
        check(sink.formats == [format] && sink.chunks.count == 2 && sink.finishes == 1, "Voice prepares once and enqueues chunks before awaiting playback completion")
        check(output.lastMetrics == fixtureMetrics && sink.stops == 2, "Successful voice stores timing and releases playback resources")

        states = []
        synth.handler = { _, _, _ in throw CloudSpeechError.serviceUnavailable }
        await expectError("unavailable") { try await output.speak("Hello", key: "fixture-key") { states.append($0) } }
        check(states == [.preparing, .idle] && output.lastMetrics == nil, "A synthesis failure resets voice without claiming it spoke")
        sink.prepareError = CloudSpeechError.playback
        synth.handler = { _, _, receive in try await receive(chunk); return fixtureMetrics }
        states = []
        await expectError("sound output") { try await output.speak("Hello", key: "fixture-key") { states.append($0) } }
        check(states == [.preparing, .idle], "Sound-device failure returns to idle")
        sink.prepareError = nil

        // An uncooperative provider can still call back after stop; generation
        // checks prevent that late reply from reaching the native player.
        let beforeChunks = sink.chunks.count
        var waiting = false
        var release = false
        states = []
        synth.handler = { _, _, receive in
            await MainActor.run { waiting = true }
            while !(await MainActor.run { release }) { try? await Task.sleep(nanoseconds: 2_000_000) }
            try await receive(chunk)
            return fixtureMetrics
        }
        let speaking = Task { try await output.speak("Late", key: "fixture-key") { states.append($0) } }
        for _ in 0..<100 where !waiting { try await Task.sleep(nanoseconds: 2_000_000) }
        check(waiting, "Delayed synthesis is active before cancellation")
        output.stop()
        release = true
        do { try await speaking.value; check(false, "Stopped voice must not succeed") }
        catch { check(error is CancellationError, "Stop cancels even an uncooperative late speech callback") }
        check(sink.chunks.count == beforeChunks && states == [.preparing, .idle], "No late audio or misleading speaking state appears after Stop")

        sink.finishHandler = { try await Task.sleep(nanoseconds: 5_000_000_000) }
        synth.handler = { _, _, receive in try await receive(chunk); return fixtureMetrics }
        states = []
        let beforeFinish = sink.finishes
        let draining = Task { try await output.speak("Playing", key: "fixture-key") { states.append($0) } }
        for _ in 0..<100 where sink.finishes == beforeFinish { try await Task.sleep(nanoseconds: 2_000_000) }
        check(sink.finishes > beforeFinish && states == [.preparing, .speaking], "Voice remains speaking while queued audio drains")
        draining.cancel()
        do { try await draining.value; check(false, "Cancellation during playback must stop") }
        catch { check(error is CancellationError, "Outer task cancellation reaches the playback drain") }
        check(states == [.preparing, .speaking, .idle], "Cancelled playback always returns to idle")
        sink.finishHandler = nil

        waiting = false
        release = false
        var oldStates: [SpeechOutputState] = []
        var newStates: [SpeechOutputState] = []
        synth.handler = { _, _, receive in
            await MainActor.run { waiting = true }
            while !(await MainActor.run { release }) { try? await Task.sleep(nanoseconds: 2_000_000) }
            try await receive(chunk)
            return fixtureMetrics
        }
        let oldSpeech = Task { try await output.speak("Old", key: "fixture-key") { oldStates.append($0) } }
        for _ in 0..<100 where !waiting { try await Task.sleep(nanoseconds: 2_000_000) }
        check(waiting, "Replacement test starts with an active old request")
        synth.handler = { _, _, receive in try await receive(chunk); return fixtureMetrics }
        var finishNew = false
        sink.finishHandler = { while !finishNew { try await Task.sleep(nanoseconds: 2_000_000) } }
        let newSpeech = Task { try await output.speak("New", key: "fixture-key") { newStates.append($0) } }
        for _ in 0..<100 where !newStates.contains(.speaking) { try await Task.sleep(nanoseconds: 2_000_000) }
        check(oldStates == [.preparing, .idle] && newStates == [.preparing, .speaking], "A new spoken reply replaces the old generation and starts normally")
        let stopsDuringNew = sink.stops
        release = true
        do { try await oldSpeech.value; check(false, "A replaced voice request must cancel") }
        catch { check(error is CancellationError, "Replacement cancels the original request") }
        check(sink.stops == stopsDuringNew && newStates == [.preparing, .speaking], "Late old completion cannot stop or reset the replacement voice")
        finishNew = true
        try await newSpeech.value
        check(newStates == [.preparing, .speaking, .idle], "Replacement audio finishes with one correct idle transition")
        sink.finishHandler = nil

        check(EngineSpeechPCMSink.drainTimeout(queuedFrames: 48_000, sampleRate: 24_000) == 7,
              "A two-second playback queue allows only seven seconds to drain after an output-device stall")
        check(EngineSpeechPCMSink.drainTimeout(queuedFrames: 0, sampleRate: 24_000) == 5,
              "Drain grace period is independent of the full response limit")

        let bounded = SpeechPrefetchBuffer()
        await expectError("no audio") { _ = try await bounded.completedChunks() }
        try await bounded.append(chunk)
        await expectError("unsupported audio") { try await bounded.append(SpeechPCMChunk(format: stereo, samples: [0, 0])) }
        await expectError("unsupported audio") { try await bounded.append(SpeechPCMChunk(format: format, samples: [])) }
        let lowRate = try SpeechPCMFormat(sampleRate: 8000)
        let oversize = SpeechPCMChunk(format: lowRate, samples: [Float](repeating: 0, count: 8000 * OpenRouterSpeechClient.maximumAudioSeconds + 1))
        let excessive = SpeechPrefetchBuffer()
        await expectError("audio limit") { try await excessive.append(oversize) }
        let boundedChunks = try await bounded.completedChunks()
        check(boundedChunks.count == 1 && boundedChunks[0].samples == chunk.samples, "Rejected prefetch chunks cannot corrupt the bounded cache")

        func controlled() -> (CloudSpeechOutput, SpeechFixtureSink, SpeechPrefetchProbe) {
            let fake = SpeechFixtureSynthesizer()
            let sink = SpeechFixtureSink()
            let probe = SpeechPrefetchProbe()
            fake.handler = { text, key, receive in
                let index = probe.started(text, key: key)
                do {
                    try await receive(SpeechPCMChunk(format: format, samples: [Float(index + 1) / 10]))
                    await MainActor.run { _ = probe.produced.insert(index) }
                    while !probe.isReleased(index) { try await Task.sleep(nanoseconds: 2_000_000) }
                    await MainActor.run { _ = probe.completed.insert(index) }
                    return fixtureMetrics
                } catch {
                    if error is CancellationError { await MainActor.run { _ = probe.cancelled.insert(index) } }
                    throw error
                }
            }
            return (CloudSpeechOutput(synthesizer: fake, sink: sink), sink, probe)
        }

        do {
            let (voice, audio, probe) = controlled()
            var firstStates: [SpeechOutputState] = []
            let first = Task { try await voice.speak("First", key: "fixture-key") { firstStates.append($0) } }
            await waitFor("Initial speech reaches playback while its network stream is unfinished", { audio.chunks.count == 1 && probe.produced.contains(0) })
            check(probe.completed.isEmpty && firstStates == [.preparing, .speaking], "First utterance still streams immediately rather than waiting for a complete file")
            voice.prefetch(" Next ", key: " fixture-key ")
            await waitFor("Next utterance generates while the first is still playing", { probe.produced.contains(1) })
            check(audio.chunks.count == 1 && audio.finishes == 0 && firstStates == [.preparing, .speaking], "Prefetch does not touch current playback or emit speech states")
            voice.prefetch("Next", key: "fixture-key")
            probe.released.insert(1)
            await waitFor("Prefetched next utterance finishes in the background", { probe.completed.contains(1) })
            check(probe.requests.count == 2 && audio.chunks.count == 1, "Repeated matching prefetch does not restart synthesis or play ahead")
            probe.released.insert(0)
            try await first.value
            probe.automatic = true
            var nextStates: [SpeechOutputState] = []
            try await voice.speak("Next", key: "fixture-key") { nextStates.append($0) }
            check(probe.requests.count == 2, "The next speak consumes its matching cache without another network request")
            check(audio.chunks.map(\.samples) == [[0.1], [0.2]] && nextStates == [.preparing, .speaking, .idle], "Cached speech plays once, in order, with normal lifecycle states")
            check(voice.lastMetrics == fixtureMetrics, "Consumed prefetch preserves measured synthesis metrics")
        }
        do {
            let (voice, audio, probe) = controlled()
            voice.prefetch("Pending", key: "fixture-key")
            await waitFor("Pending prefetch has received audio", { probe.produced.contains(0) })
            var pendingStates: [SpeechOutputState] = []
            let pending = Task { try await voice.speak("Pending", key: "fixture-key") { pendingStates.append($0) } }
            await waitFor("Matching speak awaits the in-flight prefetch", { pendingStates == [.preparing] })
            voice.stop()
            do { try await pending.value; check(false, "Stopped pending prefetch must cancel") }
            catch { check(error is CancellationError, "Stop cancels a prefetch already consumed by speak") }
            check(audio.chunks.isEmpty && pendingStates == [.preparing, .idle] && probe.cancelled.contains(0), "Cancelled prefetch cannot play cached or later audio")
        }
        do {
            let (voice, audio, probe) = controlled()
            var callbackStates: [SpeechOutputState] = []
            let first = Task {
                try await voice.speak("Current", key: "fixture-key") { state in
                    callbackStates.append(state)
                    if state == .preparing { voice.prefetch("Following", key: "fixture-key") }
                }
            }
            await waitFor("Prefetch from Preparing coexists with the installed current worker", { probe.produced.count == 2 && audio.chunks.count == 1 })
            check(probe.requests.map(\.0) == ["Current", "Following"], "Preparing callback prefetch cannot start ahead of the current synthesis task")
            voice.stop()
            do { try await first.value; check(false, "Stop must cancel active playback and future synthesis") }
            catch { check(error is CancellationError, "Stop cancels the current streaming utterance") }
            await waitFor("Stop cancels both current and prefetched requests", { probe.cancelled.count == 2 })
            check(audio.chunks.count == 1 && callbackStates == [.preparing, .speaking, .idle], "Cancelled next utterance never reaches audio or emits its own states")
        }
        do {
            let (voice, audio, probe) = controlled()
            voice.prefetch("Old", key: "fixture-key")
            await waitFor("Old prefetch starts", { probe.produced.contains(0) })
            voice.prefetch("Replacement", key: "fixture-key")
            await waitFor("Only the replacement prefetch remains active", { probe.produced.contains(1) && probe.cancelled.contains(0) })
            probe.automatic = true
            try await voice.speak("Replacement", key: "fixture-key") { _ in }
            check(probe.requests.count == 2 && audio.chunks.map(\.samples) == [[0.2]], "Replaced prefetch neither consumes another cache nor reaches playback")
            voice.prefetch("Discarded by stop", key: "fixture-key")
            await waitFor("A future prefetch starts after current playback completes", { probe.requests.count == 3 })
            voice.stop()
            try await voice.speak("Discarded by stop", key: "fixture-key") { _ in }
            check(probe.requests.count == 4 && audio.chunks.last?.samples == [0.4], "Stop discards even a completed cache so it cannot leak into a later reply")
        }
        do {
            let (voice, audio, probe) = controlled()
            probe.automatic = true
            voice.prefetch("Same text", key: "old-fixture-key")
            await waitFor("Old-key cache finishes", { probe.completed.contains(0) })
            try await voice.speak("Same text", key: "new-fixture-key") { _ in }
            check(probe.requests.count == 2 && probe.requests[1].1 == "new-fixture-key" && audio.chunks.map(\.samples) == [[0.2]],
                  "A changed key cannot reuse prefetched audio from the prior request")
            voice.prefetch("", key: "fixture-key")
            voice.prefetch(String(repeating: "x", count: 6001), key: "fixture-key")
            voice.prefetch("Valid text", key: " ")
            for _ in 0..<5 { await Task.yield() }
            check(probe.requests.count == 2, "Invalid prefetch input never starts synthesis")
        }
        do {
            let fake = SpeechFixtureSynthesizer()
            let audio = SpeechFixtureSink()
            var requests = 0
            fake.handler = { _, _, _ in
                await MainActor.run { requests += 1 }
                throw CloudSpeechError.serviceUnavailable
            }
            let voice = CloudSpeechOutput(synthesizer: fake, sink: audio)
            voice.prefetch("Unavailable", key: "fixture-key")
            await waitFor("Prefetch failure is retained for its matching utterance", { requests == 1 })
            var failedStates: [SpeechOutputState] = []
            await expectError("unavailable") { try await voice.speak("Unavailable", key: "fixture-key") { failedStates.append($0) } }
            check(requests == 1 && audio.chunks.isEmpty && failedStates == [.preparing, .idle], "A failed prefetch surfaces safely without duplicate spending or playback")
        }
    }
}
