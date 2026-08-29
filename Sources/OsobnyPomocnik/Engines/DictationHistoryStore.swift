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
    let hasScreenshot: Bool       // true → a JPEG sits at DictationHistoryStore.screenshotURL(for: id)
    let mode: String?             // TranscriptionMode.rawValue ("realtime"/"batch"); nil on old entries
    let smart: Bool?              // Smart stop requested (even if the rewrite then fell back to raw)
    let model: String?            // transcription model actually used, e.g. "gemini-3.5-transcribe"
    // Shadow comparison: the same audio transcribed a second time by the OTHER provider, for
    // A/B-ing accuracy on identical input. Only present while that setting is on, and both
    // fields are wiped together by clearShadows().
    var shadowText: String?
    var shadowModel: String?

    init(id: UUID = UUID(), date: Date, text: String, appName: String = "", bundleID: String = "",
         category: AppCategory = .generic, seconds: Int = 0,
         rewrittenText: String? = nil, metrics: DictationMetrics? = nil, hasScreenshot: Bool = false,
         mode: String? = nil, smart: Bool? = nil, model: String? = nil,
         shadowText: String? = nil, shadowModel: String? = nil) {
        self.id = id; self.date = date; self.text = text
        self.appName = appName; self.bundleID = bundleID; self.category = category
        self.seconds = seconds; self.rewrittenText = rewrittenText; self.metrics = metrics
        self.hasScreenshot = hasScreenshot
        self.mode = mode; self.smart = smart; self.model = model
        self.shadowText = shadowText; self.shadowModel = shadowModel
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
        hasScreenshot = try c.decodeIfPresent(Bool.self, forKey: .hasScreenshot) ?? false
        mode          = try c.decodeIfPresent(String.self, forKey: .mode)
        smart         = try c.decodeIfPresent(Bool.self, forKey: .smart)
        model         = try c.decodeIfPresent(String.self, forKey: .model)
        shadowText    = try c.decodeIfPresent(String.self, forKey: .shadowText)
        shadowModel   = try c.decodeIfPresent(String.self, forKey: .shadowModel)
    }
}

@Observable
@MainActor
final class DictationHistoryStore {
    static let shared = DictationHistoryStore()

    private(set) var entries: [DictationHistoryEntry] = []  // oldest first
    /// Shadow transcripts that beat their own history entry to the punch — see attachShadow.
    private var parkedShadows: [UUID: (text: String, model: String)] = [:]

    // ponytail: measured ~755 bytes/entry (150KB / 200 entries) before this change.
    // Uncapped storage was requested to build up a real dataset for the quality-analysis
    // engine — 20k entries is still only ~15MB on disk, a non-issue for a JSON file.
    // Upgrade path if it ever grows past that: paginate/archive older entries instead of
    // just deleting them.
    private let safetyCeiling = 20_000

    // Moved off UserDefaults (a .plist meant for small settings, loaded fully into memory
    // at every launch) onto its own file now that there's no small fixed cap keeping it tiny.
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OsobnyPomocnik", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dictation-history.json")
    }()

    // Screenshots are opt-in debug data for tuning Smart diktovanie — kept as loose files
    // next to the JSON, not inline in it, so the (much bigger) images don't get re-encoded
    // on every single save(). Lifecycle is tied 1:1 to the owning entry: deleted whenever
    // the entry is (prune/delete/clearAll), never separately capped.
    private let screenshotsDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OsobnyPomocnik/screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func screenshotURL(for id: UUID) -> URL { screenshotsDir.appendingPathComponent("\(id.uuidString).jpg") }

    private init() { load() }

    /// `id` is passed in when the caller needs to reference the entry before it exists —
    /// the shadow transcription finishes on its own schedule and attaches to this id later.
    func log(_ text: String, id: UUID = UUID(), appName: String = "", bundleID: String = "",
             category: AppCategory = .generic, seconds: Int = 0, rewrittenText: String? = nil,
             screenshotJPEG: Data? = nil, mode: String? = nil, smart: Bool? = nil,
             model: String? = nil) {
        guard !text.isEmpty else { return }
        if let screenshotJPEG {
            try? screenshotJPEG.write(to: screenshotURL(for: id), options: .atomic)
        }
        entries.append(DictationHistoryEntry(
            id: id, date: Date(), text: text, appName: appName, bundleID: bundleID,
            category: category, seconds: seconds, rewrittenText: rewrittenText,
            metrics: DictationQualityEngine.analyze(text: text, rewritten: rewrittenText, seconds: seconds),
            hasScreenshot: screenshotJPEG != nil, mode: mode, smart: smart, model: model,
            // A shadow that finished before the primary did is parked here waiting for us.
            shadowText: parkedShadows[id]?.text, shadowModel: parkedShadows[id]?.model
        ))
        parkedShadows[id] = nil
        if entries.count > safetyCeiling {
            let overflow = entries.prefix(entries.count - safetyCeiling)
            overflow.forEach { if $0.hasScreenshot { try? FileManager.default.removeItem(at: screenshotURL(for: $0.id)) } }
            entries.removeFirst(entries.count - safetyCeiling)
        }
        save()
    }

    /// Second opinion for `id`. Usually arrives after the entry exists; if the shadow won the
    /// race it's parked until log() creates the entry, which happens within a second or two.
    func attachShadow(to id: UUID, text: String, model: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            parkedShadows[id] = (text, model)
            return
        }
        entries[index].shadowText = text
        entries[index].shadowModel = model
        save()
    }

    /// Drops every stored second opinion, keeping the dictations themselves. Called from the
    /// comparison card once the A/B has served its purpose.
    func clearShadows() {
        for index in entries.indices where entries[index].shadowText != nil {
            entries[index].shadowText = nil
            entries[index].shadowModel = nil
        }
        parkedShadows.removeAll()
        save()
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: screenshotURL(for: id))
        entries.removeAll { $0.id == id }
        save()
    }

    func clearAll() {
        entries.forEach { if $0.hasScreenshot { try? FileManager.default.removeItem(at: screenshotURL(for: $0.id)) } }
        entries = []
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        // One-time migration from the old UserDefaults-backed store.
        if let legacy = UserDefaults.standard.data(forKey: "dictation.history.v1"),
           let decoded = try? JSONDecoder().decode([DictationHistoryEntry].self, from: legacy) {
            entries = decoded
            save()
            UserDefaults.standard.removeObject(forKey: "dictation.history.v1")
            return
        }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([DictationHistoryEntry].self, from: data) else { return }
        entries = decoded
    }
}
