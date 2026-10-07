import Foundation

/// Request/response shaping for Google's Interactions API, kept apart from DictationEngine so
/// the two fiddly bits — what we send and how we read the answer back — can be exercised by
/// scripts/check-gemini-transcription.sh without dragging the whole audio stack into a compile.
/// The networking itself stays in the engine, next to the retry and pending-recording logic
/// that both providers share.
enum GeminiTranscription {
    static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!

    /// Audio goes inline as base64 rather than through the Files API — a separate upload call
    /// would double the round-trips on the one path we spent the most effort shortening. The
    /// price is Google's 20 MB request ceiling; at our 24 kHz PCM16 (~48 KB/s) plus base64's
    /// +33% that caps a dictation at roughly 5 minutes. If longer recordings ever matter, the
    /// Files API two-step is the upgrade path.
    static let maxInlineBase64Chars = 19_000_000

    static func requestBody(base64WAV: String, model: String, keywords: [String]) throws -> Data {
        var config: [String: Any] = [
            "language_codes": ["sk-SK"],
            // "smart" would strip fillers and reformat — that's the Smart engine's job here,
            // and a pre-cleaned transcript can't be compared against OpenAI's raw one.
            "mode": ["type": "verbatim"]
        ]
        // The reason this integration exists: OpenAI takes vocabulary hints as a free-text
        // `prompt` the model may ignore, Google takes a real list. Docs cap it at 1000 terms
        // but recommend ~100 — ours is a hand-curated 30, so no truncation logic.
        if !keywords.isEmpty { config["custom_vocabulary"] = keywords }

        return try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": [["type": "audio", "data": base64WAV, "mime_type": "audio/wav"]],
            "generation_config": ["transcription_config": config]
        ])
    }

    /// Pulls the transcript out of an Interactions response.
    ///
    /// `output_text` is the SDK's convenience accessor and may or may not be in the raw JSON,
    /// so fall back to walking `steps[].content[]`. Only each content item's own `text` is
    /// read — `annotations` holds one entry per word, and folding those in would return the
    /// whole transcript a second time, word by word.
    ///
    /// Returns `""` for a completed interaction that carries no text at all: Gemini answers
    /// silence with `status: completed` and zero output tokens, which is an answer ("no speech
    /// here"), not a failure. Treating it as malformed cost three retries and a 12-second wait
    /// before telling the user the transcription had failed, which it hadn't.
    /// `nil` is reserved for a response we genuinely can't read — that one is worth retrying.
    static func transcript(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let direct = json["output_text"] as? String { return direct }
        if let steps = json["steps"] as? [[String: Any]] {
            return steps
                .compactMap { $0["content"] as? [[String: Any]] }
                .flatMap { $0 }
                .compactMap { $0["text"] as? String }
                .joined()
        }
        // No output section at all, but the envelope is a real interaction — empty transcript.
        if json["status"] is String, json["id"] is String { return "" }
        return nil
    }
}
