import AVFoundation
import Observation

/// Microphone quality test: records a few seconds of the user reading a reference
/// sentence, then reports two independent signals —
///   1. Local DSP metrics (peak level, clipping, noise-floor/SNR estimate) — instant,
///      no network needed.
///   2. Real transcription accuracy — sends the recording through the same OpenAI
///      transcription endpoint dictation uses, and compares the result word-for-word
///      against the reference sentence. This is the metric that actually answers
///      "will my dictation come out correct", not just "is it loud enough".
/// Combines both into a verdict + concrete Slovak-language suggestions.
@Observable
@MainActor
final class MicTestEngine {
    static let shared = MicTestEngine()

    enum Phase: Equatable {
        case idle
        case preparing(secondsLeft: Int)
        case recording(secondsLeft: Int)
        case analyzing
        case done
        case failed(String)
    }

    enum Verdict: Int, Comparable {
        case excellent, good, marginal, poor
        static func < (l: Verdict, r: Verdict) -> Bool { l.rawValue < r.rawValue }
    }

    struct Result {
        var peakDBFS: Double
        var rmsDBFS: Double
        var clippingPercent: Double
        var snrDB: Double?
        var transcript: String?
        var matchPercent: Double?
        var verdict: Verdict
        var suggestions: [String]
    }

    static let referenceSentences = [
        "Skúšam kvalitu mikrofónu, aby som zistil, či je zvuk dostatočne hlasný a zrozumiteľný.",
        "Dnes je pekný slnečný deň a ideme sa prejsť do parku pri rieke.",
        "Prosím, over si nastavenia hlasitosti a skús diktovanie ešte raz."
    ]

    private(set) var phase: Phase = .idle
    private(set) var result: Result?
    private(set) var referenceText: String = MicTestEngine.referenceSentences[0]
    private(set) var liveLevel: Float = 0

    private var deviceCapture: DeviceCapture?
    private var systemTap: AVAudioEngine?
    private var captureSampleRate: Double = 24_000
    private let sampleStore = MicTestSampleStore()
    private var testTask: Task<Void, Never>?
    private var levelPollTask: Task<Void, Never>?

    private init() {}

    // ponytail: 9s (was 6s) — the reference sentences run ~5-7s read at a natural pace,
    // and the old duration left no margin, cutting the tail off mid-sentence and tanking
    // the transcript-match score. The prep countdown adds further reaction-time margin.
    func startTest(durationSeconds: Int = 9, prepSeconds: Int = 2) {
        guard phase == .idle || isTerminal(phase) else { return }
        referenceText = Self.referenceSentences.randomElement() ?? Self.referenceSentences[0]
        result = nil
        sampleStore.reset()
        testTask = Task { await runTest(durationSeconds: durationSeconds, prepSeconds: prepSeconds) }
    }

    func cancel() {
        testTask?.cancel()
        levelPollTask?.cancel()
        liveLevel = 0
        teardownCapture()
        phase = .idle
    }

    private func isTerminal(_ p: Phase) -> Bool {
        if case .done = p { return true }
        if case .failed = p { return true }
        return false
    }

    // MARK: - Recording

