import Foundation
import Observation

/// Local log of every completed dictation — backs the history browser (Preferences
/// tab + menu bar dropdown) and, later, the dictation-quality engine. This is
/// personal data by nature (the user can dictate anything), so it stays local-only,
/// self-prunes, and the user can wipe it on demand.
struct DictationHistoryEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let text: String

    init(date: Date, text: String) {
        self.id = UUID(); self.date = date; self.text = text
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

    func log(_ text: String) {
        guard !text.isEmpty else { return }
        entries.append(DictationHistoryEntry(date: Date(), text: text))
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
