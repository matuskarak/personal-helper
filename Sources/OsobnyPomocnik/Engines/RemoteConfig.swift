import Foundation
import Observation

/// Remote kill-switch for features not yet ready for everyone (e.g. Smart diktovanie,
/// still untested at scale). Fetches a tiny JSON file at launch + hourly; falls back to
/// the last successfully fetched value on failure, so a network hiccup never flips a
/// feature off for someone it was meant to stay on for.
///
/// Developer mode always bypasses these flags — see `smartDictationAllowed` etc.
/// Edit feature-flags.json in the repo root + push to change behavior for everyone,
/// no new app build required.
@Observable
@MainActor
final class RemoteConfig {
    static let shared = RemoteConfig()

    private static let url = URL(string: "https://raw.githubusercontent.com/matuskarak/personal-helper/master/feature-flags.json")!
    private static let cacheKey = "remoteConfig.cache.v1"
    private static let refreshInterval: TimeInterval = 3600

    private(set) var smartDictationEnabled = false // off by default until tested with the group

    private init() {
        loadCached()
        Task { await refresh() }
        Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    var smartDictationAllowed: Bool { smartDictationEnabled || DeveloperMode.isEnabled }

    func refresh() async {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: Self.url)
        } catch {
            AppLogger.log("[RemoteConfig] refresh failed: \(error) — keeping cached flags")
            return
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            AppLogger.log("[RemoteConfig] refresh failed: status \((response as? HTTPURLResponse)?.statusCode ?? -1) — keeping cached flags")
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
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] else { return }
        if let v = json["smartDictationEnabled"] { smartDictationEnabled = v }
        AppLogger.log("[RemoteConfig] smartDictationEnabled=\(smartDictationEnabled)")
    }
}
