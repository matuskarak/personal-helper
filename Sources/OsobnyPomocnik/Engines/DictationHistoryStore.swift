import Foundation
import Observation

/// Compression A/B test (dev-only, see CLAUDE.md): the same audio uploaded a second time as
/// lossless FLAC to the same model, both requests started at the same moment. `text` is the
/// FLAC transcript (nil when that request failed — `error` says why); `wordDiff` is the word
/// edit distance against the WAV transcript after DictationQualityEngine.normalizeWords.
struct CompressionABResult: Codable {
    let model: String
    let audioSeconds: Double
    let wavBytes: Int
    let flacBytes: Int
    let encodeMs: Int
    let wavLatencyMs: Int
    var flacLatencyMs: Int?
    let text: String?
    let error: String?
    var wordDiff: Int?
}

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
    // TranscriptDiff numbers for (text, shadowText), computed once when the pair is formed
    // (and backfilled once for older pairs) so the Kvalita tab only sums them — diffing ~1,000
    // pairs word by word on every open of the tab took ~0.25 s on the main thread.
    var shadowAgreement: Double?
    var shadowIdentical: Bool?
    // Silence-trim A/B test: the SAME provider/model, but on the untrimmed audio — isolates
    // whether SilenceTrimmer itself lost anything, instead of conflating it with a model
    // difference the way shadowText above does. Only present while dictation.silenceTrimABTest
    // is on and something was actually trimmed (nothing to compare otherwise). Temporary
    // testing aid, not a shipped feature — see CLAUDE.md.
    var trimTestText: String?
    var trimTestSecondsRemoved: Int?
    var compressionTest: CompressionABResult?

    init(id: UUID = UUID(), date: Date, text: String, appName: String = "", bundleID: String = "",
         category: AppCategory = .generic, seconds: Int = 0,
         rewrittenText: String? = nil, metrics: DictationMetrics? = nil, hasScreenshot: Bool = false,
         mode: String? = nil, smart: Bool? = nil, model: String? = nil,
         shadowText: String? = nil, shadowModel: String? = nil,
         shadowAgreement: Double? = nil, shadowIdentical: Bool? = nil,
         trimTestText: String? = nil, trimTestSecondsRemoved: Int? = nil,
         compressionTest: CompressionABResult? = nil) {
        self.id = id; self.date = date; self.text = text
        self.appName = appName; self.bundleID = bundleID; self.category = category
        self.seconds = seconds; self.rewrittenText = rewrittenText; self.metrics = metrics
        self.hasScreenshot = hasScreenshot
        self.mode = mode; self.smart = smart; self.model = model
        self.shadowText = shadowText; self.shadowModel = shadowModel
        self.shadowAgreement = shadowAgreement; self.shadowIdentical = shadowIdentical
        self.trimTestText = trimTestText; self.trimTestSecondsRemoved = trimTestSecondsRemoved
        self.compressionTest = compressionTest
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
        shadowAgreement = try c.decodeIfPresent(Double.self, forKey: .shadowAgreement)
        shadowIdentical = try c.decodeIfPresent(Bool.self, forKey: .shadowIdentical)
        trimTestText           = try c.decodeIfPresent(String.self, forKey: .trimTestText)
        trimTestSecondsRemoved = try c.decodeIfPresent(Int.self, forKey: .trimTestSecondsRemoved)
        compressionTest        = try c.decodeIfPresent(CompressionABResult.self, forKey: .compressionTest)
    }

    /// The per-pair numbers the Kvalita tab aggregates — pure, so it can run off the main thread.
    static func shadowStats(text: String, shadow: String) -> (agreement: Double, identical: Bool) {
        let diff = TranscriptDiff.differences(text, shadow)
        return (TranscriptDiff.agreement(text, shadow), diff.onlyA.isEmpty && diff.onlyB.isEmpty)
    }
}

@Observable
@MainActor
final class DictationHistoryStore {
    static let shared = DictationHistoryStore()

