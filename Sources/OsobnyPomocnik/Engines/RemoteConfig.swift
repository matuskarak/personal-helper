import Foundation
import Observation

/// Per-friend remote entitlements — no backend, no passwords. Each friend gets an
/// access code from the developer; entitlements are keyed by that code in users.json
/// (repo root). Anyone without a code (or an unrecognized one) falls back to "default".
///
/// Fetches users.json at launch + hourly; falls back to the last successfully fetched
/// data on failure, so a network hiccup never flips a feature off for someone it was
/// meant to stay on for. Developer mode always bypasses these flags — see
/// `smartDictationAllowed` etc. Edit users.json + push to change anyone's access,
/// no new app build required.
@Observable
@MainActor
final class RemoteConfig {
    static let shared = RemoteConfig()

    private static let url = URL(string: "https://raw.githubusercontent.com/matuskarak/personal-helper/master/users.json")!
    private static let modelsURL = URL(string: "https://raw.githubusercontent.com/matuskarak/personal-helper/master/models.json")!
    private static let cacheKey = "remoteConfig.usersCache.v1"
    private static let modelsCacheKey = "remoteConfig.modelsCache.v1"
    private static let codeKey = "access.code"
    private static let refreshInterval: TimeInterval = 3600

    struct Entitlements: Codable {
        var smartDictationEnabled: Bool = false
    }

    /// The code this install has entered — persisted, editable in Preferences/Onboarding.
    var accessCode: String {
        didSet {
            UserDefaults.standard.set(accessCode, forKey: Self.codeKey)
            resolve()
            Task { await refresh() }
        }
    }

    private var users: [String: Entitlements] = [:]
    private(set) var entitlements = Entitlements()
    /// Transcription models on offer — served remotely so a new model (same API shape as
    /// OpenAI transcriptions or Gemini interactions) reaches users without a new build.
    private(set) var catalog = ModelCatalog.builtin

    var smartDictationAllowed: Bool { entitlements.smartDictationEnabled || DeveloperMode.isEnabled }

    private init() {
        accessCode = UserDefaults.standard.string(forKey: Self.codeKey) ?? ""
        loadCached()
        if let data = UserDefaults.standard.data(forKey: Self.modelsCacheKey) { applyModels(data) }
        resolve()
        Task { await refresh() }
        Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: Self.url)
        } catch {
            AppLogger.log("[RemoteConfig] refresh failed: \(error) — keeping cached entitlements")
            return
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            AppLogger.log("[RemoteConfig] refresh failed: status \((response as? HTTPURLResponse)?.statusCode ?? -1) — keeping cached entitlements")
            return
        }
        apply(data)
        UserDefaults.standard.set(data, forKey: Self.cacheKey)

        // Separate file, separate decoder — a bad price edit must not break entitlements
        // and vice versa. Same fail-open behavior: keep cache/builtin on any failure.
        if let (mData, mResp) = try? await URLSession.shared.data(from: Self.modelsURL),
           (mResp as? HTTPURLResponse)?.statusCode == 200 {
            applyModels(mData)
            UserDefaults.standard.set(mData, forKey: Self.modelsCacheKey)
        }
    }

    private func applyModels(_ data: Data) {
        guard let decoded = try? JSONDecoder().decode(ModelCatalog.self, from: data),
              !decoded.batchModels.isEmpty else { return }
        catalog = decoded
    }

    private func loadCached() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey) else { return }
        apply(data)
    }

    private func apply(_ data: Data) {
        guard let decoded = try? JSONDecoder().decode([String: Entitlements].self, from: data) else { return }
        users = decoded
        resolve()
    }

    private func resolve() {
        let key = accessCode.trimmingCharacters(in: .whitespacesAndNewlines)
        entitlements = users[key] ?? users["default"] ?? Entitlements()
        AppLogger.log("[RemoteConfig] resolved code='\(key.isEmpty ? "(žiadny)" : key)' → smartDictationEnabled=\(entitlements.smartDictationEnabled)")
    }
}

struct ModelInfo: Codable, Identifiable, Hashable {
    var id: String            // API model id, e.g. "gpt-transcribe"
    var provider: String      // "openai" | "gemini" — picks endpoint + key
    var displayName: String
    var usdPerMinute: Double
    var available: Bool
}

struct ModelCatalog: Codable {
    var batchModels: [ModelInfo]
    var eurPerUSD: Double
    var ratesCheckedOn: String

    /// Mirror of today's hardcoded values — offline first launch behaves exactly like before.
    static let builtin = ModelCatalog(
        batchModels: [
            ModelInfo(id: "gpt-transcribe",         provider: "openai", displayName: "gpt-transcribe (rýchly, odporúčaný)", usdPerMinute: 0.0045, available: true),
            ModelInfo(id: "gemini-3.5-transcribe",  provider: "gemini", displayName: "gemini-3.5-transcribe (presný na odborné termíny)", usdPerMinute: 0.005, available: true),
            ModelInfo(id: "gpt-4o-mini-transcribe", provider: "openai", displayName: "gpt-4o-mini-transcribe (najlacnejší)", usdPerMinute: 0.003, available: true),
            ModelInfo(id: "gpt-4o-transcribe",      provider: "openai", displayName: "gpt-4o-transcribe", usdPerMinute: 0.006, available: true),
            ModelInfo(id: "whisper-1",              provider: "openai", displayName: "whisper-1 (starší)", usdPerMinute: 0.006, available: true),
        ],
        eurPerUSD: 0.92,
        ratesCheckedOn: "júl 2026"
    )

    func info(for id: String) -> ModelInfo? { batchModels.first { $0.id == id } }
}
