@preconcurrency import AVFoundation
import AppKit
import CoreGraphics
import Observation

// MARK: - Serial WebSocket sender
//
// URLSessionWebSocketTask.send() is NOT safe to call concurrently — firing one
// unstructured Task per audio chunk (as this code originally did) causes
// concurrent sends that silently lose/corrupt data. Confirmed in testing: 35
// chunks converted successfully locally, 0 bytes received server-side.
// This queue guarantees strict FIFO, one-at-a-time delivery. `enqueue` is a
// cheap synchronous lock+append safe to call from the realtime audio thread —
// no per-chunk Task creation, so call order is preserved exactly.
private final class AudioSendQueue: @unchecked Sendable {
    // ponytail: two separate queues so audio chunks (Data) don't block control msgs (String).
    // Audio chunks are stored as raw Data — base64 encoding happens here in drainLoop,
    // NOT on the realtime CoreAudio thread, reducing audio thread allocation pressure.
    private enum Item { case control(String); case audio(Data) }
    private let lock = NSLock()
    private var pending: [Item] = []
    private var task: URLSessionWebSocketTask?
    private var isDraining = false
    private var hasReportedFailure = false
    private var droppedItems = 0

    /// Fired at most once per `configure(task:)` cycle, when a chunk exhausts its
    /// retries — signals the engine that this WS task looks dead and should be
    /// replaced. Passes the failing task so the engine can ignore a stale signal
    /// after it has already reconnected.
    var onTaskAppearsDead: (@Sendable (URLSessionWebSocketTask) -> Void)?

    func configure(task: URLSessionWebSocketTask) {
        lock.lock()
        self.task = task
        pending = []
        isDraining = false
        hasReportedFailure = false
        lock.unlock()
    }

    /// Clears the dropped-chunk counter for a brand new recording session
    /// (kept across reconnects within the same session so stopAndTranscribe
    /// can tell whether anything was actually lost).
    func resetStats() {
        lock.lock()
        droppedItems = 0
        lock.unlock()
    }

