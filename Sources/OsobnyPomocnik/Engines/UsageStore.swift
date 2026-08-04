import Foundation
import Observation

/// One logged dictation/reading action — only used transiently (log call → aggregated into
/// a DailyBucket) and to decode the pre-aggregation data still sitting under the old
/// UserDefaults key for one-time migration. Never persisted directly anymore.
struct UsageEvent: Codable {
    enum Kind: String, Codable { case dictation, reading }
    let date: Date
    let kind: Kind
    let seconds: Int   // actual recording time (dictation only, 0 for reading)
    let words: Int
    let chars: Int
    let model: String  // transcription model used (dictation only, "" for reading)

    init(date: Date, kind: Kind, seconds: Int, words: Int, chars: Int, model: String) {
        self.date = date; self.kind = kind; self.seconds = seconds
        self.words = words; self.chars = chars; self.model = model
    }

    // Custom decode so events logged before `model` existed don't wipe the whole store.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date    = try c.decode(Date.self, forKey: .date)
        kind    = try c.decode(Kind.self, forKey: .kind)
        seconds = try c.decode(Int.self, forKey: .seconds)
        words   = try c.decode(Int.self, forKey: .words)
        chars   = try c.decode(Int.self, forKey: .chars)
        model   = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
    }
}

/// One day × kind × model of activity — the actual persisted shape. Logging aggregates into
/// this at write time instead of keeping one row per action: a year of raw per-action events
/// could reach tens of thousands of rows, which UserDefaults (loaded whole into memory at
/// launch, rewritten whole on every change) isn't meant to hold. Every current consumer
/// (Summary, DailyModelBucket) only ever sums words/seconds/chars per day, so aggregating
/// here loses no information — see UsageStore.swift's read path.
struct DailyBucket: Codable {
    let day: Date
    let kind: UsageEvent.Kind
    let model: String
    var seconds = 0
    var words = 0
    var chars = 0
}

@Observable
@MainActor
final class UsageStore {
    static let shared = UsageStore()

    private(set) var dailyBuckets: [DailyBucket] = []
    private let bucketsKey = "usage.dailyBuckets.v1"
    private let legacyEventsKey = "usage.events.v1"
    private let migrationFlagKey = "usage.migratedToBuckets"
    // ~13 months: covers the "1 year" view plus a buffer, same reasoning as the old 40-day
    // "covers this month even on the 1st" comment, just scaled up for the longer view.
    // Public so the Prehľad tab's custom date-range picker can clamp to what's actually stored.
    static let maxAgeDays = 400
    private let maxAgeDays = UsageStore.maxAgeDays

    private init() {
        load()
        migrateLegacyEventsIfNeeded()
    }

    func logDictation(seconds: Int, text: String, model: String) {
        guard seconds > 0 || !text.isEmpty else { return }
        addToBucket(kind: .dictation, model: model, seconds: seconds, words: wordCount(text), chars: text.count)
    }