    private func runTest(durationSeconds: Int, prepSeconds: Int) async {
        // Give the user a beat to get ready to read before the mic actually starts —
        // previously recording began the instant the button was clicked, so the first
        // words were often missed or the tail got cut off within the fixed window.
        for remaining in stride(from: prepSeconds, through: 1, by: -1) {
            if Task.isCancelled { return }
            phase = .preparing(secondsLeft: remaining)
            try? await Task.sleep(for: .seconds(1))
        }
        if Task.isCancelled { return }

        do {
            try setupCapture()
        } catch {
            phase = .failed("Nepodarilo sa spustiť mikrofón: \(error.localizedDescription)")
            return
        }

        testLevelHolder.update(0)
        levelPollTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                self.liveLevel = testLevelHolder.current
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        for remaining in stride(from: durationSeconds, through: 1, by: -1) {
            if Task.isCancelled { teardownCapture(); return }
            phase = .recording(secondsLeft: remaining)
            try? await Task.sleep(for: .seconds(1))
        }
        levelPollTask?.cancel()
        liveLevel = 0
        teardownCapture()
        if Task.isCancelled { return }

        phase = .analyzing
        let samples = sampleStore.floatSamples()
        let pcm16 = sampleStore.pcm16Data()
        let dsp = Self.analyzeDSP(samples, sampleRate: captureSampleRate)

        var transcript: String?
        var matchPercent: Double?
        let dictation = DictationEngine.shared
        if dictation.hasOpenAIKey, !pcm16.isEmpty {
            transcript = await Self.transcribe(pcm16: pcm16, apiKey: dictation.openAIKey)
            if let t = transcript {
                matchPercent = Self.wordMatchPercent(reference: referenceText, transcript: t)
            }
        }

        let (verdict, suggestions) = Self.buildVerdict(
            peakDBFS: dsp.peakDBFS, clippingPercent: dsp.clippingPercent,
            snrDB: dsp.snrDB, matchPercent: matchPercent,
            hasTranscript: transcript != nil
        )
        result = Result(peakDBFS: dsp.peakDBFS, rmsDBFS: dsp.rmsDBFS,
                         clippingPercent: dsp.clippingPercent, snrDB: dsp.snrDB,
                         transcript: transcript, matchPercent: matchPercent,
                         verdict: verdict, suggestions: suggestions)
        phase = .done
    }

    // MARK: - Capture setup (mirrors DictationEngine's explicit-device/system-default split)

