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
    private var captureFormat: AVAudioFormat?
    private let sampleStore = MicTestSampleStore()
    private var testTask: Task<Void, Never>?
    private var levelPollTask: Task<Void, Never>?

    private init() {}

    // ponytail: 9s (was 6s) — the reference sentences run ~5-7s read at a natural pace,
    // and the old duration left no margin, cutting the tail off mid-sentence and tanking
    // the transcript-match score. The prep countdown adds further reaction-time margin.
    func startTest(durationSeconds: Int = 9, prepSeconds: Int = 2) {
        guard phase == .idle || isTerminal(phase), !isMonitoring else { return }
        referenceText = Self.referenceSentences.randomElement() ?? Self.referenceSentences[0]
        result = nil
        sampleStore.reset()
        sampleStore.setCollecting(true)
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
            // levelPollTask is unstructured, so cancelling this task doesn't reach it —
            // bail out through the same cleanup rather than leaving a 20 Hz MainActor loop alive.
            if Task.isCancelled { levelPollTask?.cancel(); liveLevel = 0; teardownCapture(); return }
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

    // MARK: - Live monitor ("Počúvať sa")

    enum ReplayState: Equatable { case idle, recording(secondsLeft: Int), playing }

    private(set) var isMonitoring = false
    private(set) var hearSelf = false
    /// Output is Bluetooth — the UI warns that the delay is the headphones', not a fault.
    private(set) var hearSelfDelayed = false
    /// Peak-hold in dBFS: jumps up instantly, falls ~20 dB/s so a word's peak stays readable.
    private(set) var livePeakDBFS: Double = -100
    /// Lit for 1.5 s after the last flat-topped (clipped) stretch.
    private(set) var isClipping = false
    private(set) var replay: ReplayState = .idle
    private(set) var monitorError: String?
    /// The mic the test and monitor record from (priority list, else system default).
    private(set) var device: AudioInputDevice?
    /// 0…1; nil = the device has no software volume (iPhone mic).
    private(set) var inputVolume: Float?

    private var monitorOutput: AVAudioEngine?
    private var pendingOutput: AVAudioEngine?
    private var replayPlayer: AVAudioPlayer?
    private var replayTask: Task<Void, Never>?
    private var lastClip = Date.distantPast

    func refreshDevice() {
        let devices = AudioDeviceManager.inputDevices()
        if let uid = DictationEngine.shared.resolvedInputDeviceUID(devices: devices) {
            device = devices.first { $0.uid == uid }
        } else {
            device = AudioDeviceManager.defaultInputDevice(in: devices)
        }
        inputVolume = device.flatMap { AudioDeviceManager.inputVolume($0.id) }
    }

    /// Writes the device's own (system-wide) input volume — same control as macOS Sound settings.
    func setInputVolume(_ v: Float) {
        guard let device else { return }
        AudioDeviceManager.setInputVolume(device.id, v)
        inputVolume = v
    }

    func startMonitor() {
        guard !isMonitoring, phase == .idle || isTerminal(phase) else { return }
        refreshDevice()
        monitorError = nil
        sampleStore.reset()
        sampleStore.setCollecting(false) // metering only; recordAndReplay switches it on
        do { try setupCapture() } catch {
            monitorError = "Nepodarilo sa spustiť mikrofón: \(error.localizedDescription)"
            return
        }
        isMonitoring = true
        AppLogger.log("[MicTest] počúvanie — '\(device?.name ?? "?")' hlasitosť=\(inputVolume.map { "\(Int($0 * 100))%" } ?? "–")")
        _ = testLevelHolder.takePeak()
        levelPollTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                self.liveLevel = testLevelHolder.current
                let (peak, clipped) = testLevelHolder.takePeak()
                self.livePeakDBFS = max(20 * log10(Double(max(peak, 1e-6))), self.livePeakDBFS - 1)
                if clipped { self.lastClip = Date() }
                self.isClipping = -self.lastClip.timeIntervalSinceNow < 1.5
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func stopMonitor() {
        guard isMonitoring else { return }
        replayTask?.cancel(); replayTask = nil
        replayPlayer?.stop(); replayPlayer = nil
        replay = .idle
        setHearSelf(false)
        levelPollTask?.cancel()
        teardownCapture()
        sampleStore.setCollecting(true)
        liveLevel = 0; livePeakDBFS = -100; isClipping = false
        isMonitoring = false
    }

    /// Plays the mic straight back into the headphones. Refused on the built-in speakers,
    /// where the mic would pick its own output up and howl.
    func setHearSelf(_ on: Bool) {
        monitorSink.set(nil)
        monitorOutput?.stop(); monitorOutput = nil
        pendingOutput = nil
        hearSelf = false
        guard on, isMonitoring, let fmt = captureFormat else { return }
        if AudioDeviceManager.outputIsBuiltInSpeaker() {
            monitorError = "Počúvať sa dá len so slúchadlami — cez reproduktory Macu by mikrofón pískal."
            return
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        // Standard mono float, never the capture format as-is: the SoloCast delivers interleaved
        // stereo, which AVAudioPlayerNode rejects with an Obj-C exception — uncatchable in Swift,
        // swallowed by AppKit mid-click, and the settings window stopped taking clicks after it.
        guard let playFormat = AVAudioFormat(standardFormatWithSampleRate: fmt.sampleRate, channels: 1) else { return }
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        hearSelf = true
        monitorError = nil
        // Started off the main thread: opening a Bluetooth output can take seconds, and doing it
        // here froze the whole settings window meanwhile.
        pendingOutput = engine
        hearSelfDelayed = AudioDeviceManager.outputIsBluetooth()
        let box = EngineBox(engine: engine, player: player)
        DispatchQueue.global(qos: .userInitiated).async {
            let error: Error?
            do { try box.engine.start(); box.player.play(); error = nil } catch let e { error = e }
            DispatchQueue.main.async {
                let me = MicTestEngine.shared
                // Stale start: turned off, or off-and-on again, while this one was opening.
                guard me.pendingOutput === box.engine, me.hearSelf, me.isMonitoring else { box.engine.stop(); return }
                me.pendingOutput = nil
                if let error {
                    me.hearSelf = false
                    me.monitorError = "Nepodarilo sa spustiť prehrávanie: \(error.localizedDescription)"
                    return
                }
                me.monitorOutput = box.engine
                monitorSink.set(box.player, format: playFormat)
                AppLogger.log("[MicTest] počuť sa — zapnuté")
            }
        }
    }

    /// Records a few seconds and plays back exactly the 24 kHz mono PCM16 that dictation
    /// uploads — i.e. how the transcription model actually hears you.
    func recordAndReplay(seconds: Int = 5) {
        guard isMonitoring, replay == .idle else { return }
        replayTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let wasHearing = self.hearSelf
            self.setHearSelf(false) // hear the recording, not yourself on top of it
            self.sampleStore.reset()
            self.sampleStore.setCollecting(true)
            for r in stride(from: seconds, through: 1, by: -1) {
                self.replay = .recording(secondsLeft: r)
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            self.sampleStore.setCollecting(false)
            let wav = Self.wavData(pcm16: self.sampleStore.pcm16Data(), sampleRate: 24_000, channels: 1)
            guard let player = try? AVAudioPlayer(data: wav) else { self.replay = .idle; return }
            self.replayPlayer = player
            self.replay = .playing
            player.play()
            try? await Task.sleep(for: .seconds(player.duration + 0.2))
            if Task.isCancelled { return }
            self.replayPlayer = nil
            self.replay = .idle
            if wasHearing { self.setHearSelf(true) }
        }
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
            captureFormat = capture.format
            let store = sampleStore
            capture.onBuffer = { [captureSampleRate = self.captureSampleRate] buffer in
                monitorSink.push(buffer)
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
            captureFormat = fmt
            let store = sampleStore
            inputNode.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [captureSampleRate = self.captureSampleRate] buffer, _ in
                monitorSink.push(buffer)
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
        var run = 0, clipped = false
        for i in 0..<frameCount {
            let a = abs(ptr[i])
            if a > peak { peak = a }
            run = a >= clipLevel ? run + 1 : 0
            if run >= minClipRun { clipped = true }
        }
        let perceptual = min(1, sqrt(peak) * 1.6)
        testLevelHolder.update(perceptual, peak: peak, clipped: clipped)
    }

    // Same rule as DictationQualityMonitor: clipping = several samples in a row pinned at the
    // ceiling (a flat-topped wave), not one loud transient. The test used to count single
    // samples, so it and the mid-dictation notice could disagree about the same mic.
    nonisolated static let clipLevel: Float = 0.999
    nonisolated static let minClipRun = 3

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
        var clipped = 0, run = 0
        for s in samples {
            let a = abs(s)
            if a > peak { peak = a }
            sumSquares += s * s
            run = a >= clipLevel ? run + 1 : 0
            if run >= minClipRun { clipped += run == minClipRun ? minClipRun : 1 }
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
            suggestions.append("Zvuk je skreslený (clipping) — zníž hlasitosť mikrofónu posuvníkom v režime „Počúvať sa“ nižšie.")
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
    private var peak: Float = 0
    private var clipped = false
    func update(_ v: Float, peak p: Float = 0, clipped c: Bool = false) {
        lock.lock(); value = v; peak = max(peak, p); clipped = clipped || c; lock.unlock()
    }
    var current: Float { lock.lock(); defer { lock.unlock() }; return value }
    /// Loudest sample and whether it clipped since the last call — the capture thread
    /// delivers several buffers per UI poll, and a clip in any of them must not be lost.
    func takePeak() -> (peak: Float, clipped: Bool) {
        lock.lock(); defer { lock.unlock() }
        let r = (peak, clipped); peak = 0; clipped = false; return r
    }
}

/// Routes captured buffers to the "hear yourself" player — set only while that's on.
/// Called on the capture thread. The queue is capped by duration, not buffer count: a USB mic
/// delivers ~10 ms buffers while a Bluetooth output pulls 40–90 ms per render, so the old cap
/// of 6 buffers (~60 ms) starved it — the playback kept dropping out ("zasekne sa").
/// 0.3 s still keeps latency from creeping up when the output clock runs a bit slow.
private final class MonitorSink: @unchecked Sendable {
    private let lock = NSLock()
    private var player: AVAudioPlayerNode?
    private var playerFormat: AVAudioFormat?
    private var queuedFrames: AVAudioFrameCount = 0
    func set(_ p: AVAudioPlayerNode?, format: AVAudioFormat? = nil) {
        lock.lock(); player = p; playerFormat = format; queuedFrames = 0; lock.unlock()
    }
    func push(_ buffer: AVAudioPCMBuffer) {
        let frames = buffer.frameLength
        lock.lock()
        guard let player, let format = playerFormat, Double(queuedFrames) < format.sampleRate * 0.3,
              let src = buffer.floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let dst = copy.floatChannelData?[0]
        else { lock.unlock(); return }
        queuedFrames += frames
        lock.unlock()
        // First channel only, read with the buffer's stride: works for interleaved and
        // non-interleaved capture alike, and the player always gets the one format it accepts.
        let stride = buffer.stride
        for i in 0..<Int(frames) { dst[i] = src[0][i * stride] }
        copy.frameLength = frames
        player.scheduleBuffer(copy) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.queuedFrames -= min(frames, self.queuedFrames); self.lock.unlock()
        }
    }
}
private let monitorSink = MonitorSink()

private struct EngineBox: @unchecked Sendable {
    let engine: AVAudioEngine
    let player: AVAudioPlayerNode
}
private let testLevelHolder = TestLevelHolder()

/// Thread-safe accumulator for the mic test's raw audio — same lock-holder pattern
/// as DictationEngine's ChunkCounter/BatchAudioBuffer. Stores both native-format
/// Float32 samples (for local DSP analysis) and converted PCM16 (for the upload).
private final class MicTestSampleStore: @unchecked Sendable {
    private let lock = NSLock()
    private var floats: [Float] = []
    private var pcm16 = Data()
    private var collecting = true

    func setCollecting(_ on: Bool) { lock.lock(); collecting = on; lock.unlock() }

    func reset() {
        lock.lock(); floats.removeAll(); pcm16 = Data(); lock.unlock()
    }

    func appendFloat(buffer: AVAudioPCMBuffer) {
        guard let ptr = buffer.floatChannelData?.pointee else { return }
        let frameCount = Int(buffer.frameLength)
        lock.lock()
        guard collecting else { lock.unlock(); return }
        floats.append(contentsOf: UnsafeBufferPointer(start: ptr, count: frameCount))
        lock.unlock()
    }

    func appendPCM16(buffer: AVAudioPCMBuffer, inputSampleRate: Double, converter: AVAudioConverter, pcm16Format: AVAudioFormat) {
        lock.lock(); let on = collecting; lock.unlock()
        guard on else { return }
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
