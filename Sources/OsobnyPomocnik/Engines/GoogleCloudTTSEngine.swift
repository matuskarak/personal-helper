import AVFoundation
import Foundation
import NaturalLanguage
import Observation

// MARK: - API models

private struct SynthesizeRequest: Encodable {
    let input: Input
    let voice: VoiceSelection
    let audioConfig: AudioConfig

    struct Input: Encodable { let text: String }
    struct VoiceSelection: Encodable { let languageCode: String; let name: String }
    struct AudioConfig: Encodable { let audioEncoding: String; let speakingRate: Double }
}

private struct SynthesizeResponse: Decodable {
    let audioContent: String
}

struct GoogleVoice: Decodable, Identifiable, Sendable {
    let name: String
    let languageCodes: [String]
    let ssmlGender: String
    var id: String { name }

    var displayName: String {
        let character = name.components(separatedBy: "-").last ?? name
        return name.contains("HD") ? "\(character) (HD)" : character
    }
}

private struct VoicesResponse: Decodable {
    let voices: [GoogleVoice]
}

// MARK: - Engine

@Observable
@MainActor
final class GoogleCloudTTSEngine: NSObject {
    static let shared = GoogleCloudTTSEngine()

    private(set) var isSpeaking = false
    private(set) var isPaused  = false

    private(set) var totalCharactersUsed: Int {
        didSet { UserDefaults.standard.set(totalCharactersUsed, forKey: "google.tts.charCount") }
    }

    private let baseURL = "https://texttospeech.googleapis.com/v1"
    private let keychainKey = "google-tts-api-key"

    private var player: AVAudioPlayer?
    private var playbackContinuation: CheckedContinuation<Void, Error>?

    // UserDefaults in development (no codesigning = Keychain returns nil).
    // Switch to KeychainHelper for production/notarized build.
    var apiKey: String {
        didSet {
            if apiKey.isEmpty { UserDefaults.standard.removeObject(forKey: "google.api.key") }
            else              { UserDefaults.standard.set(apiKey, forKey: "google.api.key") }
        }
    }

    var hasAPIKey: Bool { !apiKey.isEmpty }

    var selectedVoiceName: String {
        didSet { UserDefaults.standard.set(selectedVoiceName, forKey: "google.tts.voice") }
    }

    // Default EN Chirp 3 HD voice — can be expanded to a picker later
    var selectedEnVoiceName: String {
        didSet { UserDefaults.standard.set(selectedEnVoiceName, forKey: "google.tts.voice.en") }
    }

    func voiceName(for languageCode: String) -> String {
        languageCode.hasPrefix("en") ? selectedEnVoiceName : selectedVoiceName
    }

    private override init() {
        self.totalCharactersUsed  = UserDefaults.standard.integer(forKey: "google.tts.charCount")
        self.apiKey               = UserDefaults.standard.string(forKey: "google.api.key") ?? ""
        self.selectedVoiceName    = UserDefaults.standard.string(forKey: "google.tts.voice") ?? "sk-SK-Chirp3-HD-Zephyr"
        self.selectedEnVoiceName  = UserDefaults.standard.string(forKey: "google.tts.voice.en") ?? "en-US-Chirp3-HD-Aoede"
        super.init()
    }

    func resetCharacterCount() { totalCharactersUsed = 0 }

    // MARK: - Playback pipeline

    /// Splits text into sentences and pipelines fetch+playback for low latency.
    func speak(_ text: String, rate: Float, languageCode: String = "sk-SK") async throws {
        guard hasAPIKey else { throw GoogleTTSError.noAPIKey }

        stop()
        isSpeaking = true
        isPaused   = false

        let sentences = text.sentences()
        guard !sentences.isEmpty else { isSpeaking = false; return }

        // Start fetching first sentence immediately
        var nextFetch: Task<Data, Error> = Task { [weak self] in
            guard let self else { throw GoogleTTSError.captureFailed }
            return try await self.synthesize(text: sentences[0], rate: rate, languageCode: languageCode)
        }

        for i in sentences.indices {
            guard isSpeaking else { break }

            let data = try await nextFetch.value

            // Kick off next sentence fetch in parallel while current plays
            if i + 1 < sentences.endIndex {
                let nextText = sentences[i + 1]
                let r = rate
                let lang = languageCode
                nextFetch = Task { [weak self] in
                    guard let self else { throw GoogleTTSError.captureFailed }
                    return try await self.synthesize(text: nextText, rate: r, languageCode: lang)
                }
            }

            try await playAndWait(data)
        }

        if isSpeaking { isSpeaking = false; isPaused = false }
    }

