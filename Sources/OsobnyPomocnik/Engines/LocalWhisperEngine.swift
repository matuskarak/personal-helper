import Foundation
import WhisperKit

/// test/local-whisper-sk ONLY — see CLAUDE.md. Wraps WhisperKit to transcribe a WAV file
/// fully on-device, for side-by-side comparison against the existing cloud transcription
/// path (DictationEngine's gpt-transcribe / gpt-live-transcribe). Not wired into the real
/// dictation flow — this is a standalone accuracy test, see LocalModelTestEngine.
@MainActor
final class LocalWhisperEngine {
    static let shared = LocalWhisperEngine()

    enum Status: Equatable {
        case notLoaded
        case downloading(progress: Double)
        case loaded
        case failed(String)
    }

    enum Source: String, CaseIterable, Identifiable {
        case stock = "Stock large-v3-turbo"
        case slovakFineTuned = "SK fine-tuned (NaiveNeuron)"
        var id: String { rawValue }
    }

    private(set) var status: Status = .notLoaded
    private var whisperKit: WhisperKit?
    private var loadedSource: Source?

    var source: Source = .stock {
        didSet {
            guard source != oldValue else { return }
            whisperKit = nil
            loadedSource = nil
            status = .notLoaded
        }
    }

    // WhisperKit matches this as a substring against folder names in the Argmax CoreML repo
    // (e.g. "openai_whisper-large-v3-v20240930_turbo") — "large-v3-turbo" doesn't actually
    // occur as a substring there (there's a "-v20240930" date tag spliced in between), which
    // is why the plain name 404s. This is the exact folder-name fragment instead.
    private let stockModelVariant = "large-v3-v20240930_turbo"

    // Converted locally via whisperkittools from NaiveNeuron/whisper-large-v3-turbo-sk (not
    // published as a ready CoreML repo) — see CLAUDE.md for how this folder was produced.
    private let skModelFolder = "\(NSHomeDirectory())/Documents/whisperkit-models-sk/NaiveNeuron_whisper-large-v3-turbo-sk"

    private init() {}

    func ensureLoaded() async {
        if case .loaded = status, whisperKit != nil, loadedSource == source { return }
        status = .downloading(progress: 0)
        do {
            let config: WhisperKitConfig
            switch source {
            case .stock:
                config = WhisperKitConfig(
                    model: stockModelVariant,
                    verbose: false, logLevel: .error,
                    prewarm: true, load: true, download: true
                )
            case .slovakFineTuned:
                guard FileManager.default.fileExists(atPath: skModelFolder) else {
                    throw LocalWhisperError.skModelMissing
                }
                config = WhisperKitConfig(
                    modelFolder: skModelFolder,
                    verbose: false, logLevel: .error,
                    prewarm: true, load: true, download: false
                )
            }
            whisperKit = try await WhisperKit(config)
            loadedSource = source
            status = .loaded
            AppLogger.log("[LocalWhisperEngine] model loaded — source=\(source.rawValue)")
        } catch {
            status = .failed(error.localizedDescription)
            AppLogger.log("[LocalWhisperEngine] ⚠️ load failed (\(source.rawValue)): \(error)")
        }
    }

    struct TranscribeOutcome {
        var text: String
        var seconds: Double
    }

    /// - Parameter promptKeywords: same free-text vocabulary hints the cloud gpt-live-transcribe
    ///   path gets (default keywords + matched App profile's) — encoded into Whisper's
    ///   `initial_prompt` mechanism (`promptTokens`) so garbled technical/foreign terms have a
    ///   chance of being recognized correctly instead of guessed at with zero context.
    func transcribe(wavURL: URL, promptKeywords: [String] = []) async throws -> TranscribeOutcome {
        await ensureLoaded()
        guard let whisperKit else { throw LocalWhisperError.notLoaded }
        let t0 = Date()
        var options = DecodingOptions()
        options.language = "sk"
        options.detectLanguage = false
        if !promptKeywords.isEmpty, let tokenizer = whisperKit.tokenizer {
            options.promptTokens = tokenizer.encode(text: promptKeywords.joined(separator: ", "))
            options.usePrefillPrompt = true
        }
        let results = try await whisperKit.transcribe(audioPath: wavURL.path, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscribeOutcome(text: text, seconds: Date().timeIntervalSince(t0))
    }

    enum LocalWhisperError: LocalizedError {
        case notLoaded
        case skModelMissing
        var errorDescription: String? {
            switch self {
            case .notLoaded:     "Lokálny model sa nepodarilo načítať."
            case .skModelMissing: "SK model nie je na disku — spusti konverziu cez whisperkittools (viď CLAUDE.md)."
            }
        }
    }
}
