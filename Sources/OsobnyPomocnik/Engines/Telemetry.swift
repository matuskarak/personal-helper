import AppKit
import Foundation
import Observation

/// Anonymous usage statistics — what the dictation engine needs to get better, nothing a
/// person could be recognised by. Per event: the metrics DictationQualityEngine already
/// computes (WPM, filler words, sentence length…), duration, model, outcome, latency and the
/// *category* of the target app. Never the transcript, keywords, app or window names, keys.
///
/// Install ID is a random UUID minted on first launch — not tied to a name or email, but it
/// lets a tester ask "delete my rows". Timestamps are rounded to the hour.
///
/// Sink is an n8n webhook feeding a Data Table (no backend of our own yet). Events queue
/// locally and flush in one POST; a failed flush keeps the queue for next time.
@Observable
@MainActor
final class Telemetry {
    static let shared = Telemetry()

    // ponytail: public repo, so this token is public too — it only lets someone spam rows,
    // not read them. Rotate here + in the n8n webhook filter if it gets abused.
    private static let endpoint = URL(string: "https://n8n.pixeled.sk/webhook/osobny-pomocnik-telemetry")!
    private static let token = "op-alfa-9f3kq2"
    private static let maxQueued = 500

    struct Event: Codable {
        var event: String            // "dictation" | "read" | "insertFromMemory" | "launch"
        var ts: String               // ISO hour, e.g. 2026-09-02T13:00
        var seconds = 0
        var words = 0
        var wpm = 0
        var fillerCount = 0
        var fillers = ""             // JSON {"proste":3} — dictionary words, not transcript
        var avgSentenceWords = 0
        var repeatedStarts = 0
        var model = ""
        var mode = ""
        var outcome = ""             // ok | empty | failed | cancelled
        var latencyMs = 0
        var category = ""            // AppCategory rawValue, never the app name
    }

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "telemetry.enabled") }
    }
    let installID: String
    private var queue: [Event]
    private var flushTask: Task<Void, Never>?

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: "telemetry.enabled") as? Bool ?? true
        if let id = UserDefaults.standard.string(forKey: "telemetry.installID") {
            installID = id
        } else {
            installID = UUID().uuidString
            UserDefaults.standard.set(installID, forKey: "telemetry.installID")
        }
        queue = (UserDefaults.standard.data(forKey: "telemetry.queue"))
            .flatMap { try? JSONDecoder().decode([Event].self, from: $0) } ?? []
    }

    // MARK: - Recording

    /// One row per finished dictation; `outcome` says how it ended.
    func dictation(seconds: Int, metrics: DictationMetrics?, model: String?, mode: String?,
                   outcome: String, latencyMs: Int, category: AppCategory) {
        var e = Event(event: "dictation", ts: Self.hourStamp())
        e.seconds = seconds
        if let m = metrics {
            e.words = m.wordCount; e.wpm = m.wordsPerMinute; e.fillerCount = m.fillerCount
            e.avgSentenceWords = m.avgSentenceWords; e.repeatedStarts = m.repeatedSentenceStarts
            e.fillers = (try? JSONEncoder().encode(m.fillers)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        e.model = model ?? ""; e.mode = mode ?? ""; e.outcome = outcome
        e.latencyMs = latencyMs; e.category = category.rawValue
        record(e)
    }

    /// Feature use without payload — "how do people actually use the app".
    func feature(_ name: String) {
        record(Event(event: name, ts: Self.hourStamp()))
    }

    private func record(_ e: Event) {
        guard isEnabled else { return }
        queue.append(e)
        if queue.count > Self.maxQueued { queue.removeFirst(queue.count - Self.maxQueued) }
        persist()
        // Debounced: a burst of events (dictation + its feature taps) goes out as one POST.
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(queue), forKey: "telemetry.queue")
    }

    // MARK: - Sending

    func flush() async {
        guard isEnabled, !queue.isEmpty else { return }
        let batch = queue
        let envelope: [String: Any] = [
            "installID": installID,
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "macos": {
                let v = ProcessInfo.processInfo.operatingSystemVersion
                return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            }(),
            "events": batch.map { e -> [String: Any] in
                (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(e))) as? [String: Any] ?? [:]
            }
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: envelope) else { return }
        var req = URLRequest(url: Self.endpoint, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.token, forHTTPHeaderField: "x-op-token")
        req.httpBody = body
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0) else {
                AppLogger.log("[Telemetry] odoslanie zlyhalo: status \((resp as? HTTPURLResponse)?.statusCode ?? -1) — \(batch.count) udalostí ostáva vo fronte")
                return
            }
            // Drop exactly what we sent; anything recorded meanwhile stays.
            queue.removeFirst(min(batch.count, queue.count))
            persist()
            AppLogger.log("[Telemetry] odoslaných \(batch.count) anonymných udalostí")
        } catch {
            AppLogger.log("[Telemetry] odoslanie zlyhalo: \(error.localizedDescription) — skúsim neskôr")
        }
    }

    /// Wipes everything queued locally (used when the user switches statistics off).
    func clearQueue() {
        queue.removeAll()
        persist()
    }

    private static func hourStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Bratislava")
        f.dateFormat = "yyyy-MM-dd'T'HH:00"
        return f.string(from: Date())
    }
}
