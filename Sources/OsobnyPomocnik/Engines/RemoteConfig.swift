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
    private static let cacheKey = "remoteConfig.usersCache.v1"
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

    var smartDictationAllowed: Bool { entitlements.smartDictationEnabled || DeveloperMode.isEnabled }

    private init() {
        accessCode = UserDefaults.standard.string(forKey: Self.codeKey) ?? ""
        loadCached()
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
