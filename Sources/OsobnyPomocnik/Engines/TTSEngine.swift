import AVFoundation
import NaturalLanguage
import Observation

enum TTSMode: String, CaseIterable {
    case system = "system"
    case googleCloud = "googleCloud"

    var displayName: String {
        switch self {
        case .system:      "macOS (on-device)"
        case .googleCloud: "Google Cloud (Chirp 3 HD)"
        }
    }
}

@Observable
@MainActor
final class TTSEngine: NSObject {
    static let shared = TTSEngine()

    private(set) var isSpeaking = false
    private(set) var isPaused   = false
    private(set) var currentText: String?

    // Stored properties so @Observable tracks changes and SwiftUI re-renders
    var mode: TTSMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "tts.mode") }
    }
    /// Every speed the settings screen offers, in cycling order (Vyvoj/Komponenty/nastavenia-rychlosti.md).
    static let allSpeeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    static let defaultSpeeds: [Double] = [0.75, 1, 1.25, 1.5, 2]
    static func format(_ speed: Double) -> String { String(format: "%g×", speed) }

    /// Playback speed as a multiplier (1 = normal). macOS voices top out at 2×, Google honours up to 3×.
    var speed: Double {
        didSet { UserDefaults.standard.set(speed, forKey: "tts.speed") }
    }
    /// Speeds the pill button cycles through — kept sorted and always containing 1×, so the
    /// user can never end up with an empty set.
    var enabledSpeeds: [Double] {
        didSet {
            let clean = Self.allSpeeds.filter { enabledSpeeds.contains($0) || $0 == 1 }
            if clean != enabledSpeeds { enabledSpeeds = clean }
            UserDefaults.standard.set(enabledSpeeds, forKey: "tts.enabledSpeeds")
        }
    }
    var orderedSpeeds: [Double] { Self.allSpeeds.filter { enabledSpeeds.contains($0) } }
    /// Engine-native rate: 0.5 = normal for both AVSpeech and the Google mapping.
    private var rate: Float { Float(speed / 2) }
    var selectedVoiceIdentifier: String? {
        didSet { UserDefaults.standard.set(selectedVoiceIdentifier, forKey: "tts.voiceIdentifier") }
    }

    // "auto" | "sk-SK" | "en-US"
    var languageMode: String {
        didSet { UserDefaults.standard.set(languageMode, forKey: "tts.languageMode") }
    }

    private let synthesizer = AVSpeechSynthesizer()
    /// The utterance whose finish/cancel is allowed to flip `isSpeaking` — stopSpeaking() of
    /// the previous utterance delivers its didCancel *after* the replacement already started.
    private var currentUtterance: ObjectIdentifier?
    private var googleEngine: GoogleCloudTTSEngine { .shared }

    override private init() {
        let savedMode = TTSMode(rawValue: UserDefaults.standard.string(forKey: "tts.mode") ?? "") ?? .googleCloud
        self.mode = savedMode
        let savedSpeed = UserDefaults.standard.double(forKey: "tts.speed")
        let legacyRate = UserDefaults.standard.double(forKey: "tts.rate")   // pre-redesign slider 0.1–1.0 (= ×0.2–×2)
        let migrated = legacyRate > 0
            ? Self.allSpeeds.min { abs($0 - legacyRate * 2) < abs($1 - legacyRate * 2) } ?? 1
            : 1
        self.speed = savedSpeed > 0 ? savedSpeed : migrated
        self.enabledSpeeds = UserDefaults.standard.array(forKey: "tts.enabledSpeeds") as? [Double] ?? Self.defaultSpeeds
        self.selectedVoiceIdentifier = UserDefaults.standard.string(forKey: "tts.voiceIdentifier")
        self.languageMode = UserDefaults.standard.string(forKey: "tts.languageMode") ?? "auto"
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Public interface

    func speak(_ text: String, trackUsage: Bool = true) {
        currentText = text
        RecentTextStore.shared.store(text)
        if trackUsage { UsageStore.shared.logReading(text) }
        let lang = resolvedLanguage(for: text)
        let spoken = SpeechTextNormalizer.normalize(text, language: lang)
        switch mode {
        case .system:      speakWithSystem(spoken, language: lang)
        case .googleCloud: Task { await speakWithGoogle(spoken, language: lang) }
        }
    }

    func replayLast() {
        guard let text = RecentTextStore.shared.lastText else { return }
        speak(text)
    }

    /// Steps to the next enabled speed (wrapping). Mid-read, the current text restarts at the
    /// new speed — neither engine can change rate inside an utterance (client decision 2026-09-11).
    @discardableResult
    func cycleSpeed() -> Double {
        let list = orderedSpeeds
        let next = list.first { $0 > speed + 0.001 } ?? list.first ?? 1
        speed = next
        if isSpeaking, let text = currentText { speak(text, trackUsage: false) }
        return next
    }

    func pause() {
        switch mode {
        case .system:
            guard isSpeaking, !isPaused else { return }
            synthesizer.pauseSpeaking(at: .word)
            isPaused = true
        case .googleCloud:
            googleEngine.pause()
            isPaused = googleEngine.isPaused
        }
    }

    func resume() {
        switch mode {
        case .system:
            guard isPaused else { return }
            synthesizer.continueSpeaking()
            isPaused = false
        case .googleCloud:
            googleEngine.resume()
            isPaused = googleEngine.isPaused
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        googleEngine.stop()
        isSpeaking  = false
        isPaused    = false
        currentText = nil
    }

    // MARK: - System TTS

    private func speakWithSystem(_ text: String, language: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = rate.clamped(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceMaximumSpeechRate)
        utterance.voice = preferredSystemVoice(language: language)
        currentUtterance = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
        isSpeaking = true
        isPaused   = false
    }

    var availableSkVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("sk") }
    }

    private func preferredSystemVoice(language: String) -> AVSpeechSynthesisVoice? {
        // Use the manually selected voice only when it matches the resolved language
        if let id = selectedVoiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: id),
           voice.language.hasPrefix(String(language.prefix(2))) { return voice }
        return AVSpeechSynthesisVoice(language: language)
            ?? AVSpeechSynthesisVoice(language: "sk-SK")
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    // MARK: - Language resolution

    func resolvedLanguage(for text: String) -> String {
        switch languageMode {
        case "sk-SK": return "sk-SK"
        case "en-US": return "en-US"
        default: // "auto"
            let rec = NLLanguageRecognizer()
            rec.processString(text)
            switch rec.dominantLanguage {
            case .english: return "en-US"
            default:       return "sk-SK"
            }
        }
    }

    // MARK: - Google Cloud TTS

    private func speakWithGoogle(_ text: String, language: String) async {
        do {
            googleEngine.stop()
            isSpeaking = true
            isPaused   = false
            try await googleEngine.speak(text, rate: rate, languageCode: language)
            isSpeaking = googleEngine.isSpeaking
            isPaused   = googleEngine.isPaused
        } catch GoogleCloudTTSEngine.GoogleTTSError.noAPIKey {
            mode = .system
            speakWithSystem(text, language: language)
        } catch {
            isSpeaking = false
            print("[TTSEngine] Google TTS error: \(error.localizedDescription)")
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension TTSEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        utteranceEnded(ObjectIdentifier(utterance))
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        utteranceEnded(ObjectIdentifier(utterance))
    }
    nonisolated private func utteranceEnded(_ id: ObjectIdentifier) {
        Task { @MainActor in
            guard id == self.currentUtterance else { return }
            self.isSpeaking = false; self.isPaused = false
        }
    }
}

// MARK: - Helpers

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(hi, Swift.max(lo, self)) }
}
private extension Float {
    func clamped(_ lo: Float, _ hi: Float) -> Float { Swift.min(hi, Swift.max(lo, self)) }
}