    func logReading(_ text: String) {
        guard !text.isEmpty else { return }
        addToBucket(kind: .reading, model: "", seconds: 0, words: wordCount(text), chars: text.count)
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    private func addToBucket(kind: UsageEvent.Kind, model: String, seconds: Int, words: Int, chars: Int) {
        let day = Calendar.current.startOfDay(for: Date())
        if let i = dailyBuckets.firstIndex(where: { $0.day == day && $0.kind == kind && $0.model == model }) {
            dailyBuckets[i].seconds += seconds
            dailyBuckets[i].words   += words
            dailyBuckets[i].chars   += chars
        } else {
            dailyBuckets.append(DailyBucket(day: day, kind: kind, model: model,
                                             seconds: seconds, words: words, chars: chars))
        }
        prune()
        save()
    }

    private func prune() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -maxAgeDays, to: Date()) else { return }
        dailyBuckets.removeAll { $0.day < cutoff }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(dailyBuckets) else { return }
        UserDefaults.standard.set(data, forKey: bucketsKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: bucketsKey),
              let decoded = try? JSONDecoder().decode([DailyBucket].self, from: data) else { return }
        dailyBuckets = decoded
    }

    /// One-time: aggregate whatever's left under the pre-aggregation raw-event key into daily
    /// buckets. The old key is deliberately never deleted — leaving a few stale KB behind is
    /// free, and it means a bug here can never lose data that's still sitting on disk.
    private func migrateLegacyEventsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migrationFlagKey) else { return }
        UserDefaults.standard.set(true, forKey: migrationFlagKey)
        guard let data = UserDefaults.standard.data(forKey: legacyEventsKey),
              let events = try? JSONDecoder().decode([UsageEvent].self, from: data),
              !events.isEmpty else { return }

        let cal = Calendar.current
        var byKey: [String: DailyBucket] = [:]
        for e in events {
            let day = cal.startOfDay(for: e.date)
            let key = "\(day.timeIntervalSince1970)_\(e.kind.rawValue)_\(e.model)"
            var bucket = byKey[key] ?? DailyBucket(day: day, kind: e.kind, model: e.model)
            bucket.seconds += e.seconds
            bucket.words   += e.words
            bucket.chars   += e.chars
            byKey[key] = bucket
        }
        // Merge with anything already in dailyBuckets (shouldn't normally overlap, since this
        // only runs once, but merge rather than overwrite in case load() already ran).
        for (_, legacy) in byKey {
            if let i = dailyBuckets.firstIndex(where: { $0.day == legacy.day && $0.kind == legacy.kind && $0.model == legacy.model }) {
                dailyBuckets[i].seconds += legacy.seconds
                dailyBuckets[i].words   += legacy.words
                dailyBuckets[i].chars   += legacy.chars
            } else {
                dailyBuckets.append(legacy)
            }
        }
        prune()
        save()
        AppLogger.log("[UsageStore] Migrated \(events.count) legacy events into \(byKey.count) daily buckets")
    }

    // MARK: - Aggregation

    struct Summary {
        var dictationSeconds = 0
        var dictationWords   = 0
        var readingWords     = 0
        var readingChars     = 0
    }

    /// Estimated time saved versus doing it by hand: dictation compares actual recording
    /// time against a 40 wpm typing baseline; reading compares a 120 wpm manual-reading
    /// baseline against 180 wpm listening (hence words / 360).
    /// Lives here rather than in a view so the Prehľad tab and the menu bar can't drift apart.
    static func savedTimeText(_ s: Summary) -> String {
        let dictationSavedMin = max(0, Double(s.dictationWords) / 40.0 - Double(s.dictationSeconds) / 60.0)
        let readingSavedMin   = Double(s.readingWords) / 360.0
        let totalMin = dictationSavedMin + readingSavedMin
        if totalMin < 1  { return String(format: "%.0f s", totalMin * 60) }
        if totalMin < 60 { return String(format: "%.0f min", totalMin) }
        return String(format: "%.1f h", totalMin / 60)
    }

    private func summary(for range: DateInterval) -> Summary {
        var s = Summary()
        for b in dailyBuckets where range.contains(b.day) {
            switch b.kind {
            case .dictation: s.dictationSeconds += b.seconds; s.dictationWords += b.words
            case .reading:   s.readingWords += b.words; s.readingChars += b.chars
            }
        }
        return s
    }

    var today: Summary {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? Date()
        return summary(for: DateInterval(start: start, end: end))
    }

    /// Week starts Monday — ISO8601 calendar's weekOfYear is Monday-first by definition.
    var thisWeek: Summary {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = .current
        let comps = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        guard let start = iso.date(from: comps),
              let end = iso.date(byAdding: .day, value: 7, to: start) else { return Summary() }
        return summary(for: DateInterval(start: start, end: end))
    }

    var thisMonth: Summary {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: Date())
        guard let start = cal.date(from: comps),
              let end = cal.date(byAdding: .month, value: 1, to: start) else { return Summary() }
        return summary(for: DateInterval(start: start, end: end))
    }

    // MARK: - Chart data

    struct DailyModelBucket: Identifiable {
        let id = UUID()
        let day: Date
        let model: String
        var words: Int
        var seconds: Int
    }

    /// Dictation activity for the last `days` days, bucketed per day × model — feeds the trend chart.
    func dictationDailyByModel(days: Int) -> [DailyModelBucket] {
        let today = Calendar.current.startOfDay(for: Date())
        guard let from = Calendar.current.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        return dictationDailyByModel(from: from, to: Date())
    }

    /// Same, but for an explicit range — backs the custom date-range picker. `days:` above is
    /// now a thin wrapper around this so there's one source of truth for the aggregation.
    func dictationDailyByModel(from: Date, to: Date) -> [DailyModelBucket] {
        let cal = Calendar.current
        let fromDay = cal.startOfDay(for: from)
        let toDay = cal.startOfDay(for: to)
        var merged: [String: DailyModelBucket] = [:]
        for b in dailyBuckets where b.kind == .dictation && b.day >= fromDay && b.day <= toDay {
            let key = "\(b.day.timeIntervalSince1970)_\(b.model)"
            var bucket = merged[key] ?? DailyModelBucket(day: b.day, model: b.model, words: 0, seconds: 0)
            bucket.words += b.words
            bucket.seconds += b.seconds
            merged[key] = bucket
        }
        return merged.values.sorted { $0.day < $1.day }
    }
}
