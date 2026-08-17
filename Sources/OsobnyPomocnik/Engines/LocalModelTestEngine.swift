import AVFoundation
import Observation

/// test/local-whisper-sk ONLY — see CLAUDE.md. Records a short sample and transcribes it
/// through BOTH the existing cloud path (gpt-transcribe) and the local WhisperKit model,
/// side by side, so accuracy can be judged directly instead of guessed at. Mirrors
/// MicTestEngine's standalone recording pipeline — deliberately not touching
/// DictationEngine's session state machine, since this is a throwaway comparison tool.
@Observable
@MainActor
final class LocalModelTestEngine {
    static let shared = LocalModelTestEngine()

    enum Phase: Equatable {
        case idle
        case recording(secondsLeft: Int)
        case transcribing
    }

    struct RunResult: Identifiable {
        let id = UUID()
        var date = Date()
        var reference: String = ""
        var cloudText: String = ""
        var cloudSeconds: Double = 0
        var cloudMatchPercent: Double?
        var localText: String = ""
        var localSeconds: Double = 0
        var localMatchPercent: Double?
        var localError: String?
    }

    private(set) var phase: Phase = .idle
    private(set) var results: [RunResult] = []  // newest first
    private(set) var liveLevel: Float = 0

    private var deviceCapture: DeviceCapture?
    private var systemTap: AVAudioEngine?
    private var sampleStore = MicTestSampleStoreCompat()
    private var testTask: Task<Void, Never>?
    private var levelPollTask: Task<Void, Never>?

    private init() {}

    func startRecording(maxSeconds: Int = 20) {
        guard phase == .idle else { return }
        sampleStore.reset()
        testTask = Task { await runRecording(maxSeconds: maxSeconds) }
    }

    /// Stops early — the countdown is a ceiling, not a fixed duration, since test
    /// sentences vary a lot in length.
    func stopRecording() {
        testTask?.cancel()
    }

    private func runRecording(maxSeconds: Int) async {
        do {
            try setupCapture()
        } catch {
            AppLogger.log("[LocalModelTestEngine] ⚠️ capture setup failed: \(error)")
            phase = .idle
            return
        }
        levelPollTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                self.liveLevel = testLocalLevelHolder.current
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        for remaining in stride(from: maxSeconds, through: 1, by: -1) {
            if Task.isCancelled { break }
            phase = .recording(secondsLeft: remaining)
            try? await Task.sleep(for: .seconds(1))
        }
        levelPollTask?.cancel()
        liveLevel = 0
        teardownCapture()
        if sampleStore.pcm16Data().isEmpty { phase = .idle; return }

        phase = .transcribing
        await runComparison()
        phase = .idle
    }

    private func runComparison() async {
        let pcm16 = sampleStore.pcm16Data()
        let wav = Self.wavData(pcm16: pcm16, sampleRate: 24_000, channels: 1)
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("local-model-test-\(UUID().uuidString).wav")
        try? wav.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        var run = RunResult()

        async let cloud = Self.transcribeCloud(pcm16: pcm16)
        async let local = Self.transcribeLocal(wavURL: tmpURL)

        let (cloudOutcome, localOutcome) = await (cloud, local)
        run.cloudText = cloudOutcome.text
        run.cloudSeconds = cloudOutcome.seconds
        switch localOutcome {
        case .success(let outcome):
            run.localText = outcome.text
            run.localSeconds = outcome.seconds
        case .failure(let error):
            run.localError = error.localizedDescription
        }
        results.insert(run, at: 0)
    }

    /// Called from the UI after the user types in what they actually said, so both
    /// transcripts can be scored against the same ground truth.
    func setReference(_ text: String, for id: UUID) {
        guard let i = results.firstIndex(where: { $0.id == id }) else { return }
        results[i].reference = text
        if !text.isEmpty {
            results[i].cloudMatchPercent = Self.wordMatchPercent(reference: text, transcript: results[i].cloudText)
            results[i].localMatchPercent = Self.wordMatchPercent(reference: text, transcript: results[i].localText)
        }
    }

    func clearResults() { results = [] }

    // MARK: - Capture (copy of MicTestEngine's device/system-default split)