    private(set) var entries: [DictationHistoryEntry] = []  // oldest first
    /// Shadow transcripts that beat their own history entry to the punch — see attachShadow.
    private var parkedShadows: [UUID: (text: String, model: String)] = [:]
    /// Same race, for the silence-trim A/B test — see attachTrimTest.
    private var parkedTrimTests: [UUID: (text: String, secondsRemoved: Int)] = [:]
    /// Same race, for the compression A/B test — see attachCompressionTest.
    private var parkedCompressionTests: [UUID: CompressionABResult] = [:]

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

    // Persistence runs off the main thread: every log/attach* used to re-encode the whole
    // history (~2 MB, ~1,900 entries) and write it synchronously on main. Now save() only
    // marks the store dirty; after `saveDelay` the current entries are snapshotted (a value
    // copy, ~free) and encoded + written atomically on `ioQueue`. Several changes inside the
    // window → one write. Serial queue = writes land in snapshot order, newest wins.
    // Nothing is lost on quit: AppDelegate.applicationWillTerminate calls flush(), which
    // writes synchronously. A crash can lose at most the last `saveDelay` of changes, never
    // corrupt the file (.atomic = temp file + rename).
    private let ioQueue = DispatchQueue(label: "sk.matuskarak.osobny-pomocnik.history-save", qos: .utility)
    private var pendingSave: DispatchWorkItem?
    private let saveDelay: TimeInterval = 0.7

    private init() {
        load()
        backfillShadowStats()
    }

    /// `id` is passed in when the caller needs to reference the entry before it exists —
    /// the shadow transcription finishes on its own schedule and attaches to this id later.
    func log(_ text: String, id: UUID = UUID(), appName: String = "", bundleID: String = "",
             category: AppCategory = .generic, seconds: Int = 0, rewrittenText: String? = nil,
             screenshotJPEG: Data? = nil, mode: String? = nil, smart: Bool? = nil,
             model: String? = nil, silentSeconds: Int = 0, longestSilenceSeconds: Int = 0) {
        guard !text.isEmpty else { return }
        if let screenshotJPEG {
            try? screenshotJPEG.write(to: screenshotURL(for: id), options: .atomic)
        }
        let parkedStats = parkedShadows[id].map { DictationHistoryEntry.shadowStats(text: text, shadow: $0.text) }
        entries.append(DictationHistoryEntry(
            id: id, date: Date(), text: text, appName: appName, bundleID: bundleID,
            category: category, seconds: seconds, rewrittenText: rewrittenText,
            metrics: DictationQualityEngine.analyze(text: text, rewritten: rewrittenText, seconds: seconds),
            hasScreenshot: screenshotJPEG != nil, mode: mode, smart: smart, model: model,
            // A shadow that finished before the primary did is parked here waiting for us.
            shadowText: parkedShadows[id]?.text, shadowModel: parkedShadows[id]?.model,
            shadowAgreement: parkedStats?.agreement, shadowIdentical: parkedStats?.identical,
            trimTestText: parkedTrimTests[id]?.text, trimTestSecondsRemoved: parkedTrimTests[id]?.secondsRemoved,
            compressionTest: parkedCompressionTests[id]
        ))
        parkedShadows[id] = nil
        parkedTrimTests[id] = nil
        parkedCompressionTests[id] = nil
        if let entry = entries.last {
            Telemetry.shared.dictation(seconds: seconds, metrics: entry.metrics, model: model, mode: mode,
                                       outcome: "ok", latencyMs: DictationEngine.shared.lastTranscriptionLatencyMs,
                                       category: category, silentSeconds: silentSeconds,
                                       longestSilenceSeconds: longestSilenceSeconds)
        }
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
        let stats = DictationHistoryEntry.shadowStats(text: entries[index].text, shadow: text)
        entries[index].shadowText = text
        entries[index].shadowModel = model
        entries[index].shadowAgreement = stats.agreement
        entries[index].shadowIdentical = stats.identical
        save()
    }