    private func setupCapture() throws {
        let pcm16Format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!

        if let uid = DictationEngine.shared.resolvedInputDeviceUID(),
           let device = AudioDeviceManager.inputDevices().first(where: { $0.uid == uid }) {
            guard let capture = DeviceCapture.make(deviceID: device.id) else {
                throw MicTestError.setupFailed
            }
            guard let converter = AVAudioConverter(from: capture.format, to: pcm16Format) else {
                throw MicTestError.setupFailed
            }
            captureSampleRate = capture.format.sampleRate
            let store = sampleStore
            capture.onBuffer = { [captureSampleRate = self.captureSampleRate] buffer in
                store.appendFloat(buffer: buffer)
                store.appendPCM16(buffer: buffer, inputSampleRate: captureSampleRate, converter: converter, pcm16Format: pcm16Format)
                Self.updateLiveLevel(buffer)
            }
            guard capture.start() else { throw MicTestError.setupFailed }
            deviceCapture = capture
        } else {
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let fmt = inputNode.outputFormat(forBus: 0)
            guard fmt.sampleRate > 0, fmt.channelCount > 0 else { throw MicTestError.setupFailed }
            guard let converter = AVAudioConverter(from: fmt, to: pcm16Format) else { throw MicTestError.setupFailed }
            captureSampleRate = fmt.sampleRate
            let store = sampleStore
            inputNode.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [captureSampleRate = self.captureSampleRate] buffer, _ in
                store.appendFloat(buffer: buffer)
                store.appendPCM16(buffer: buffer, inputSampleRate: captureSampleRate, converter: converter, pcm16Format: pcm16Format)
                Self.updateLiveLevel(buffer)
            }
            try engine.start()
            systemTap = engine
        }
    }

    // Same perceptual (sqrt) curve DictationEngine uses for its equalizer, so the mic
    // test's bars feel consistent with the real dictation pill. Runs on the audio
    // capture thread — only touches the lock-protected holder, nothing @MainActor.
    nonisolated private static func updateLiveLevel(_ buffer: AVAudioPCMBuffer) {
        guard let ptr = buffer.floatChannelData?.pointee else { return }
        let frameCount = Int(buffer.frameLength)
        var peak: Float = 0
        for i in 0..<frameCount {
            let a = abs(ptr[i])
            if a > peak { peak = a }
        }
        let perceptual = min(1, sqrt(peak) * 1.6)
        testLevelHolder.update(perceptual)
    }

    private func teardownCapture() {
        deviceCapture?.stop()
        deviceCapture = nil
        systemTap?.inputNode.removeTap(onBus: 0)
        systemTap?.stop()
        systemTap = nil
    }

    enum MicTestError: LocalizedError {
        case setupFailed
        var errorDescription: String? { "Zariadenie nie je dostupné." }
    }

    // MARK: - DSP analysis

    private static func analyzeDBFS(peak: Float, rms: Float) -> (peakDBFS: Double, rmsDBFS: Double) {
        (20 * log10(Double(max(peak, 1e-6))), 20 * log10(Double(max(rms, 1e-6))))
    }

    private static func analyzeDSP(_ samples: [Float], sampleRate: Double) -> (peakDBFS: Double, rmsDBFS: Double, clippingPercent: Double, snrDB: Double?) {
        guard !samples.isEmpty else { return (-100, -100, 0, nil) }
        var peak: Float = 0
        var sumSquares: Float = 0
        var clipped = 0
        for s in samples {
            let a = abs(s)
            if a > peak { peak = a }
            sumSquares += s * s
            if a >= 0.999 { clipped += 1 }
        }
        let rms = sqrt(sumSquares / Float(samples.count))
        let (peakDBFS, rmsDBFS) = analyzeDBFS(peak: peak, rms: rms)
        let clippingPercent = Double(clipped) / Double(samples.count) * 100

        // Noise-floor/SNR estimate: RMS per ~50ms frame, quietest 20% ≈ noise floor,
        // loudest 20% ≈ voice peak. No VAD model needed — just a level-distribution split.
        let frameLen = max(1, Int(sampleRate * 0.05))
        guard samples.count >= frameLen * 5 else { return (peakDBFS, rmsDBFS, clippingPercent, nil) }
        var frameRMS: [Float] = []
        var i = 0
        while i + frameLen <= samples.count {
            var sq: Float = 0
            for j in i..<(i + frameLen) { sq += samples[j] * samples[j] }
            frameRMS.append(sqrt(sq / Float(frameLen)))
            i += frameLen
        }
        frameRMS.sort()
        let bucket = max(1, frameRMS.count / 5)
        let noiseFloor = frameRMS.prefix(bucket).reduce(0, +) / Float(bucket)
        let voicePeak  = frameRMS.suffix(bucket).reduce(0, +) / Float(bucket)
        let snrDB = 20 * log10(Double(max(voicePeak, 1e-6)) / Double(max(noiseFloor, 1e-6)))
        return (peakDBFS, rmsDBFS, clippingPercent, snrDB)
    }

    // MARK: - Transcription (reuses the same REST endpoint as batch dictation)

    private static func transcribe(pcm16: Data, apiKey: String) async -> String? {
        let wav = wavData(pcm16: pcm16, sampleRate: 24_000, channels: 1)
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func addField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        addField("model", "gpt-4o-mini-transcribe")
        addField("language", "sk")
        addField("response_format", "json")
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else {
                AppLogger.log("[MicTestEngine] transcribe failed: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "?")")
                return nil
            }
            return text
        } catch {
            AppLogger.log("[MicTestEngine] transcribe network error: \(error)")
            return nil
        }
    }

    private static func wavData(pcm16: Data, sampleRate: UInt32, channels: UInt16) -> Data {
        let byteRate   = sampleRate * UInt32(channels) * 2
        let blockAlign = channels * 2
        let dataSize   = UInt32(pcm16.count)
        var header = Data()
        func u32(_ v: UInt32) { header.append(Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])) }
        func u16(_ v: UInt16) { header.append(Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff)])) }
        header.append("RIFF".data(using: .ascii)!); u32(36 + dataSize)
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!); u32(16)
        u16(1); u16(channels); u32(sampleRate); u32(byteRate); u16(blockAlign); u16(16)
        header.append("data".data(using: .ascii)!); u32(dataSize)
        return header + pcm16
    }

    // MARK: - Word-level accuracy vs reference sentence

    // Normalizer + edit distance live in DictationQualityEngine — same job, one copy.
    private static func wordMatchPercent(reference: String, transcript: String) -> Double {
        let ref = DictationQualityEngine.normalizeWords(reference)
        let hyp = DictationQualityEngine.normalizeWords(transcript)
        guard !ref.isEmpty else { return 0 }
        let distance = DictationQualityEngine.wordLevenshtein(ref, hyp)
        return max(0, 1 - Double(distance) / Double(ref.count)) * 100
    }

    // MARK: - Verdict

    private static func buildVerdict(peakDBFS: Double, clippingPercent: Double, snrDB: Double?,
                                      matchPercent: Double?, hasTranscript: Bool) -> (Verdict, [String]) {
        var suggestions: [String] = []
        var verdict: Verdict = .excellent

        if clippingPercent > 0.5 {
            suggestions.append("Zvuk je skreslený (clipping) — zníž vstupnú hlasitosť mikrofónu v Nastaveniach zvuku macOS.")
            verdict = max(verdict, .poor)
        }
        if peakDBFS < -35 {
            suggestions.append("Mikrofón je veľmi potichu — priblíž sa k nemu alebo zvýš vstupnú hlasitosť.")
            verdict = max(verdict, .poor)
        } else if peakDBFS < -25 {
            suggestions.append("Hlasitosť je nižšia, ako by mala byť — skús hovoriť bližšie k mikrofónu.")
            verdict = max(verdict, .marginal)
        }
        if let snr = snrDB {
            if snr < 15 {
                suggestions.append("V pozadí je výrazný šum, ktorý sťažuje rozpoznávanie — skús tichšie prostredie.")
                verdict = max(verdict, .poor)
            } else if snr < 25 {
                suggestions.append("V pozadí je badateľný šum — ak je to možné, over tichšie prostredie.")
                verdict = max(verdict, .marginal)
            }
        }
        if let match = matchPercent {
            if match < 70 {
                suggestions.append("Prepis sa výrazne líšil od textu, ktorý si čítal — skús hovoriť pomalšie a zreteľnejšie, alebo over mikrofón.")
                verdict = max(verdict, .poor)
            } else if match < 90 {
                suggestions.append("Prepis sa mierne líšil od pôvodného textu — mikrofón je použiteľný, no nie ideálny.")
                verdict = max(verdict, .marginal)
            }
        } else if !hasTranscript {
            suggestions.append("Bez OpenAI API kľúča vieme otestovať len hlasitosť, nie presnosť prepisu.")
        }
        if suggestions.isEmpty {
            suggestions.append("Mikrofón funguje výborne — hlasitosť aj zrozumiteľnosť sú v poriadku.")
        }
        return (verdict, suggestions)
    }
}