    var droppedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return droppedItems
    }

    /// Enqueue a control message (session config, commit, etc.) — sent as-is.
    func enqueue(_ message: String) { append(.control(message)) }

    /// Enqueue a raw PCM16 audio chunk — base64-wrapped into append JSON here, not on the audio thread.
    func enqueueAudio(_ data: Data) { append(.audio(data)) }

    private func append(_ item: Item) {
        lock.lock()
        pending.append(item)
        let shouldStartDraining = !isDraining
        if shouldStartDraining { isDraining = true }
        lock.unlock()

        if shouldStartDraining {
            Task { await self.drainLoop() }
        }
    }

    private func drainLoop() async {
        while true {
            lock.lock()
            guard !pending.isEmpty else {
                isDraining = false
                lock.unlock()
                break
            }
            let item = pending.removeFirst()
            lock.unlock()

            let msg: String
            switch item {
            case .control(let s): msg = s
            case .audio(let d):
                let b64 = d.base64EncodedString()
                msg = #"{"type":"input_audio_buffer.append","audio":"\#(b64)"}"#
            }

            // Retry on the current task a few times — covers brief Wi-Fi blips where the
            // task itself is still alive. A genuinely dead task fails all 3 near-instantly.
            var delivered = false
            var lastFailedTask: URLSessionWebSocketTask?
            for attempt in 0..<3 {
                lock.lock(); let currentTask = task; lock.unlock()
                guard let currentTask else { break }
                do {
                    try await currentTask.send(.string(msg))
                    delivered = true
                    break
                } catch {
                    AppLogger.log("[AudioSendQueue] ⚠️ send() failed (attempt \(attempt + 1)/3, msg len \(msg.count)): \(error)")
                    lastFailedTask = currentTask
                    if attempt < 2 { try? await Task.sleep(for: .milliseconds(150)) }
                }
            }

            if !delivered {
                lock.lock()
                droppedItems += 1
                let shouldReport = !hasReportedFailure
                if shouldReport { hasReportedFailure = true }
                lock.unlock()
                if shouldReport, let deadTask = lastFailedTask {
                    onTaskAppearsDead?(deadTask)
                }
            }
        }
    }

    /// Waits until every enqueued message (including one just enqueued, like commit)
    /// has actually been sent. Polling is fine here — this is a short, rare wait.
    func flush() async {
        for _ in 0..<250 { // ~5s safety cap
            lock.lock()
            let empty = pending.isEmpty && !isDraining
            lock.unlock()
            if empty { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

// MARK: - Engine

@Observable
@MainActor
final class DictationEngine {
    static let shared = DictationEngine()

    private(set) var isRecording    = false
    private(set) var isTranscribing = false  // brief "inserting" state after stop
    private(set) var isRewriting    = false  // Smart diktovanie: rewriting with screen context
    private(set) var liveText       = ""     // live transcript shown in indicator
    private(set) var connectionError: String? { didSet { if connectionError != oldValue { AppLogger.log("[DictationEngine] ⚡ connectionError=\(connectionError ?? "nil") | isRecording=\(isRecording) session=#\(sessionID)") } } }
    private(set) var audioLevel: Float = 0   // 0...1, polled from the mic for the UI equalizer

    // False from the moment recording starts until the FIRST real audio chunk has
    // actually flowed. Bluetooth/Continuity mics can take a second or more to
    // finish their handshake — this lets the indicator show "connecting" instead
    // of implying the mic is already listening.
    private(set) var isMicReady = false
    // True only while an actual Bluetooth link is negotiating and hasn't delivered real
    // audio yet (buffers are all zeros). UI shows "Inicializujem Bluetooth…".
    private(set) var btNegotiating = false
    // Transport traits of the capture device, read once at session start — a wired mic
    // must not be treated (or labelled) as a link that needs warming up.
    private var captureNeedsWarmup = false
    private var captureIsBluetooth = false
    // AVAudioEngine path only — restart guard for ConfigChange / tap invalidation.
    private var tapRestartCount = 0
    private var tapNeedsReinstall = false
    // Non-nil when using CoreAudio IO proc path (explicit device selection).
    private var deviceCapture: DeviceCapture?

    // Transient, non-error info shown in the indicator (e.g. "saved to memory").
    // Distinct from connectionError so the UI can style it differently.
    private(set) var notice: String?
    /// Sticky notices stay until the user clicks the pill away. Advisory ones (mic-quality
    /// hints raised mid-dictation) auto-hide so they don't sit on top of an active session.
    private(set) var noticeIsSticky = true

    func showNotice(_ msg: String, sticky: Bool = true) {
        noticeIsSticky = sticky
        notice = msg
    }

    // Set at the end of stopAndTranscribe() — false if the mic tap never produced
    // a single usable chunk during the whole recording (mic permission, broken
    // device, etc.), so callers can show a clear "audio didn't work" message
    // instead of silently treating it the same as "nothing was said".
    private(set) var lastRecordingCapturedAudio = true

    private var levelPollTask: Task<Void, Never>?

    // Guards against a duplicate startRecording() call while one is already in
    // flight but hasn't set isRecording=true yet (mic grace-period wait can take
    // a second or more for Bluetooth/Continuity devices). Without this, an
    // impatient second hotkey press during that window started a SECOND session
    // that tore down the first — visible in the UI as "ready" flickering back to
    // "connecting".
    private var isStarting = false

    private(set) var totalSecondsRecorded: Int {
        didSet { UserDefaults.standard.set(totalSecondsRecorded, forKey: "whisper.usage.seconds") }
    }

    var openAIKey: String {
        didSet {
            if openAIKey.isEmpty { UserDefaults.standard.removeObject(forKey: "openai.dictation.key") }
            else                 { UserDefaults.standard.set(openAIKey, forKey: "openai.dictation.key") }
        }
    }
    var hasOpenAIKey: Bool { !openAIKey.isEmpty }

    // Latency tradeoff, same five values on both realtime models:
    // "minimal"|"low"|"medium"|"high"|"xhigh"
    var transcriptionDelay: String {
        didSet { UserDefaults.standard.set(transcriptionDelay, forKey: "whisper.delay") }
    }

    enum TranscriptionMode: String { case realtime, batch }

    /// Which backend serves .realtime mode.
    ///
    /// `.live` is OpenAI's dedicated transcription session — no conversational model in the
    /// loop, and it accepts `keywords`/`prompt`/`languages`, which is where the accuracy win
    /// actually comes from (measured: the model swap alone changed almost nothing; adding
    /// keywords turned "resolve input device uid" into "resolvedInputDeviceUID").
    ///
    /// `.legacy` is the original path — the conversational `gpt-realtime-2` with its voice
    /// reply switched off. Kept selectable, not deleted, so a regression in the new session
    /// is one dropdown away from a fix instead of a new build.
    enum RealtimeModel: String, CaseIterable, Sendable {
        case live   = "gpt-live-transcribe"
        case legacy = "gpt-realtime-whisper"

        var socketURL: URL {
            switch self {
            // The transcription session is selected by `intent`, not by `model` — the model
            // goes in session.update instead.
            case .live:   URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
            case .legacy: URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime-2")!
            }
        }

        var label: String {
            switch self {
            case .live:   "gpt-live-transcribe (nový, presnejší)"
            case .legacy: "gpt-realtime-whisper (pôvodný)"
            }
        }
    }

    var realtimeModel: RealtimeModel {
        didSet { UserDefaults.standard.set(realtimeModel.rawValue, forKey: "dictation.realtimeModel") }
    }

    // Always-on keywords for gpt-live-transcribe (one per line), on top of whatever the
    // matched App profile adds — e.g. the user's own name, recurring product/project terms.
    // Same free-text format and parser as AppProfile.keywords (AppProfile.parseKeywords).
    // API caps the combined array at 16384 entries (tested against the live endpoint) —
    // no real user gets near that, so no truncation logic here.
    var defaultKeywords: String {
        didSet { UserDefaults.standard.set(defaultKeywords, forKey: "dictation.defaultKeywords") }
    }

    var transcriptionMode: TranscriptionMode {
        didSet { UserDefaults.standard.set(transcriptionMode.rawValue, forKey: "dictation.mode") }
    }

    // REST /v1/audio/transcriptions model used in .batch mode.
    var batchModel: String {
        didSet { UserDefaults.standard.set(batchModel, forKey: "dictation.batchModel") }
    }
    // gpt-transcribe listed first: OpenAI's newer, more accurate replacement for the
    // gpt-4o-*/whisper-1 family (WER 15.21% -> 8.98% on OpenAI's own benchmark) — see
    // Pricing.swift for the rate and the "not truly live" caveat on all these numbers.
    static let batchModels = ["gpt-transcribe", "gpt-4o-mini-transcribe", "gpt-4o-transcribe", "whisper-1"]

    /// $/minute for whichever mode+model is currently selected — used for the usage cost estimate.
    /// ponytail: applies the CURRENT rate to the whole accumulated counter, not a historical
    /// mix of rates if the user switched modes mid-way. Fine until someone needs split billing.
    /// Delegates to Pricing.usdPerMinute so the per-model rate has one source of truth instead
    /// of drifting between here and the model picker in Nastavenia.
    var costPerMinute: Double { Pricing.usdPerMinute(realtime: transcriptionMode == .realtime, batchModel: batchModel) }

    // Microphone priority order — persistent stableKeys (see AudioInputDevice.stableKey),
    // most preferred first. At recording start we walk the list and use the first one
    // that's currently connected; if none are, or the list is empty, fall back to system default.
    var micPriority: [String] {
        didSet { UserDefaults.standard.set(micPriority, forKey: "dictation.micPriority") }
    }

    /// First priority-list device that's currently connected, or nil (→ system default)
    /// if the list is empty or none of its devices are present right now. Matches by
    /// stableKey (so a USB mic in a different port than last time still resolves) but
    /// returns the live `uid` of that instance, since callers need the actual connected
    /// device to open, not its stable identity.
    func resolvedInputDeviceUID() -> String? {
        guard !micPriority.isEmpty else { return nil }
        let byStableKey = Dictionary(AudioDeviceManager.inputDevices().map { ($0.stableKey, $0) },
                                     uniquingKeysWith: { first, _ in first })
        guard let key = micPriority.first(where: { byStableKey[$0] != nil }) else { return nil }
        return byStableKey[key]?.uid
    }

    /// Same thresholds as MicTestEngine's verdict, minus the transcript-accuracy part —
    /// nil when everything looks fine (we only want to interrupt with a notice on a
    /// real problem, not congratulate a working mic mid-dictation).
    private static func qualityWarning(from s: (peakDBFS: Double, clippingPercent: Double, snrDB: Double?)) -> String? {
        if s.clippingPercent > 0.5 {
            return "⚠️ Zvuk je skreslený — zníž vstupnú hlasitosť mikrofónu v Nastaveniach zvuku."
        }
        if s.peakDBFS < -35 {
            return "⚠️ Mikrofón je veľmi potichu — priblíž sa k nemu alebo zvýš vstupnú hlasitosť."
        }
        if let snr = s.snrDB, snr < 15 {
            return "⚠️ V pozadí je výrazný šum — skús tichšie prostredie."
        }
        return nil
    }

    // Audio
    private let audioEngine = AVAudioEngine()
    private let pcm16Format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true
    )!

    // WebSocket
    private var wsTask:       URLSessionWebSocketTask?
    private var wsURLSession: URLSession?
    private let sendQueue = AudioSendQueue()
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 4

    private var accumulatedText         = ""
    private(set) var recordingStartDate: Date?  // also drives the pill's live elapsed-time counter

    // Live-insert state (realtime mode only)
    var liveInsertEnabled: Bool {
        didSet { UserDefaults.standard.set(liveInsertEnabled, forKey: "dictation.liveInsert") }
    }
    // When true, regular Diktovanie (⇧⌘D) always runs in Smart mode (context capture + rewrite).
    var smartAlwaysOn: Bool {
        didSet { UserDefaults.standard.set(smartAlwaysOn, forKey: "dictation.smartAlwaysOn") }
    }
    var enterAutoStop: Bool {
        didSet { UserDefaults.standard.set(enterAutoStop, forKey: "dictation.enterAutoStop") }
    }
    // Set after stopAndTranscribe when live-insert handled the paste — AppDelegate checks this
    // to skip the normal insertOrRemember call and log correctly.
    private(set) var didLiveInsert = false
    private(set) var liveInsertActive = false  // true once first delta confirms a focused field
    private var liveInsertedCount = 0      // grapheme clusters typed live (= backspace count for correction)
    private(set) var isWaitingForServer = false  // true when >3s without a delta while recording
    private var lastDeltaDate: Date? = nil
    // Resumed when the server sends the final completed transcript after commit
    private var transcriptionContinuation: CheckedContinuation<String, Never>?

    // Target-app context — captured at recording start, consumed at stop. Needed on
    // every dictation for quality tracking; the screenshot only for Smart diktovanie.
    private var isSmartMode        = false
    private var capturedScreenshot: CGImage?
    private var capturedProfile:    AppProfile?
    private var capturedAppName:    String = ""
    private var capturedBundleID:   String = ""
    private var contextCaptureTask: Task<Void, Never>?

    // Profile resolved synchronously at recording start, purely so its keywords can go into
    // the very FIRST session.update. capturedProfile above can't serve here: it's filled by
    // contextCaptureTask, which awaits ScreenCaptureKit and lands long after the socket opens.
    // NSWorkspace.frontmostApplication is a plain synchronous read, so bundleID alone is free —
    // the async capture then only refines the match by window title, for Smart rewrite.
    private var sessionProfile: AppProfile?

    // Bumped on every startRecording(). Stale WS callbacks from an abandoned
    // session (e.g. user pressed the shortcut rapidly start→stop→start) check
    // this before mutating state, so they can't corrupt a newer in-flight session.
    private var sessionID = 0

    // Fires when the system's audio device configuration changes mid-recording
    // (e.g. a routing utility like SoundSource switches the input device, a
    // Bluetooth device connects/disconnects). Without handling this, the tap's
    // format/converter become stale and can corrupt memory. Confirmed crash cause.
    private var configChangeObserver: NSObjectProtocol?

    private init() {
        self.totalSecondsRecorded   = UserDefaults.standard.integer(forKey: "whisper.usage.seconds")
        // Migrate the old single-device pick into a one-item priority list.
        // didSet doesn't fire for assignments inside this initializer, so persist explicitly.
        if let legacyUID = UserDefaults.standard.string(forKey: "dictation.inputDeviceUID") {
            let migrated = [AudioInputDevice.stableKey(forUID: legacyUID)]
            self.micPriority = migrated
            UserDefaults.standard.set(migrated, forKey: "dictation.micPriority")
            UserDefaults.standard.removeObject(forKey: "dictation.inputDeviceUID")
        } else {
            let stored = UserDefaults.standard.stringArray(forKey: "dictation.micPriority") ?? []
            // One-time re-key + de-dupe: entries saved before stableKey existed are raw UIDs,
            // which for a USB mic without a real serial include the port-dependent segment —
            // the same physical device could appear several times, each a permanent "not
            // connected" ghost from whichever port it isn't currently in.
            var seen = Set<String>()
            let migrated = stored.map(AudioInputDevice.stableKey(forUID:)).filter { seen.insert($0).inserted }
            self.micPriority = migrated
            if migrated != stored { UserDefaults.standard.set(migrated, forKey: "dictation.micPriority") }
        }
        self.openAIKey              = UserDefaults.standard.string(forKey: "openai.dictation.key") ?? ""
        self.transcriptionDelay     = UserDefaults.standard.string(forKey: "whisper.delay") ?? "low"
        self.transcriptionMode      = TranscriptionMode(rawValue: UserDefaults.standard.string(forKey: "dictation.mode") ?? "") ?? .realtime
        self.realtimeModel          = RealtimeModel(rawValue: UserDefaults.standard.string(forKey: "dictation.realtimeModel") ?? "") ?? .live
        self.defaultKeywords        = UserDefaults.standard.string(forKey: "dictation.defaultKeywords") ?? ""
        // New default for fresh installs only — existing users keep whatever they already
        // had saved, this doesn't migrate anyone off their current choice.
        self.batchModel             = UserDefaults.standard.string(forKey: "dictation.batchModel") ?? "gpt-transcribe"
        self.liveInsertEnabled      = UserDefaults.standard.object(forKey: "dictation.liveInsert") as? Bool ?? true
        self.enterAutoStop          = UserDefaults.standard.bool(forKey: "dictation.enterAutoStop")
        self.smartAlwaysOn          = UserDefaults.standard.bool(forKey: "dictation.smartAlwaysOn")
    }

    func resetUsageCounter() { totalSecondsRecorded = 0 }

    /// Validates the OpenAI key and checks whether the account has access to the
    /// specific realtime/transcription models this app depends on.
    func testAPIKey() async -> String {
        guard hasOpenAIKey else { return "❌ Žiadny API kľúč nie je nastavený." }

        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        req.setValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return "❌ Neplatná odpoveď servera." }

            guard http.statusCode == 200 else {
                let msg = String(data: data, encoding: .utf8) ?? "?"
                AppLogger.log("[DictationEngine] API key test FAILED [\(http.statusCode)]: \(msg.prefix(300))")
                return "❌ Chyba \(http.statusCode): \(msg.prefix(200))"
            }

            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let models = json["data"] as? [[String: Any]]
            else { return "✅ Kľúč je platný (zoznam modelov sa nepodarilo prečítať)." }

            let ids = Set(models.compactMap { $0["id"] as? String })
            // Only the models the current settings actually use — reporting a missing
            // gpt-realtime-2 to someone on gpt-live-transcribe is just noise.
            let needed = transcriptionMode == .realtime
                ? (realtimeModel == .live ? [RealtimeModel.live.rawValue]
                                          : ["gpt-realtime-2", RealtimeModel.legacy.rawValue])
                : [batchModel]
            let missing = needed.filter { !ids.contains($0) }
            AppLogger.log("[DictationEngine] API key OK. Required: \(needed.joined(separator: ", ")) — missing: \(missing.isEmpty ? "none" : missing.joined(separator: ", "))")

            guard missing.isEmpty else {
                return "⚠️ Kľúč je platný, ale účet nemá prístup k: \(missing.joined(separator: ", "))"
            }
            return "✅ API kľúč funguje a má prístup k potrebným modelom."
        } catch {
            return "❌ Sieťová chyba: \(error.localizedDescription)"
        }
    }

    // MARK: - Public API

    func startRecording(smart: Bool = false) async throws {
        guard hasOpenAIKey else { throw DictationError.noAPIKey }
        guard !isStarting else {
            AppLogger.log("[DictationEngine] startRecording — already starting, ignoring duplicate call")
            return
        }
        isStarting = true
        defer { isStarting = false }

        AppLogger.markSection("nové diktovanie")
        chunkCounter.reset()
        qualityMonitor.reset()
        tapRestartCount = 0
        tapNeedsReinstall = false
        let micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
        AppLogger.log("[DictationEngine] startRecording(smart: \(smart)) — mic permission: \(micAuth.description)")

        stopSession()

        // Determine input format + converter. For an explicit device we use CoreAudio IO proc
        // (DeviceCapture) which bypasses SoundSource's Ark plugin entirely — no deadlocks.
        // For system default we keep AVAudioEngine which already works correctly.
        let inputFormat: AVAudioFormat
        let converter: AVAudioConverter

        if let uid = resolvedInputDeviceUID() {
            // Explicit device selected — ONLY use DeviceCapture, never AVAudioEngine fallback.
            // Falling back to AVAudioEngine when BT device is in a bad state can block
            // audioEngine.start() for 30+ seconds, freezing the UI.
            guard let device = AudioDeviceManager.inputDevices().first(where: { $0.uid == uid }) else {
                AppLogger.log("[DictationEngine] ⚠️ Selected device UID '\(uid)' not found in inputDevices()")
                connectionError = "Vybrané zariadenie nie je dostupné. Zmeň mikrofón v nastaveniach."
                throw DictationError.audioSetupFailed
            }
            guard let capture = DeviceCapture.make(deviceID: device.id) else {
                AppLogger.log("[DictationEngine] ⚠️ DeviceCapture.make() failed for '\(device.name)'")
                connectionError = "Mikrofón '\(device.name)' nie je dostupný. Skontroluj pripojenie."
                throw DictationError.audioSetupFailed
            }
            captureNeedsWarmup = device.needsLinkWarmup
            captureIsBluetooth = device.isBluetooth
            AppLogger.log("[DictationEngine] DeviceCapture path: '\(device.name)' \(capture.format.sampleRate)Hz \(capture.format.channelCount)ch transport=\(device.transportFourCC) warmup=\(captureNeedsWarmup)")
            guard let conv = AVAudioConverter(from: capture.format, to: pcm16Format) else {
                AppLogger.log("[DictationEngine] ⚠️ AVAudioConverter failed for DeviceCapture format")
                throw DictationError.audioSetupFailed
            }
            inputFormat   = capture.format
            converter     = conv
            deviceCapture = capture

        } else {
            // System default — AVAudioEngine path. AVAudioEngine only starts delivering
            // once the route is up, so there's no warmup window to wait out here.
            deviceCapture = nil
            captureNeedsWarmup = false
            captureIsBluetooth = false
            AppLogger.log("[DictationEngine] Using system default microphone")
            audioEngine.reset()
            let inputNode = audioEngine.inputNode
            var fmt = inputNode.outputFormat(forBus: 0)
            let graceDeadline = Date().addingTimeInterval(4.0)
            while (fmt.sampleRate <= 0 || fmt.channelCount <= 0) && Date() < graceDeadline {
                try? await Task.sleep(for: .milliseconds(150))
                fmt = inputNode.outputFormat(forBus: 0)
            }
            AppLogger.log("[DictationEngine] Input format (after grace period): \(fmt.sampleRate)Hz, \(fmt.channelCount)ch, \(fmt.commonFormat.rawValue)")
            guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
                AppLogger.log("[DictationEngine] ⚠️ Mic still not available after grace period — giving up")
                throw DictationError.audioSetupFailed
            }
            guard let conv = AVAudioConverter(from: fmt, to: pcm16Format) else {
                AppLogger.log("[DictationEngine] ⚠️ Failed to create AVAudioConverter")
                throw DictationError.audioSetupFailed
            }
            inputFormat = fmt
            converter   = conv
        }

        // From here on we're committing — any throw below must roll back via stopSession().
        sessionID += 1
        let mySessionID = sessionID

        isSmartMode        = smart
        capturedScreenshot = nil
        capturedProfile    = nil
        capturedAppName    = ""
        capturedBundleID   = ""
        liveText          = ""
        accumulatedText   = ""
        connectionError   = nil
        notice            = nil
        isRecording       = true
        isMicReady        = false
        btNegotiating     = false
        isTranscribing    = false
        didLiveInsert       = false
        liveInsertActive    = false
        liveInsertedCount   = 0
        isWaitingForServer  = false
        lastDeltaDate       = nil
        reconnectAttempts   = 0
        sendQueue.resetStats()
        AppLogger.log("[DictationEngine] 🟢 session #\(sessionID) started | path=\(deviceCapture != nil ? "DeviceCapture" : "AVAudioEngine") liveInsert=\(liveInsertEnabled)")

        // Which app are we dictating into? Needed on every session so the quality tab can
        // say "you dictate differently into ChatGPT than into Slack". Screenshot only in
        // Smart mode — capturing pixels is the slow part, app identity is nearly free.
        // Awaited (with a timeout) in stopAndTranscribe, so short dictations don't lose it.
        // Resolved here, synchronously, because openRealtimeSocket() below needs the profile's
        // keywords in the first session.update — see the sessionProfile declaration.
        sessionProfile = AppProfileStore.shared.matchingProfile(
            bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, windowTitle: nil
        )
        if realtimeModel == .live, transcriptionMode == .realtime {
            AppLogger.log("[DictationEngine] Session profile: \(sessionProfile?.displayName ?? "—"), keywords: \(sessionProfile?.transcriptionKeywords.count ?? 0)")
        }

        contextCaptureTask = Task { [weak self] in
            let ctx = await SmartContextCapture.shared.captureFrontmostContext(captureScreenshot: smart)
            guard let self else { return }
            self.capturedScreenshot = ctx.image
            self.capturedAppName    = ctx.appName ?? ""
            self.capturedBundleID   = ctx.bundleID ?? ""
            self.capturedProfile = AppProfileStore.shared.matchingProfile(
                bundleID: ctx.bundleID, windowTitle: ctx.windowTitle
            )
        }

        do {
            // Locals captured by tap/IO-proc callbacks — no @MainActor access from audio thread.
            let tapConverter  = converter
            let tapPCM16      = pcm16Format
            let tapSampleRate = inputFormat.sampleRate

            if let capture = deviceCapture {
                // ── CoreAudio IO proc path (explicit device) ──────────────────────────────
                // Bypasses AVAudioEngine and SoundSource's Ark plugin entirely.
                // No ConfigChange observer needed — CoreAudio fires per-device notifications
                // separately and we don't fight Ark's HAL lock here.
                switch transcriptionMode {
                case .realtime:
                    openRealtimeSocket(sessionID: mySessionID)
                    let tapQueue = sendQueue
                    capture.onBuffer = { buf in
                        sendChunkOverWebSocket(
                            buffer: buf, inputSampleRate: tapSampleRate,
                            converter: tapConverter, pcm16Format: tapPCM16, queue: tapQueue
                        )
                    }
                    AppLogger.log("[DictationEngine] DeviceCapture WS ready, starting IO proc...")

                case .batch:
                    AppLogger.log("[DictationEngine] DeviceCapture Batch mode (\(batchModel))")
                    _ = batchAudioBuffer.drain()
                    capture.onBuffer = { buf in
                        accumulateChunkForBatch(
                            buffer: buf, inputSampleRate: tapSampleRate,
                            converter: tapConverter, pcm16Format: tapPCM16
                        )
                    }
                }

                guard capture.start() else {
                    AppLogger.log("[DictationEngine] ⚠️ DeviceCapture.start() failed")
                    throw DictationError.audioSetupFailed
                }
                recordingStartDate = Date()
                AppLogger.log("[DictationEngine] DeviceCapture IO proc started ✓")

            } else {
                // ── AVAudioEngine path (system default) ───────────────────────────────────
                let inputNode = audioEngine.inputNode

                switch transcriptionMode {
                case .realtime:
                    openRealtimeSocket(sessionID: mySessionID)
                    AppLogger.log("[DictationEngine] WS task started, audio tap installing...")
                    let tapQueue = sendQueue
                    inputNode.installTap(onBus: 0, bufferSize: 2_400, format: inputFormat) { buf, _ in
                        sendChunkOverWebSocket(
                            buffer: buf, inputSampleRate: tapSampleRate,
                            converter: tapConverter, pcm16Format: tapPCM16, queue: tapQueue
                        )
                    }

                case .batch:
                    AppLogger.log("[DictationEngine] Batch mode (\(batchModel)) — recording locally, no WebSocket")
                    _ = batchAudioBuffer.drain()
                    inputNode.installTap(onBus: 0, bufferSize: 2_400, format: inputFormat) { buf, _ in
                        accumulateChunkForBatch(
                            buffer: buf, inputSampleRate: tapSampleRate,
                            converter: tapConverter, pcm16Format: tapPCM16
                        )
                    }
                }

                // ConfigChange: only relevant for AVAudioEngine (Ark plugin, BT negotiation).
                if let configChangeObserver { NotificationCenter.default.removeObserver(configChangeObserver) }
                configChangeObserver = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange,
                    object: audioEngine,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.isRecording else { return }
                        guard self.isMicReady else {
                            let running = self.audioEngine.isRunning
                            AppLogger.log("[DictationEngine] AVAudioEngineConfigurationChange (chunks:\(chunkCounter.sent), running:\(running)) — pred mic ready")
                            if running { self.tapNeedsReinstall = true }
                            return
                        }
                        AppLogger.log("[DictationEngine] ⚠️ Audio configuration changed mid-recording — aborting session cleanly")
                        self.connectionError = "Zvukové zariadenie sa zmenilo počas nahrávania. Diktovanie zastavené."
                        self.liveText        = "⚠️ Zariadenie sa zmenilo"
                        self.stopSession()
                        self.transcriptionContinuation?.resume(returning: "")
                        self.transcriptionContinuation = nil
                    }
                }

                audioEngine.prepare()
                try audioEngine.start()
                recordingStartDate = Date()
                AppLogger.log("[DictationEngine] Audio engine started, recording active")
            }

            // ── Shared: level meter + isMicReady polling ──────────────────────────────
            audioLevelHolder.update(0)
            levelPollTask?.cancel()
            levelPollTask = Task { @MainActor [weak self] in
                // For DeviceCapture path: track when the current IO proc attempt started
                // so we can restart it if BT HFP negotiation stalls (no chunks for 5s).
                var dcProcStart = Date()
                var dcRestartCount = 0

                while let self, !Task.isCancelled, self.isRecording {
                    self.audioLevel = audioLevelHolder.current

                    if !self.isMicReady, chunkCounter.sent > 0 {
                        let hasAudio = chunkCounter.hasRealAudio
                        // Only BT/Continuity links deliver zeroed buffers while negotiating, so
                        // only those need to wait for actual amplitude (capped at 3s so a silent
                        // session still works). A wired or built-in mic that's producing chunks is
                        // already live — silence there just means the user hasn't started talking,
                        // and waiting on it both delayed the pill and mislabelled a USB mic as
                        // "Inicializujem Bluetooth…".
                        let warmingUp = self.captureNeedsWarmup && !hasAudio
                            && -dcProcStart.timeIntervalSinceNow <= 3.0
                        if !warmingUp {
                            let timedOut = self.captureNeedsWarmup && !hasAudio
                            self.isMicReady = true
                            self.btNegotiating = false
                            AppLogger.log("[DictationEngine] Mic ready — first chunk flowed\(timedOut ? " (3s warmup timeout, audio silent)" : "")")
                        } else {
                            // Chunks flowing but all zeros — link still negotiating. Only claim
                            // "Bluetooth" when it genuinely is one.
                            self.btNegotiating = self.captureIsBluetooth
                        }
                    }

                    if let cap = self.deviceCapture, !self.isMicReady {
                        // BT/Continuity HFP negotiation can stall — restart IO proc after 5s.
                        if -dcProcStart.timeIntervalSinceNow > 5.0 {
                            dcRestartCount += 1
                            if dcRestartCount > 4 {
                                AppLogger.log("[DictationEngine] ⚠️ DeviceCapture — \(dcRestartCount) reštartov bez audia — abort")
                                self.connectionError = "Mikrofón nie je dostupný. Skúste zariadenie odpojiť a znovu pripojiť."
                                self.stopSession()
                                self.transcriptionContinuation?.resume(returning: "")
                                self.transcriptionContinuation = nil
                                break
                            }
                            AppLogger.log("[DictationEngine] levelPoll — DeviceCapture reštart (\(dcRestartCount)/4), BT timeout")
                            cap.stop()
                            try? await Task.sleep(for: .milliseconds(500))
                            if cap.start() {
                                AppLogger.log("[DictationEngine] levelPoll — DeviceCapture reštartovaný ✓")
                            } else {
                                AppLogger.log("[DictationEngine] ⚠️ levelPoll — DeviceCapture.start() retry failed")
                            }
                            dcProcStart = Date()
                        }
                    } else if self.deviceCapture == nil {
                        // AVAudioEngine path: restart engine if ConfigChange stopped it.
                        let needsRestart = !self.isMicReady && self.sessionID == mySessionID &&
                            (self.tapNeedsReinstall || !self.audioEngine.isRunning)
                        if needsRestart {
                            self.tapNeedsReinstall = false
                            self.tapRestartCount += 1
                            if self.tapRestartCount > 5 {
                                AppLogger.log("[DictationEngine] ⚠️ levelPoll — \(self.tapRestartCount) reštartov bez audia — abort")
                                self.connectionError = "Mikrofón nie je dostupný. Skontrolujte nastavenia zvuku."
                                self.stopSession()
                                self.transcriptionContinuation?.resume(returning: "")
                                self.transcriptionContinuation = nil
                                break
                            }
                            AppLogger.log("[DictationEngine] levelPoll — reštart tapa (\(self.tapRestartCount)/5), engine running: \(self.audioEngine.isRunning)")
                            self.audioEngine.stop()
                            try? await Task.sleep(for: .milliseconds(300))
                            do {
                                self.audioEngine.prepare()
                                try self.audioEngine.start()
                                AppLogger.log("[DictationEngine] levelPoll — engine reštartovaný ✓")
                            } catch {
                                AppLogger.log("[DictationEngine] ⚠️ levelPoll — engine restart failed: \(error)")
                                try? await Task.sleep(for: .milliseconds(500))
                            }
                        }
                    }

                    if self.transcriptionMode == .realtime, self.isMicReady,
                       let lastDelta = self.lastDeltaDate {
                        self.isWaitingForServer = -lastDelta.timeIntervalSinceNow > 5.0
                    }

                    // Passive quality check — fires once, ~15s into the session. Advisory only:
                    // the dictation is still running, so this must not park itself over the pill.
                    if let snapshot = qualityMonitor.consumeIfReady() {
                        if let warning = Self.qualityWarning(from: snapshot) {
                            self.showNotice(warning, sticky: false)
                        }
                    }

                    try? await Task.sleep(for: .milliseconds(50))
                }
                self?.audioLevel = 0
                self?.isWaitingForServer = false
            }
        } catch {
            AppLogger.log("[DictationEngine] ⚠️ startRecording failed after partial setup — rolling back: \(error)")
            stopSession()
            throw error
        }
    }


    /// Stops mic, commits audio buffer, waits for server's completed transcript, then returns it.
    func stopAndTranscribe() async -> String? {
        let elapsed = recordingStartDate.map { Int(Date().timeIntervalSince($0)) } ?? 0
        recordingStartDate = nil

        stopAudio()
        isTranscribing = true
        let firstInfo = chunkCounter.firstChunkInfo
        // ponytail: was `chunkCounter.sent > 0` — true for any chunk sent, even pure digital
        // silence (wrong/muted input device). hasRealAudio checks actual peak amplitude, which
        // is what "audio sa nezaznamenalo" is meant to detect — see its BT-silence comment.
        lastRecordingCapturedAudio = chunkCounter.hasRealAudio
        AppLogger.log("[DictationEngine] Recording stopped. Chunks sent: \(chunkCounter.sent), failed: \(chunkCounter.failed), firstChunkBytes: \(firstInfo.bytes), firstChunkMaxAmplitude: \(firstInfo.maxAmplitude)/32767, secondsSinceLastChunk: \(chunkCounter.secondsSinceLastChunk.map { String(format: "%.1f", $0) } ?? "n/a")")

        let transcript: String
        switch transcriptionMode {
        case .realtime:
            // Commit the audio buffer — enqueue behind any still-pending chunks so it's
            // only sent once every prior append has actually gone out, then wait for drain.
            let commitMsg = #"{"type":"input_audio_buffer.commit"}"#
            sendQueue.enqueue(commitMsg)
            await sendQueue.flush()
            AppLogger.log("[DictationEngine] → input_audio_buffer.commit sent")

            // Reconnects recover the connection but can't recover audio chunks that were
            // in flight during the drop — let the user know the transcript might be short
            // a few words, rather than silently handing back an incomplete result.
            if sendQueue.droppedCount > 0, connectionError == nil {
                AppLogger.log("[DictationEngine] ⚠️ \(sendQueue.droppedCount) audio chunk(s) dropped this session")
                showNotice("⚠️ Časť textu sa možno neprenieslo (nestabilné pripojenie) — over výsledok.")
            }

            // Wait for the completed event (timeout 8 s)
            transcript = await withCheckedContinuation { cont in
                transcriptionContinuation = cont
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(8))
                    guard let self else { return }
                    if self.liveInsertActive {
                        self.didLiveInsert = true
                        self.transcriptionContinuation?.resume(returning: "")
                    } else {
                        self.transcriptionContinuation?.resume(returning: self.liveText)
                    }
                    self.transcriptionContinuation = nil
                }
            }

        case .batch:
            transcript = await transcribeBatch()
        }

        var result = transcript.isEmpty ? nil : transcript
        // ponytail: in live-insert mode `transcript`/`result` is deliberately forced to ""
        // (text already typed live, no need to re-insert) — but usage/cost tracking must
        // still count that dictation. accumulatedText holds the real server transcript
        // regardless of insertion mode; batch mode never touches accumulatedText, so fall
        // back to the direct transcript there.
        let dictatedText = transcriptionMode == .realtime ? accumulatedText : transcript
        if !dictatedText.isEmpty { totalSecondsRecorded += elapsed }

        // The context capture races the transcript — on a very short dictation the
        // transcript can land first, leaving capturedProfile nil (which used to silently
        // skip the Smart rewrite altogether). Give it a moment to finish before reading it.
        if let task = contextCaptureTask {
            // Whichever finishes first wins; the 2 s cap keeps a hung ScreenCaptureKit
            // call from delaying the user's text. Cancelling the group only abandons the
            // wait — the capture task itself is harmless if it lands late.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await task.value }
                group.addTask { try? await Task.sleep(for: .seconds(2)) }
                await group.next()
                group.cancelAll()
            }
            if capturedProfile == nil {
                AppLogger.log("[DictationEngine] ⚠️ context capture didn't finish in time — no app context for this session")
            }
        }
        contextCaptureTask = nil

        // Smart diktovanie: rewrite the raw transcript using captured screen context
        var rewritten: String?
        if isSmartMode, let raw = result, let profile = capturedProfile {
            isRewriting = true
            do {
                let output = try await SmartRewriteEngine.shared.rewrite(
                    transcript: raw,
                    screenshot: capturedScreenshot,
                    profile: profile,
                    apiKey: openAIKey
                )
                result = output
                rewritten = output
            } catch {
                AppLogger.log("[DictationEngine] Smart rewrite failed, falling back to raw transcript: \(error)")
                result = raw
            }
            isRewriting = false
        }

        let appName  = capturedAppName
        let bundleID = capturedBundleID
        let category = capturedProfile?.category ?? .generic

        isSmartMode        = false
        capturedScreenshot = nil
        capturedProfile    = nil
        sessionProfile     = nil
        capturedAppName    = ""
        capturedBundleID   = ""

        closeWebSocket()
        isTranscribing  = false
        liveText        = ""
        accumulatedText = ""
        if !dictatedText.isEmpty {
            let model = transcriptionMode == .realtime ? realtimeModel.rawValue : batchModel
            UsageStore.shared.logDictation(seconds: elapsed, text: dictatedText, model: model)
            DictationHistoryStore.shared.log(dictatedText, appName: appName, bundleID: bundleID,
                                             category: category, seconds: elapsed,
                                             rewrittenText: rewritten)
        }
        return result
    }

    // MARK: - Batch transcription (REST /v1/audio/transcriptions)

    /// Wraps the recorded PCM16 buffer in a WAV header and uploads it to the
    /// REST transcription endpoint. Used by .batch mode instead of the
    /// realtime WebSocket commit/wait flow.
    private func transcribeBatch() async -> String {
        let pcmData = batchAudioBuffer.drain()
        AppLogger.log("[DictationEngine] Batch transcribe — \(pcmData.count) bytes PCM, model: \(batchModel)")
        guard !pcmData.isEmpty else { return "" }

        let wav = Self.wavData(pcm16: pcmData, sampleRate: 24_000, channels: 1)

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func addField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        addField("model", batchModel)
        addField("language", "sk")
        addField("response_format", "json")
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        // ponytail: 180s covers ~2min recordings (upload + OpenAI processing); shared session default is 60s which timed out
        let batchSession: URLSession = {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 180
            cfg.timeoutIntervalForResource = 180
            return URLSession(configuration: cfg)
        }()
        do {
            let (data, response) = try await batchSession.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let msg = String(data: data, encoding: .utf8) ?? "?"
                AppLogger.log("[DictationEngine] ⚠️ Batch transcription HTTP error: \(msg.prefix(300))")
                connectionError = "Prepis zlyhal: \(msg.prefix(150))"
                return ""
            }
            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let text = json["text"] as? String
            else {
                AppLogger.log("[DictationEngine] ⚠️ Batch transcription — unexpected response: \(String(data: data, encoding: .utf8)?.prefix(300) ?? "?")")
                return ""
            }
            AppLogger.log("[DictationEngine] Batch transcription completed (\(text.count) chars)")
            return text
        } catch {
            AppLogger.log("[DictationEngine] ⚠️ Batch transcription network error: \(error)")
            connectionError = "Sieťová chyba: \(error.localizedDescription)"
            return ""
        }
    }

    /// Minimal 44-byte canonical WAV header for mono PCM16 — no dependency needed.
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
        u16(1) // PCM
        u16(channels)
        u32(sampleRate)
        u32(byteRate)
        u16(blockAlign)
        u16(16) // bits per sample
        header.append("data".data(using: .ascii)!); u32(dataSize)
        return header + pcm16
    }

    // MARK: - WebSocket

    private func sendSessionConfig(delay: String) {
        let payload = realtimeModel == .live
            ? liveTranscribeSessionPayload(delay: delay)
            : legacyRealtimeSessionPayload(delay: delay)
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str  = String(data: data, encoding: .utf8) else { return }
        AppLogger.log("[DictationEngine] → session.update: \(str.prefix(400))")
        sendQueue.enqueue(str)
    }

    /// Dedicated transcription session (`intent=transcription`). No conversational model in
    /// the loop, so none of the output_modalities/create_response contortions below.
    ///
    /// `turn_detection` MUST be null: the API rejects server_vad for this model outright
    /// ("Turn detection is not supported for this transcription model") and a rejected
    /// session.update means the transcription config never applies — zero transcript, no
    /// obvious cause. Consequence: no mid-recording auto-commit, so the single `completed`
    /// arrives on our own commit in stopAndTranscribe(). Verified over a 3.3-minute stream:
    /// connection held, deltas stayed append-only (never revised), so live-insert is safe.
    private func liveTranscribeSessionPayload(delay: String) -> [String: Any] {
        var transcription: [String: Any] = [
            "model": RealtimeModel.live.rawValue,
            // Plural on purpose — this model takes `languages`, not `language`, and sending
            // both is an error. "en" is here because Slovak dictation routinely carries
            // English technical terms.
            "languages": ["sk", "en"],
            "delay": delay
        ]
        if let profile = sessionProfile {
            transcription["prompt"] = profile.category.transcriptionPrompt
        }
        // Default (always-on) keywords first, then the matched profile's — order shouldn't
        // matter to the model, but keeping it deterministic makes app.log easier to read.
        let keywords = AppProfile.parseKeywords(defaultKeywords) + (sessionProfile?.transcriptionKeywords ?? [])
        if !keywords.isEmpty { transcription["keywords"] = keywords }
        return [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24000],
                        "turn_detection": NSNull(),
                        "transcription": transcription
                    ] as [String: Any]
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    /// Original path: the conversational gpt-realtime-2 used as transcription-only —
    /// text-only output, VAD that fires without generating a reply, transcription delegated
    /// to gpt-realtime-whisper. Kept as the fallback behind the model picker.
    private func legacyRealtimeSessionPayload(delay: String) -> [String: Any] {
        [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "output_modalities": ["text"],
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24000
                        ],
                        "turn_detection": [
                            "type":                "server_vad",
                            "threshold":           0.5,
                            "prefix_padding_ms":   300,
                            "silence_duration_ms": 500,
                            "create_response":     false
                        ],
                        "transcription": [
                            "model":    RealtimeModel.legacy.rawValue,
                            "language": "sk",
                            "delay":    delay
                        ]
                    ] as [String: Any]
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    private func receiveMessages(task: URLSessionWebSocketTask, sessionID mySessionID: Int) async {
        AppLogger.log("[DictationEngine] receiveMessages loop started (session #\(mySessionID))")
        do {
            while true {
                let raw = try await task.receive()
                let text: String
                switch raw {
                case .string(let s): text = s
                case .data(let d):   text = String(data: d, encoding: .utf8) ?? ""
                @unknown default:    continue
                }
                // ponytail: skip delta events — they're many/second and useless after debugging.
                // Log everything else (session.created, error, completed, speech_started, …).
                if !text.contains("transcription.delta") && !text.contains("audio_transcript.delta") {
                    AppLogger.log("[DictationEngine] WS ← \(text.prefix(300))")
                }
                handleEvent(text, sessionID: mySessionID)
            }
        } catch {
            // A newer session may have already started and closed THIS session's
            // socket on purpose (stopSession()) — don't let that stale close
            // overwrite the newer session's state.
            guard sessionID == mySessionID else {
                AppLogger.log("[DictationEngine] WS closed for stale session #\(mySessionID) (current #\(sessionID)) — ignoring: \(error)")
                return
            }
            AppLogger.log("[DictationEngine] WS closed: \(error)")
            if isRecording {
                attemptReconnect(deadTask: task, sessionID: mySessionID,
                                  reason: "receive loop closed: \(error.localizedDescription)")
            }
        }
    }

    /// Called when either the send or receive side of the realtime WS looks dead while
    /// still recording (flaky internet, not a user-initiated stop). Opens a fresh WS task,
    /// re-sends the session config, and resumes — the model loses server-side context from
    /// the reconnect but our own accumulatedText keeps everything transcribed so far, so new
    /// deltas just append onto it. Bounded by maxReconnectAttempts so a truly offline machine
    /// still gives up and surfaces an error instead of looping forever.
    private func attemptReconnect(deadTask: URLSessionWebSocketTask, sessionID mySessionID: Int, reason: String) {
        guard sessionID == mySessionID, isRecording else { return }
        // `wsTask` may have already been replaced by a reconnect triggered from the other
        // signal path (send-side vs. receive-side can both fire for the same dead task) —
        // if so, this is a stale duplicate, ignore it.
        guard deadTask === wsTask else {
            AppLogger.log("[DictationEngine] Ignoring dead-task signal for already-replaced WS task (\(reason))")
            return
        }
        guard reconnectAttempts < maxReconnectAttempts else {
            AppLogger.log("[DictationEngine] ⚠️ Reconnect attempts exhausted (\(maxReconnectAttempts)) — giving up (\(reason))")
            connectionError = "Spojenie so serverom sa stratilo. Skús diktovanie znova."
            liveText        = "⚠️ Chyba spojenia"
            isRecording     = false
            return
        }
        reconnectAttempts += 1
        AppLogger.log("[DictationEngine] 🔄 Reconnecting WS (\(reconnectAttempts)/\(maxReconnectAttempts)) — \(reason)")

        openRealtimeSocket(sessionID: mySessionID)
    }

    /// Opens the realtime WebSocket for the currently selected model, wires the send queue
    /// and the receive loop, and sends the session config.
    ///
    /// ponytail: this was copy-pasted three times — DeviceCapture path, AVAudioEngine path,
    /// and reconnect — so adding a second realtime model would have meant three near-identical
    /// edits. One function instead; the model only shows up in `socketURL` and `sendSessionConfig`.
    private func openRealtimeSocket(sessionID mySessionID: Int) {
        let url = realtimeModel.socketURL
        AppLogger.log("[DictationEngine] Connecting to \(url) (\(realtimeModel.rawValue))")
        var req = URLRequest(url: url)
        req.setValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .default)
        let task    = session.webSocketTask(with: req)
        wsURLSession = session
        wsTask       = task
        sendQueue.configure(task: task)
        sendQueue.onTaskAppearsDead = { [weak self] deadTask in
            Task { @MainActor in
                self?.attemptReconnect(deadTask: deadTask, sessionID: mySessionID, reason: "send failures exhausted")
            }
        }
        task.resume()
        sendSessionConfig(delay: transcriptionDelay)
        Task { await self.receiveMessages(task: task, sessionID: mySessionID) }
    }

    private func handleEvent(_ text: String, sessionID mySessionID: Int) {
        guard sessionID == mySessionID else {
            AppLogger.log("[DictationEngine] Ignoring event from stale session #\(mySessionID) (current #\(sessionID))")
            return
        }
        guard
            let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String
        else { return }

        switch type {
        case "session.created", "transcription_session.created", "session.updated":
            AppLogger.log("[DictationEngine] ✅ Session ready: \(type)")

        case "error":
            let errObj = json["error"] as? [String: Any]
            let code   = errObj?["code"]    as? String ?? ""
            let msg    = errObj?["message"] as? String ?? text
            AppLogger.log("[DictationEngine] ⚠️ API error [\(code)]: \(msg)")

            // ponytail: server_vad auto-commits on silence; our trailing manual commit
            // in stopAndTranscribe() then hits "buffer empty" — harmless, but resuming
            // with "" wiped out everything already transcribed. Resume with what we have.
            let alreadyTranscribed = accumulatedText
            let harmless = code == "input_audio_buffer_commit_empty"
            // Any *real* server-side error means transcription won't work even if we keep
            // "recording", so surface it and tear the session down. The buffer-empty case is
            // the expected end of a silent session — it must not raise a user-facing error at
            // all (it used to show the raw English API text, only hidden by a 3 s auto-dismiss).
            if !harmless {
                connectionError = "[\(code)] \(msg)"
                liveText = "⚠️ \(msg)"
            }
            stopSession()
            if liveInsertActive {
                didLiveInsert = true
                transcriptionContinuation?.resume(returning: "")
            } else {
                transcriptionContinuation?.resume(returning: alreadyTranscribed)
            }
            transcriptionContinuation = nil

        // Partial transcription delta — update live text shown in indicator
        case "input_audio_transcription.delta",
             "response.audio_transcript.delta",
             "conversation.item.input_audio_transcription.delta":
            if let delta = json["delta"] as? String, !delta.isEmpty {
                lastDeltaDate = Date()
                isWaitingForServer = false
                liveText += delta
                if transcriptionMode == .realtime, liveInsertEnabled, !isSmartMode {
                    if !liveInsertActive {
                        liveInsertActive = FocusValidator.hasEditableFocus()
                        if liveInsertActive {
                            AppLogger.log("[DictationEngine] Live-insert active — focused field confirmed")
                        }
                    }
                    if liveInsertActive {
                        TextInserter.shared.typeText(delta)
                        liveInsertedCount += delta.count
                    }
                }
            }

        // Transcription completed after buffer commit — resume stopAndTranscribe
        case "input_audio_transcription.completed",
             "response.audio_transcript.done",
             "conversation.item.input_audio_transcription.completed":
            let transcript = (json["transcript"] as? String)
                          ?? (json["text"]       as? String)
                          ?? ""
            if !transcript.isEmpty {
                accumulatedText += (accumulatedText.isEmpty ? "" : " ") + transcript
                liveText = accumulatedText
            }
            if liveInsertActive {
                if transcriptionContinuation != nil {
                    // User pressed stop — text was already typed live, skip normal paste.
                    // ponytail: no correction — realtime deltas match completed in practice;
                    // minor mismatch (punctuation) is acceptable vs. the complexity of backspace+retype.
                    AppLogger.log("[DictationEngine] Live-insert done — typed \(liveInsertedCount) chars live, skipping paste")
                    didLiveInsert = true
                    transcriptionContinuation?.resume(returning: "")
                    transcriptionContinuation = nil
                }
                // Mid-recording VAD completion: liveText updated above, nothing else to do.
            } else {
                transcriptionContinuation?.resume(returning: liveText)
                transcriptionContinuation = nil
            }

        default:
            AppLogger.log("[DictationEngine] unhandled event: \(type)")
        }
    }

    // MARK: - Cleanup

    private func stopAudio() {
        AppLogger.log("[DictationEngine] 🔴 stopAudio() | session #\(sessionID) isMicReady=\(isMicReady) btNeg=\(btNegotiating) chunks=\(chunkCounter.sent) err=\(connectionError ?? "nil")")
        if let cap = deviceCapture {
            cap.stop()
            deviceCapture = nil
        } else {
            audioEngine.inputNode.removeTap(onBus: 0)
            if audioEngine.isRunning { audioEngine.stop() }
        }
        isRecording    = false
        btNegotiating  = false
        captureNeedsWarmup = false
        captureIsBluetooth = false
        levelPollTask?.cancel()
        levelPollTask = nil
        audioLevel = 0
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
    }

    private func closeWebSocket() {
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask       = nil
        wsURLSession = nil
    }

    private func stopSession() {
        stopAudio()
        closeWebSocket()
    }

    // MARK: - Errors

    enum DictationError: LocalizedError {
        case noAPIKey, audioSetupFailed
        var errorDescription: String? {
            switch self {
            case .noAPIKey:        "OpenAI API kľúč nie je nastavený. Nastav ho v Nastaveniach."
            case .audioSetupFailed: "Nepodarilo sa inicializovať audio konvertor."
            }
        }
    }
}

