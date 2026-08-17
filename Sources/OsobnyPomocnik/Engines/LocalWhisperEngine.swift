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

    private(set) var status: Status = .notLoaded
    private var whisperKit: WhisperKit?

    /// `NaiveNeuron/whisper-large-v3-turbo-sk` isn't published as a ready-made CoreML repo
    /// yet — it needs conversion via whisperkittools first (see CLAUDE.md). Until that's
    /// done, default to the stock multilingual large-v3-turbo from Argmax's own repo, which
    /// WhisperKit downloads automatically. Swap `modelRepo`/`model` once the SK conversion
    /// is available, to compare fine-tuned vs stock on the same test harness.
    // WhisperKit matches this as a substring against folder names in the Argmax CoreML repo
    // (e.g. "openai_whisper-large-v3-v20240930_turbo") — "large-v3-turbo" doesn't actually
    // occur as a substring there (there's a "-v20240930" date tag spliced in between), which
    // is why the plain name 404s. This is the exact folder-name fragment instead.
    var modelVariant = "large-v3-v20240930_turbo"
    var modelRepo: String?

    private init() {}

    func ensureLoaded() async {
        if case .loaded = status, whisperKit != nil { return }
        status = .downloading(progress: 0)
        do {
            let config = WhisperKitConfig(
                model: modelVariant,
                modelRepo: modelRepo,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: true
            )
            whisperKit = try await WhisperKit(config)
            status = .loaded
            AppLogger.log("[LocalWhisperEngine] model loaded — variant=\(modelVariant) repo=\(modelRepo ?? "default")")
        } catch {
            status = .failed(error.localizedDescription)
            AppLogger.log("[LocalWhisperEngine] ⚠️ load failed: \(error)")
        }
    }

    struct TranscribeOutcome {
        var text: String
        var seconds: Double
    }

    func transcribe(wavURL: URL) async throws -> TranscribeOutcome {
        await ensureLoaded()
        guard let whisperKit else { throw LocalWhisperError.notLoaded }
        let t0 = Date()
        var options = DecodingOptions()
        options.language = "sk"
        options.detectLanguage = false
        let results = try await whisperKit.transcribe(audioPath: wavURL.path, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscribeOutcome(text: text, seconds: Date().timeIntervalSince(t0))
    }

    enum LocalWhisperError: LocalizedError {
        case notLoaded
        var errorDescription: String? { "Lokálny model sa nepodarilo načítať." }
    }
}