    /// Same race as attachShadow, for the silence-trim A/B test's untrimmed-audio transcript.
    func attachTrimTest(to id: UUID, text: String, secondsRemoved: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            parkedTrimTests[id] = (text, secondsRemoved)
            return
        }
        entries[index].trimTestText = text
        entries[index].trimTestSecondsRemoved = secondsRemoved
        save()
    }

    /// Same race as attachShadow, for the compression A/B test's FLAC result.
    func attachCompressionTest(to id: UUID, result: CompressionABResult) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            parkedCompressionTests[id] = result
            return
        }
        entries[index].compressionTest = result
        save()
    }

    /// Drops every stored second opinion, keeping the dictations themselves. Called from the
    /// comparison card once the A/B has served its purpose.
    func clearShadows() {
        for index in entries.indices where entries[index].shadowText != nil {
            entries[index].shadowText = nil
            entries[index].shadowModel = nil
            entries[index].shadowAgreement = nil
            entries[index].shadowIdentical = nil
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

    /// Debounced, background write — see `ioQueue`.
    private func save() {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingSave = nil
                let snapshot = self.entries, url = self.fileURL
                self.ioQueue.async { Self.write(snapshot, to: url) }
            }
        }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: item)
    }

    /// Writes any pending change synchronously and waits for an in-flight background write.
    /// Call before the process exits (applicationWillTerminate) or before anything reads
    /// dictation-history.json from disk.
    func flush() {
        if let item = pendingSave {
            item.cancel()
            pendingSave = nil
            let snapshot = entries, url = fileURL
            ioQueue.sync { Self.write(snapshot, to: url) }
        } else {
            ioQueue.sync {}   // let a write already handed to the queue finish
        }
    }

    private nonisolated static func write(_ entries: [DictationHistoryEntry], to url: URL) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// One-time fill of shadowAgreement/shadowIdentical for pairs stored before those fields
    /// existed. Diffing ~1,000 pairs takes a fraction of a second — done off main, then
    /// merged by id (entries may have changed meanwhile) and persisted via save().
    private func backfillShadowStats() {
        let todo = entries.compactMap { e -> (UUID, String, String)? in
            guard let shadow = e.shadowText, e.shadowAgreement == nil else { return nil }
            return (e.id, e.text, shadow)
        }
        guard !todo.isEmpty else { return }
        Task.detached(priority: .utility) {
            var results: [UUID: (agreement: Double, identical: Bool, shadow: String)] = [:]
            for (id, text, shadow) in todo {
                let s = DictationHistoryEntry.shadowStats(text: text, shadow: shadow)
                results[id] = (s.agreement, s.identical, shadow)
            }
            let computed = results
            await MainActor.run {
                let store = DictationHistoryStore.shared
                for index in store.entries.indices {
                    // Skip if the shadow was cleared or replaced while we were computing.
                    guard let r = computed[store.entries[index].id],
                          store.entries[index].shadowText == r.shadow,
                          store.entries[index].shadowAgreement == nil else { continue }
                    store.entries[index].shadowAgreement = r.agreement
                    store.entries[index].shadowIdentical = r.identical
                }
                store.save()
                AppLogger.log("[History] shadow stats backfilled for \(computed.count) pairs")
            }
        }
    }

    private func load() {
        // One-time migration from the old UserDefaults-backed store.
        if let legacy = UserDefaults.standard.data(forKey: "dictation.history.v1"),
           let decoded = try? JSONDecoder().decode([DictationHistoryEntry].self, from: legacy) {
            entries = decoded
            save()
            flush()   // on disk before the only other copy is removed
            UserDefaults.standard.removeObject(forKey: "dictation.history.v1")
            return
        }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([DictationHistoryEntry].self, from: data) else { return }
        entries = decoded
    }
}