// MARK: - Audio chunk helper (free function — nonisolated, safe from tap thread)

/// Thread-safe counter so we can log "first chunk sent" / periodic progress
/// from the realtime audio tap thread without touching @MainActor state.
private final class ChunkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var sentCount = 0
    private var failCount = 0
    private var firstChunkBytes = 0
    private var firstChunkMaxAmplitude: Int16 = 0
    private var peakAmplitude: Int16 = 0   // max across all chunks — detects BT silence
    private var lastSentAt: Date?

    func recordSent(byteCount: Int = 0, maxAmplitude: Int16 = 0) -> Int {
        lock.lock(); defer { lock.unlock() }
        sentCount += 1
        if sentCount == 1 { firstChunkBytes = byteCount; firstChunkMaxAmplitude = maxAmplitude }
        if maxAmplitude > peakAmplitude { peakAmplitude = maxAmplitude }
        lastSentAt = Date()
        return sentCount
    }
    var firstChunkInfo: (bytes: Int, maxAmplitude: Int16) {
        lock.lock(); defer { lock.unlock() }
        return (firstChunkBytes, firstChunkMaxAmplitude)
    }
    // True when any chunk contained non-silence (amplitude > ~0.15% of full scale).
    // BT HFP delivers zeroed buffers during negotiation — this distinguishes real audio.
    var hasRealAudio: Bool {
        lock.lock(); defer { lock.unlock() }
        return peakAmplitude > 50
    }
    var secondsSinceLastChunk: Double? {
        lock.lock(); defer { lock.unlock() }
        guard let lastSentAt else { return nil }
        return Date().timeIntervalSince(lastSentAt)
    }
    func recordFailure() -> Int {
        lock.lock(); defer { lock.unlock() }
        failCount += 1
        return failCount
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        sentCount = 0
        failCount = 0
        firstChunkBytes = 0
        firstChunkMaxAmplitude = 0
        peakAmplitude = 0
        lastSentAt = nil
    }
    var sent: Int   { lock.lock(); defer { lock.unlock() }; return sentCount }
    var failed: Int { lock.lock(); defer { lock.unlock() }; return failCount }
}
private let chunkCounter = ChunkCounter()

