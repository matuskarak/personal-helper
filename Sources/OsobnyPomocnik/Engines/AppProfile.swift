import Foundation
import Observation

// MARK: - Model

/// What kind of target the dictated text lands in. Drives which rubric the
/// dictation-quality engine grades against — a prompt for ChatGPT and a Slack
/// message have genuinely different criteria for "good".
enum AppCategory: String, Codable, CaseIterable, Sendable {
    case aiChat, messaging, email, document, code, generic

    var label: String {
        switch self {
        case .aiChat:    return "AI chat / prompt"
        case .messaging: return "Správy / chat"
        case .email:     return "E-mail"
        case .document:  return "Dokument / text"
        case .code:      return "Kód"
        case .generic:   return "Všeobecné"
        }
    }
}

/// Maps a frontmost app (by bundle ID, optionally narrowed by window-title keyword
/// for browser-based tools) to rewrite instructions used by Smart diktovanie.
struct AppProfile: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var displayName: String
    var bundleID: String        // empty = generic fallback (matches everything)
    var titleKeyword: String = "" // optional case-insensitive substring match on window title
    var instructions: String
    var category: AppCategory = .generic

    init(id: UUID = UUID(), displayName: String, bundleID: String,
         titleKeyword: String = "", instructions: String, category: AppCategory = .generic) {
        self.id = id; self.displayName = displayName; self.bundleID = bundleID
        self.titleKeyword = titleKeyword; self.instructions = instructions; self.category = category
    }

    // ponytail: hand-written decode purely so added fields don't nuke saved profiles.
    // Synthesized Codable throws on a missing key even when the property has a default,
    // and AppProfileStore.init falls back to `defaults` on any decode failure — i.e.
    // shipping a new field with synthesized Codable silently wipes the user's profiles.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id           = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        displayName  = try c.decode(String.self, forKey: .displayName)
        bundleID     = try c.decode(String.self, forKey: .bundleID)
        titleKeyword = try c.decodeIfPresent(String.self, forKey: .titleKeyword) ?? ""
        instructions = try c.decode(String.self, forKey: .instructions)
        category     = try c.decodeIfPresent(AppCategory.self, forKey: .category) ?? .generic
    }
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

    private static let categoryMigrationKey = "smart.appProfiles.categoryMigrated"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([AppProfile].self, from: data),
           !decoded.isEmpty {
            profiles = Self.migrateCategories(decoded)
        } else {
            profiles = Self.defaults
        }
    }

    /// Profiles saved before `category` existed all decode as `.generic`, which would leave
    /// the shipped ChatGPT/Claude profiles graded by the wrong rubric until hand-fixed.
    /// Adopt the category from the matching shipped default — once only, so a later
    /// deliberate "generic" choice isn't overwritten on every launch.
    private static func migrateCategories(_ decoded: [AppProfile]) -> [AppProfile] {
        guard !UserDefaults.standard.bool(forKey: categoryMigrationKey) else { return decoded }
        UserDefaults.standard.set(true, forKey: categoryMigrationKey)

        var migrated = decoded
        var changed = false
        for i in migrated.indices where migrated[i].category == .generic {
            guard let match = defaults.first(where: {
                $0.bundleID == migrated[i].bundleID && $0.titleKeyword == migrated[i].titleKeyword
            }), match.category != .generic else { continue }
            migrated[i].category = match.category
            changed = true
        }
        if changed { persist(migrated) }
        return migrated
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
            instructions: "Oprav gramatiku, interpunkciu a preklepy v nadiktovanom texte. Zachovaj pôvodný význam a štýl. Vráť LEN opravený text, bez vysvetlení a úvodných fráz.",
            category: .generic
        ),
        AppProfile(
            displayName: "Slack",
            bundleID: "com.tinyspeck.slackmacgap", titleKeyword: "",
            instructions: "Prepisuješ nadiktovaný text pre Slack správu. Uprav ho na krátky, neformálny chat tón, oprav gramatiku, zachovaj zmysel. Vráť LEN finálny text, bez vysvetlení.",
            category: .messaging
        ),
        AppProfile(
            displayName: "Mail",
            bundleID: "com.apple.mail", titleKeyword: "",
            instructions: "Prepisuješ nadiktovaný text pre email. Uprav na zdvorilý, jasný tón vhodný pre email, oprav gramatiku a interpunkciu, prípadne rozdeľ na odseky. Vráť LEN finálny text.",
            category: .email
        ),
        AppProfile(
            displayName: "ChatGPT (Safari)",
            bundleID: "com.apple.Safari", titleKeyword: "ChatGPT",
            instructions: "Prepisuješ nadiktovaný text ako prompt pre AI nástroj. Uprav ho tak, aby bol jasný, štruktúrovaný a presný, vhodný na pochopenie jazykovým modelom. Vráť LEN finálny text.",
            category: .aiChat
        ),
        AppProfile(
            displayName: "Claude (Safari)",
            bundleID: "com.apple.Safari", titleKeyword: "Claude",
            instructions: "Prepisuješ nadiktovaný text ako prompt pre AI asistenta. Uprav ho tak, aby bol jasný, štruktúrovaný a presný. Vráť LEN finálny text.",
            category: .aiChat
        )
    ]
}
