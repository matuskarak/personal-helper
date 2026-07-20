import Foundation
import Observation

// MARK: - Model

/// Maps a frontmost app (by bundle ID, optionally narrowed by window-title keyword
/// for browser-based tools) to rewrite instructions used by Smart diktovanie.
struct AppProfile: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var displayName: String
    var bundleID: String        // empty = generic fallback (matches everything)
    var titleKeyword: String = "" // optional case-insensitive substring match on window title
    var instructions: String
}

// MARK: - Store

@Observable
@MainActor
final class AppProfileStore {
    static let shared = AppProfileStore()

    private static let key = "smart.appProfiles"

    var profiles: [AppProfile] {
        didSet { Self.persist(profiles) }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([AppProfile].self, from: data),
           !decoded.isEmpty {
            profiles = decoded
        } else {
            profiles = Self.defaults
        }
    }

    private static func persist(_ profiles: [AppProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func addBlank() {
        profiles.append(AppProfile(displayName: "Nový profil", bundleID: "", titleKeyword: "", instructions: ""))
    }

    func remove(_ profile: AppProfile) {
        profiles.removeAll { $0.id == profile.id }
    }

    /// Most specific match wins: bundleID + titleKeyword > bundleID only > generic fallback.
    func matchingProfile(bundleID: String?, windowTitle: String?) -> AppProfile {
        let title = (windowTitle ?? "").lowercased()

        if let bundleID,
           let match = profiles.first(where: {
               !$0.bundleID.isEmpty && $0.bundleID == bundleID &&
               !$0.titleKeyword.isEmpty && title.contains($0.titleKeyword.lowercased())
           }) { return match }

        if let bundleID,
           let match = profiles.first(where: { !$0.bundleID.isEmpty && $0.bundleID == bundleID && $0.titleKeyword.isEmpty }) {
            return match
        }

        return profiles.first(where: { $0.bundleID.isEmpty }) ?? Self.defaults[0]
    }

    // MARK: - Defaults

    static let defaults: [AppProfile] = [
        AppProfile(
            displayName: "Generický (fallback)",
            bundleID: "", titleKeyword: "",
            instructions: "Oprav gramatiku, interpunkciu a preklepy v nadiktovanom texte. Zachovaj pôvodný význam a štýl. Vráť LEN opravený text, bez vysvetlení a úvodných fráz."
        ),
        AppProfile(
            displayName: "Slack",
            bundleID: "com.tinyspeck.slackmacgap", titleKeyword: "",
            instructions: "Prepisuješ nadiktovaný text pre Slack správu. Uprav ho na krátky, neformálny chat tón, oprav gramatiku, zachovaj zmysel. Vráť LEN finálny text, bez vysvetlení."
        ),
        AppProfile(
            displayName: "Mail",
            bundleID: "com.apple.mail", titleKeyword: "",
            instructions: "Prepisuješ nadiktovaný text pre email. Uprav na zdvorilý, jasný tón vhodný pre email, oprav gramatiku a interpunkciu, prípadne rozdeľ na odseky. Vráť LEN finálny text."
        ),
        AppProfile(
            displayName: "ChatGPT (Safari)",
            bundleID: "com.apple.Safari", titleKeyword: "ChatGPT",
            instructions: "Prepisuješ nadiktovaný text ako prompt pre AI nástroj. Uprav ho tak, aby bol jasný, štruktúrovaný a presný, vhodný na pochopenie jazykovým modelom. Vráť LEN finálny text."
        ),
        AppProfile(
            displayName: "Claude (Safari)",
            bundleID: "com.apple.Safari", titleKeyword: "Claude",
            instructions: "Prepisuješ nadiktovaný text ako prompt pre AI asistenta. Uprav ho tak, aby bol jasný, štruktúrovaný a presný. Vráť LEN finálny text."
        )
    ]
}