/// Passive audio-quality check over the first ~15s of a session — peak level,
/// clipping, and a noise-floor/SNR estimate (same heuristic as MicTestEngine, minus
/// the transcript-accuracy part since there's no reference sentence during real
/// dictation). Fed from convertChunk on the realtime thread; evaluated once from the
/// MainActor level-poll loop so a quiet/noisy mic gets flagged mid-session instead of
/// only being visible after the fact via a standalone test.
private final class DictationQualityMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var windowStart: Date?
    private var frameRMS: [Float] = []
    private var peak: Float = 0
    private var clippedSamples = 0
    private var totalSamples = 0
    private var ready = false
    private let windowDuration: TimeInterval = 15
    private let maxFrames = 600 // ~15s worth of chunk-sized frames — bounded, cheap

    func reset() {
        lock.lock()
        windowStart = nil; frameRMS.removeAll(); peak = 0
        clippedSamples = 0; totalSamples = 0; ready = false
        lock.unlock()
    }

    func recordChunk(ptr: UnsafePointer<Int16>, count: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !ready, count > 0 else { return }
        let now = Date()
        if windowStart == nil { windowStart = now }

        var sumSquares: Float = 0
        var localPeak: Float = 0
        var localClipped = 0
        for i in 0..<count {
            let f = Float(ptr[i]) / Float(Int16.max)
            let a = abs(f)
            if a > localPeak { localPeak = a }
            if a >= 0.999 { localClipped += 1 }
            sumSquares += f * f
        }
        if frameRMS.count < maxFrames { frameRMS.append(sqrt(sumSquares / Float(count))) }
        if localPeak > peak { peak = localPeak }
        clippedSamples += localClipped
        totalSamples += count

        if let start = windowStart, now.timeIntervalSince(start) >= windowDuration {
            ready = true
        }
    }

    /// Non-nil exactly once — the caller (MainActor poll loop) consumes it and moves on.
    func consumeIfReady() -> (peakDBFS: Double, clippingPercent: Double, snrDB: Double?)? {
        lock.lock(); defer { lock.unlock() }
        guard ready else { return nil }
        ready = false // consumed — never fires again this session
        let peakDBFS = 20 * log10(Double(max(peak, 1e-6)))
        let clippingPercent = totalSamples > 0 ? Double(clippedSamples) / Double(totalSamples) * 100 : 0
        guard frameRMS.count >= 5 else { return (peakDBFS, clippingPercent, nil) }
        let sorted = frameRMS.sorted()
        let bucket = max(1, sorted.count / 5)
        let noiseFloor = sorted.prefix(bucket).reduce(0, +) / Float(bucket)
        let voicePeak  = sorted.suffix(bucket).reduce(0, +) / Float(bucket)
        let snrDB = 20 * log10(Double(max(voicePeak, 1e-6)) / Double(max(noiseFloor, 1e-6)))
        return (peakDBFS, clippingPercent, snrDB)
    }
}
private let qualityMonitor = DictationQualityMonitor()