    func pause() {
        player?.pause()
        isPaused = true
    }

    func resume() {
        player?.play()
        isPaused = false
    }

    func stop() {
        player?.stop()
        player = nil
        // Resume continuation so the pipeline loop can exit cleanly
        playbackContinuation?.resume(returning: ())
        playbackContinuation = nil
        isSpeaking = false
        isPaused = false
    }

    // MARK: - Internal playback

    private func playAndWait(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { cont in
            do {
                let p = try AVAudioPlayer(data: data)
                self.player = p
                self.playbackContinuation = cont
                p.delegate = self
                p.prepareToPlay()
                if !p.play() {
                    self.playbackContinuation = nil
                    cont.resume(throwing: GoogleTTSError.captureFailed)
                }
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    // MARK: - Google API

    private func synthesize(text: String, rate: Float, languageCode: String) async throws -> Data {
        let url = URL(string: "\(baseURL)/text:synthesize?key=\(apiKey)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = SynthesizeRequest(
            input: .init(text: text),
            voice: .init(languageCode: languageCode, name: voiceName(for: languageCode)),
            // Map our 0.1–1.0 slider to Google's 0.25–4.0 range.
            // Default 0.5 → 1.0 (normal speed).
            audioConfig: .init(audioEncoding: "MP3", speakingRate: Double(rate * 2.0).clamped(0.25, 4.0))
        )
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw GoogleTTSError.invalidResponse }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw GoogleTTSError.apiError(http.statusCode, msg)
        }

        let decoded = try JSONDecoder().decode(SynthesizeResponse.self, from: data)
        guard let audioData = Data(base64Encoded: decoded.audioContent) else {
            throw GoogleTTSError.decodingFailed
        }
        totalCharactersUsed += text.count
        return audioData
    }

    func fetchVoices() async throws -> [GoogleVoice] {
        guard hasAPIKey else { throw GoogleTTSError.noAPIKey }
        let url = URL(string: "\(baseURL)/voices?key=\(apiKey)&languageCode=sk-SK")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let resp = try JSONDecoder().decode(VoicesResponse.self, from: data)
        return resp.voices.sorted { $0.name < $1.name }
    }

    // MARK: - Errors

    enum GoogleTTSError: LocalizedError {
        case noAPIKey, invalidResponse, decodingFailed, captureFailed
        case apiError(Int, String)

        var errorDescription: String? {
            switch self {
            case .noAPIKey:               "Google Cloud API kľúč nie je nastavený."
            case .invalidResponse:        "Neplatná odpoveď servera."
            case .decodingFailed:         "Nepodarilo sa dekódovať audio."
            case .captureFailed:          "Prehrávanie zlyhalo."
            case .apiError(let c, let m): "API chyba \(c): \(m)"
            }
        }
    }
}

// MARK: - AVAudioPlayerDelegate

extension GoogleCloudTTSEngine: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if flag {
                self.playbackContinuation?.resume(returning: ())
            } else {
                self.playbackContinuation?.resume(throwing: GoogleTTSError.captureFailed)
            }
            self.playbackContinuation = nil
        }
    }
}

// MARK: - Text splitting

private extension String {
    func sentences() -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = self
        var result: [String] = []
        tokenizer.enumerateTokens(in: startIndex..<endIndex) { range, _ in
            let s = String(self[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { result.append(s) }
            return true
        }
        return result.isEmpty ? [self] : result
    }
}

// MARK: - Helpers

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(hi, Swift.max(lo, self)) }
}
