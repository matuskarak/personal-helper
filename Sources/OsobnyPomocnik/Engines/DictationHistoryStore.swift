import Foundation
import Observation

/// Local log of every completed dictation — backs the history browser (Preferences
/// tab + menu bar dropdown) and, later, the dictation-quality engine. This is
/// personal data by nature (the user can dictate anything), so it stays local-only,
/// self-prunes, and the user can wipe it on demand.
struct DictationHistoryEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let text: String              // raw transcript, as spoken
    // Context + metrics, all added later — absent on entries logged before this shipped.
    let appName: String
    let bundleID: String
    let category: AppCategory
    let seconds: Int
    let rewrittenText: String?    // Smart diktovanie output, when it ran
    let metrics: DictationMetrics?

    init(date: Date, text: String, appName: String = "", bundleID: String = "",
         category: AppCategory = .generic, seconds: Int = 0,
         rewrittenText: String? = nil, metrics: DictationMetrics? = nil) {
        self.id = UUID(); self.date = date; self.text = text
        self.appName = appName; self.bundleID = bundleID; self.category = category
        self.seconds = seconds; self.rewrittenText = rewrittenText; self.metrics = metrics
    }

    // ponytail: hand-written decode so the added fields don't destroy existing history.
    // Synthesized Codable throws on a missing key even with a default value, and load()
    // bails to an empty array on any failure — which the next save() would then persist.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decode(UUID.self, forKey: .id)
        date          = try c.decode(Date.self, forKey: .date)
        text          = try c.decode(String.self, forKey: .text)
        appName       = try c.decodeIfPresent(String.self, forKey: .appName) ?? ""
        bundleID      = try c.decodeIfPresent(String.self, forKey: .bundleID) ?? ""
        category      = try c.decodeIfPresent(AppCategory.self, forKey: .category) ?? .generic
        seconds       = try c.decodeIfPresent(Int.self, forKey: .seconds) ?? 0
        rewrittenText = try c.decodeIfPresent(String.self, forKey: .rewrittenText)
        metrics       = try c.decodeIfPresent(DictationMetrics.self, forKey: .metrics)
    }
}

@Observable
@MainActor
final class DictationHistoryStore {
    static let shared = DictationHistoryStore()

    private(set) var entries: [DictationHistoryEntry] = []  // oldest first
    private let defaultsKey = "dictation.history.v1"
    // ponytail: fixed caps, not user-configurable — this is a personal-data store,
    // keep the retention policy simple and predictable rather than another setting.
    private let maxAgeDays = 30
    private let maxEntries = 200

    private init() { load() }

    func log(_ text: String, appName: String = "", bundleID: String = "",
             category: AppCategory = .generic, seconds: Int = 0, rewrittenText: String? = nil) {
        guard !text.isEmpty else { return }
        entries.append(DictationHistoryEntry(
            date: Date(), text: text, appName: appName, bundleID: bundleID,
            category: category, seconds: seconds, rewrittenText: rewrittenText,
            metrics: DictationQualityEngine.analyze(text: text, rewritten: rewrittenText, seconds: seconds)
        ))
        prune()
        save()
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clearAll() {
        entries = []
        save()
    }

    private func prune() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -maxAgeDays, to: Date()) else { return }
        entries.removeAll { $0.date < cutoff }
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([DictationHistoryEntry].self, from: data) else { return }
        entries = decoded
    }
}
