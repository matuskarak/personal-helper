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
    var rate: Float {
        didSet { UserDefaults.standard.set(Double(rate), forKey: "tts.rate") }
    }
    var selectedVoiceIdentifier: String? {
        didSet { UserDefaults.standard.set(selectedVoiceIdentifier, forKey: "tts.voiceIdentifier") }
    }

    // "auto" | "sk-SK" | "en-US"
    var languageMode: String {
        didSet { UserDefaults.standard.set(languageMode, forKey: "tts.languageMode") }
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var googleEngine: GoogleCloudTTSEngine { .shared }

    override private init() {
        let savedMode = TTSMode(rawValue: UserDefaults.standard.string(forKey: "tts.mode") ?? "") ?? .googleCloud
        let savedRate = Float(UserDefaults.standard.double(forKey: "tts.rate"))
        self.mode = savedMode
        self.rate = savedRate > 0 ? savedRate.clamped(0.1, 1.0) : 0.5
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
        switch mode {
        case .system:      speakWithSystem(text, language: lang)
        case .googleCloud: Task { await speakWithGoogle(text, language: lang) }
        }
    }

    func replayLast() {
        guard let text = RecentTextStore.shared.lastText else { return }
        speak(text)
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
        Task { @MainActor in self.isSpeaking = false; self.isPaused = false }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false; self.isPaused = false }
    }
}

// MARK: - Helpers

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(hi, Swift.max(lo, self)) }
}
private extension Float {
    func clamped(_ lo: Float, _ hi: Float) -> Float { Swift.min(hi, Swift.max(lo, self)) }
}
