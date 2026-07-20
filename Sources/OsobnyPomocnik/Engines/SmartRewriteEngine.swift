import AppKit
import Foundation
import Observation

/// Rewrites a raw dictation transcript using screenshot + app context, optimized
/// for the target app (Slack tone, email tone, AI-prompt clarity, etc.) via
/// OpenAI's vision-capable Chat Completions API.
@Observable
@MainActor
final class SmartRewriteEngine {
    static let shared = SmartRewriteEngine()

    var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "smart.model") }
    }

    private init() {
        self.model = UserDefaults.standard.string(forKey: "smart.model") ?? "gpt-4o-mini"
    }

    func rewrite(
        transcript: String,
        screenshot: CGImage?,
        profile: AppProfile,
        apiKey: String
    ) async throws -> String {
        var content: [[String: Any]] = [
            ["type": "text", "text": "Nadiktovaný text:\n\(transcript)"]
        ]
        if let screenshot, let b64 = screenshot.jpegBase64() {
            content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)"]])
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": profile.instructions],
                ["role": "user", "content": content]
            ],
            "max_tokens": 1000
        ]

        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw SmartRewriteError.invalidResponse }
        guard http.statusCode == 200 else {
            throw SmartRewriteError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "unknown")
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let text = message["content"] as? String
        else { throw SmartRewriteError.invalidResponse }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum SmartRewriteError: LocalizedError {
        case invalidResponse
        case apiError(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:        "Neplatná odpoveď servera."
            case .apiError(let c, let m): "API chyba \(c): \(m)"
            }
        }
    }
}

// MARK: - CGImage → JPEG base64

private extension CGImage {
    func jpegBase64(quality: CGFloat = 0.6) -> String? {
        let rep = NSBitmapImageRep(cgImage: self)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else { return nil }
        return data.base64EncodedString()
    }
}