/// Thread-safe holder for the current mic level (0...1, normalized). Updated from
/// the realtime audio thread (cheap lock+write only); read by a MainActor polling
/// loop in DictationEngine so the UI never touches @Observable state cross-thread.
private final class AudioLevelHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Float = 0

    func update(_ v: Float) {
        lock.lock(); value = v; lock.unlock()
    }
    var current: Float {
        lock.lock(); defer { lock.unlock() }; return value
    }
}
private let audioLevelHolder = AudioLevelHolder()

/// Accumulates PCM16 audio in memory during .batch-mode recording, instead of
/// streaming chunks over the WebSocket. Same lock-holder pattern as ChunkCounter/
/// AudioLevelHolder above — safe to touch from the realtime audio tap thread.
private final class BatchAudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ bytes: Data) {
        lock.lock(); data.append(bytes); lock.unlock()
    }
    func drain() -> Data {
        lock.lock(); defer { lock.unlock() }
        let d = data
        data = Data()
        return d
    }
}
private let batchAudioBuffer = BatchAudioBuffer()

// Realtime audio thread: NO file/console I/O here on purpose. Logging from the
// CoreAudio render thread was the likely cause of SwiftUI/AttributeGraph crashes
// observed in testing (logging can block on I/O and stall the realtime thread,
// and any incidental Swift runtime work here is outside actor-isolation guarantees).
// Only thread-safe, lock-protected counters are touched; logging happens later on
// the MainActor (see stopAndTranscribe's summary line).
/// Converts one tap buffer to 24kHz PCM16, updates the level meter + chunkCounter
/// diagnostics, and returns the raw bytes — shared by both the realtime (WS) and
/// batch (in-memory buffer) tap callbacks below.
private func convertChunk(
    buffer: AVAudioPCMBuffer,
    inputSampleRate: Double,
    converter: AVAudioConverter,
    pcm16Format: AVAudioFormat
) -> Data? {
    let ratio    = 24_000.0 / inputSampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
    guard let out = AVAudioPCMBuffer(pcmFormat: pcm16Format, frameCapacity: capacity) else {
        chunkCounter.recordFailure()
        return nil
    }

    var consumed = false
    var err: NSError?
    converter.convert(to: out, error: &err) { _, status in
        guard !consumed else { status.pointee = .noDataNow; return nil }
        status.pointee = .haveData
        consumed = true
        return buffer
    }
    guard err == nil, out.frameLength > 0,
          let ptr = out.int16ChannelData?.pointee else {
        chunkCounter.recordFailure()
        return nil
    }

    // Cheap max-amplitude scan on just this buffer to verify we're not sending silence/zeros.
    var maxAmp: Int16 = 0
    let frameCount = Int(out.frameLength)
    for i in 0..<frameCount {
        let v = ptr[i]
        let mag = v == Int16.min ? Int16.max : abs(v)
        if mag > maxAmp { maxAmp = mag }
    }
    chunkCounter.recordSent(byteCount: frameCount * 2, maxAmplitude: maxAmp)
    qualityMonitor.recordChunk(ptr: ptr, count: frameCount)
    // Normal speech rarely exceeds ~10-30% of full digital scale, so a raw linear
    // ratio barely moves the UI. Apply a perceptual (sqrt) curve + gain so typical
    // speaking volume visibly animates the equalizer.
    let rawLevel = Float(maxAmp) / Float(Int16.max)
    let perceptual = min(1, sqrt(rawLevel) * 1.6)
    audioLevelHolder.update(perceptual)

    return Data(bytes: ptr, count: Int(out.frameLength) * 2)
}

