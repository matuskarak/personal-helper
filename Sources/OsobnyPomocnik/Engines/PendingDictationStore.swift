import Foundation
import Observation

/// Recordings whose transcription hasn't succeeded yet — the safety net that makes a failed
/// network request survivable instead of fatal.
///
/// Before this existed, `transcribeBatch()` drained the PCM buffer and then returned "" on any
/// error, so a DNS hiccup destroyed the recording outright: the user's words were gone with no
/// way to get them back. Now the WAV lands on disk *before* the upload is attempted and is only
/// deleted once a transcript actually comes back.
struct PendingDictation: Codable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let mode: String        // TranscriptionMode.rawValue at recording time
    let appName: String
    let bundleID: String
    let seconds: Int

    var displayName: String {
        let time = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
        let app = appName.isEmpty ? "neznáma appka" : appName
        return "\(time) — \(app) (\(seconds)s)"
    }
}

@Observable
@MainActor
final class PendingDictationStore {
    static let shared = PendingDictationStore()

    private(set) var pending: [PendingDictation] = []   // oldest first

    // ponytail: audio only, no screenshot. A recovered recording is retried minutes later at
    // the earliest, by which point the screen it was dictated into is long gone — a Smart
    // rewrite against a stale screenshot is worse than none. Retry returns the raw transcript.
    // Upgrade path if that ever matters: persist capturedScreenshotJPEG next to the WAV.
    private let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OsobnyPomocnik/pending", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Recordings older than this are dropped — audio is bulky (~48 KB/s) and a week-old
    /// dictation nobody retried isn't worth the disk.
    private let maxAge: TimeInterval = 7 * 24 * 3600

    private init() {
        load()
        prune()
    }

    func wavURL(for id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).wav") }
    private func metaURL(for id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).json") }

    /// Writes the recording to disk and returns its handle. Returns nil (and logs) if the write
    /// fails — the caller still attempts the upload, it just has no safety net for that one.
    func save(wav: Data, mode: String, appName: String, bundleID: String, seconds: Int) -> PendingDictation? {
        let item = PendingDictation(id: UUID(), date: Date(), mode: mode,
                                    appName: appName, bundleID: bundleID, seconds: seconds)
        do {
            try wav.write(to: wavURL(for: item.id), options: .atomic)
            try JSONEncoder().encode(item).write(to: metaURL(for: item.id), options: .atomic)
        } catch {
            AppLogger.log("[PendingDictation] ⚠️ nepodarilo sa uložiť nahrávku: \(error)")
            return nil
        }
        pending.append(item)
        AppLogger.log("[PendingDictation] uložená nahrávka \(item.id) (\(wav.count) B, \(seconds)s)")
        return item
    }

    func remove(_ item: PendingDictation) { remove(id: item.id) }

    func remove(id: UUID) {
        try? FileManager.default.removeItem(at: wavURL(for: id))
        try? FileManager.default.removeItem(at: metaURL(for: id))
        pending.removeAll { $0.id == id }
    }

    func removeAll() { pending.forEach { remove($0) } }

    func wav(for item: PendingDictation) -> Data? {
        try? Data(contentsOf: wavURL(for: item.id))
    }

    private func load() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        pending = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let item = try? JSONDecoder().decode(PendingDictation.self, from: data)
                else { return nil }
                // A meta file whose WAV vanished is useless — nothing to retry from.
                return FileManager.default.fileExists(atPath: wavURL(for: item.id).path) ? item : nil
            }
            .sorted { $0.date < $1.date }
        if !pending.isEmpty {
            AppLogger.log("[PendingDictation] načítaných \(pending.count) čakajúcich nahrávok")
        }
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-maxAge)
        pending.filter { $0.date < cutoff }.forEach { remove($0) }
    }
}