/// Thread-safe holder for the mic test's live level meter — same lock-holder pattern
/// as DictationEngine's AudioLevelHolder (capture-thread writes, MainActor loop reads).
/// A separate instance because MicTestEngine records through its own independent
/// pipeline, not through DictationEngine.
private final class TestLevelHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Float = 0
    func update(_ v: Float) { lock.lock(); value = v; lock.unlock() }
    var current: Float { lock.lock(); defer { lock.unlock() }; return value }
}
private let testLevelHolder = TestLevelHolder()

/// Thread-safe accumulator for the mic test's raw audio — same lock-holder pattern
/// as DictationEngine's ChunkCounter/BatchAudioBuffer. Stores both native-format
/// Float32 samples (for local DSP analysis) and converted PCM16 (for the upload).
private final class MicTestSampleStore: @unchecked Sendable {
    private let lock = NSLock()
    private var floats: [Float] = []
    private var pcm16 = Data()

    func reset() {
        lock.lock(); floats.removeAll(); pcm16 = Data(); lock.unlock()
    }

    func appendFloat(buffer: AVAudioPCMBuffer) {
        guard let ptr = buffer.floatChannelData?.pointee else { return }
        let frameCount = Int(buffer.frameLength)
        lock.lock()
        floats.append(contentsOf: UnsafeBufferPointer(start: ptr, count: frameCount))
        lock.unlock()
    }

    func appendPCM16(buffer: AVAudioPCMBuffer, inputSampleRate: Double, converter: AVAudioConverter, pcm16Format: AVAudioFormat) {
        let ratio = 24_000.0 / inputSampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: pcm16Format, frameCapacity: capacity) else { return }
        var consumed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            guard !consumed else { status.pointee = .noDataNow; return nil }
            status.pointee = .haveData
            consumed = true
            return buffer
        }
        guard err == nil, out.frameLength > 0, let ptr = out.int16ChannelData?.pointee else { return }
        let data = Data(bytes: ptr, count: Int(out.frameLength) * 2)
        lock.lock(); pcm16.append(data); lock.unlock()
    }

    func floatSamples() -> [Float] {
        lock.lock(); defer { lock.unlock() }; return floats
    }

    func pcm16Data() -> Data {
        lock.lock(); defer { lock.unlock() }; return pcm16
    }
}