    private func setupCapture() throws {
        let pcm16Format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!

        if let uid = DictationEngine.shared.resolvedInputDeviceUID(),
           let device = AudioDeviceManager.inputDevices().first(where: { $0.uid == uid }) {
            guard let capture = DeviceCapture.make(deviceID: device.id) else { throw LocalTestError.setupFailed }
            guard let converter = AVAudioConverter(from: capture.format, to: pcm16Format) else { throw LocalTestError.setupFailed }
            let store = sampleStore
            let inputSampleRate = capture.format.sampleRate
            capture.onBuffer = { buffer in
                store.appendPCM16(buffer: buffer, inputSampleRate: inputSampleRate, converter: converter, pcm16Format: pcm16Format)
                Self.updateLiveLevel(buffer)
            }
            guard capture.start() else { throw LocalTestError.setupFailed }
            deviceCapture = capture
        } else {
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let fmt = inputNode.outputFormat(forBus: 0)
            guard fmt.sampleRate > 0, fmt.channelCount > 0 else { throw LocalTestError.setupFailed }
            guard let converter = AVAudioConverter(from: fmt, to: pcm16Format) else { throw LocalTestError.setupFailed }
            let store = sampleStore
            let inputSampleRate = fmt.sampleRate
            inputNode.installTap(onBus: 0, bufferSize: 2048, format: fmt) { buffer, _ in
                store.appendPCM16(buffer: buffer, inputSampleRate: inputSampleRate, converter: converter, pcm16Format: pcm16Format)
                Self.updateLiveLevel(buffer)
            }
            try engine.start()
            systemTap = engine
        }
    }

    nonisolated private static func updateLiveLevel(_ buffer: AVAudioPCMBuffer) {
        guard let ptr = buffer.floatChannelData?.pointee else { return }
        let frameCount = Int(buffer.frameLength)
        var peak: Float = 0
        for i in 0..<frameCount {
            let a = abs(ptr[i])
            if a > peak { peak = a }
        }
        testLocalLevelHolder.update(min(1, sqrt(peak) * 1.6))
    }

    private func teardownCapture() {
        deviceCapture?.stop()
        deviceCapture = nil
        systemTap?.inputNode.removeTap(onBus: 0)
        systemTap?.stop()
        systemTap = nil
    }

    enum LocalTestError: LocalizedError {
        case setupFailed
        var errorDescription: String? { "Zariadenie nie je dostupné." }
    }

    // MARK: - Transcription paths

    private static func transcribeCloud(pcm16: Data) async -> (text: String, seconds: Double) {
        let t0 = Date()
        guard DictationEngine.shared.hasOpenAIKey, !pcm16.isEmpty else { return ("(bez API kľúča)", 0) }
        let wav = wavData(pcm16: pcm16, sampleRate: 24_000, channels: 1)
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(DictationEngine.shared.openAIKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func addField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        addField("model", "gpt-transcribe")
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
                return ("(cloud chyba)", Date().timeIntervalSince(t0))
            }
            return (text, Date().timeIntervalSince(t0))
        } catch {
            return ("(sieťová chyba: \(error.localizedDescription))", Date().timeIntervalSince(t0))
        }
    }

    private static func transcribeLocal(wavURL: URL) async -> Result<LocalWhisperEngine.TranscribeOutcome, Error> {
        do {
            let outcome = try await LocalWhisperEngine.shared.transcribe(wavURL: wavURL)
            return .success(outcome)
        } catch {
            return .failure(error)
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

    private static func wordMatchPercent(reference: String, transcript: String) -> Double {
        let ref = DictationQualityEngine.normalizeWords(reference)
        let hyp = DictationQualityEngine.normalizeWords(transcript)
        guard !ref.isEmpty else { return 0 }
        let distance = DictationQualityEngine.wordLevenshtein(ref, hyp)
        return max(0, 1 - Double(distance) / Double(ref.count)) * 100
    }
}

private final class TestLocalLevelHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Float = 0
    func update(_ v: Float) { lock.lock(); value = v; lock.unlock() }
    var current: Float { lock.lock(); defer { lock.unlock() }; return value }
}
private let testLocalLevelHolder = TestLocalLevelHolder()

/// Same PCM16-accumulator shape as MicTestEngine's private MicTestSampleStore — duplicated
/// rather than shared since that one is private to its file and this is a throwaway test
/// tool scoped to this branch only (see CLAUDE.md).
private final class MicTestSampleStoreCompat: @unchecked Sendable {
    private let lock = NSLock()
    private var pcm16 = Data()

    func reset() { lock.lock(); pcm16 = Data(); lock.unlock() }

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

    func pcm16Data() -> Data {
        lock.lock(); defer { lock.unlock() }; return pcm16
    }
}