// Realtime audio thread: NO file/console I/O here on purpose (see note above).
private func sendChunkOverWebSocket(
    buffer: AVAudioPCMBuffer,
    inputSampleRate: Double,
    converter: AVAudioConverter,
    pcm16Format: AVAudioFormat,
    queue: AudioSendQueue
) {
    guard let bytes = convertChunk(buffer: buffer, inputSampleRate: inputSampleRate, converter: converter, pcm16Format: pcm16Format) else { return }
    // base64 encoding happens in AudioSendQueue.drainLoop (cooperative pool), not here on the audio thread.
    queue.enqueueAudio(bytes)
}

// Same as above, but for .batch mode: no WebSocket, just accumulate in memory.
private func accumulateChunkForBatch(
    buffer: AVAudioPCMBuffer,
    inputSampleRate: Double,
    converter: AVAudioConverter,
    pcm16Format: AVAudioFormat
) {
    guard let bytes = convertChunk(buffer: buffer, inputSampleRate: inputSampleRate, converter: converter, pcm16Format: pcm16Format) else { return }
    batchAudioBuffer.append(bytes)
}

private extension AVAuthorizationStatus {
    var description: String {
        switch self {
        case .notDetermined: "notDetermined"
        case .restricted:    "restricted"
        case .denied:        "DENIED ⚠️"
        case .authorized:    "authorized ✅"
        @unknown default:    "unknown"
        }
    }
}
