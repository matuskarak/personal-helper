import Foundation
import Observation

/// Timestamped log of dictation/reading activity — backs the "Prehľad" usage tab.
/// Separate from the cumulative "total" counters in DictationEngine/GoogleCloudTTSEngine,
/// which only track all-time totals and can't answer "how much today/this week".
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

@Observable
@MainActor
final class UsageStore {
    static let shared = UsageStore()

    private(set) var events: [UsageEvent] = []
    private let defaultsKey = "usage.events.v1"
    private let maxAgeDays = 40 // covers "this month" view even on the 1st, plus buffer

    private init() { load() }

    func logDictation(seconds: Int, text: String, model: String) {
        guard seconds > 0 || !text.isEmpty else { return }
        append(UsageEvent(date: Date(), kind: .dictation, seconds: seconds,
                           words: wordCount(text), chars: text.count, model: model))
    }

    func logReading(_ text: String) {
        guard !text.isEmpty else { return }
        append(UsageEvent(date: Date(), kind: .reading, seconds: 0,
                           words: wordCount(text), chars: text.count, model: ""))
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    private func append(_ event: UsageEvent) {
        events.append(event)
        prune()
        save()
    }

    private func prune() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -maxAgeDays, to: Date()) else { return }
        events.removeAll { $0.date < cutoff }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([UsageEvent].self, from: data) else { return }
        events = decoded
    }

    // MARK: - Aggregation

    struct Summary {
        var dictationSeconds = 0
        var dictationWords   = 0
        var readingWords     = 0
        var readingChars     = 0
    }

    private func summary(for range: DateInterval) -> Summary {
        var s = Summary()
        for e in events where range.contains(e.date) {
            switch e.kind {
            case .dictation: s.dictationSeconds += e.seconds; s.dictationWords += e.words
            case .reading:   s.readingWords += e.words; s.readingChars += e.chars
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
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let cutoff = cal.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        var buckets: [String: DailyModelBucket] = [:]
        for e in events where e.kind == .dictation && e.date >= cutoff {
            let day = cal.startOfDay(for: e.date)
            let key = "\(day.timeIntervalSince1970)_\(e.model)"
            var bucket = buckets[key] ?? DailyModelBucket(day: day, model: e.model, words: 0, seconds: 0)
            bucket.words += e.words
            bucket.seconds += e.seconds
            buckets[key] = bucket
        }
        return buckets.values.sorted { $0.day < $1.day }
    }
}
