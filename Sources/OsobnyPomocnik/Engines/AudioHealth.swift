import CoreAudio
import Foundation

/// Append-only record of everything the audio subsystem does that isn't routine.
///
/// It exists because the wedges are rare, arrive without warning, and were only ever diagnosed
/// after the fact from `log show` — which keeps a few hours at best. On 2026-08-31 the whole
/// tool hung; the cause turned out to be the USB mic dropping off the bus 17 minutes earlier
/// (`removing usbDevice`), a device object torn down mid-open, and coreaudiod spinning at 50%
/// until it stopped answering. None of that was visible in the app's own log.
///
/// Deliberately a SEPARATE file from app.log: app.log gets cleared between test runs, and the
/// whole point of this one is to still be there weeks later when a pattern needs proving.
enum AudioHealth {
    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/OsobnyPomocnik", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("audio-health.log")
    }()

    /// Enumeration slower than this is not normal — a warm HAL answers in single-digit
    /// milliseconds, a cold one in about a second. Anything above this is worth a record.
    static let slowEnumeration: TimeInterval = 3

    private static let queue = DispatchQueue(label: "sk.matuskarak.osobny-pomocnik.audiohealth")
    /// ~200 KB of incidents is months of history; past that the oldest half is dropped.
    private static let maxBytes = 200_000

    static func record(_ event: String) {
        // One diagnostics switch for the whole app (Nastavenia → O aplikácii).
        guard AppLogger.isEnabled else { return }
        let stamp = Self.formatter.string(from: Date())
        AppLogger.log("[AudioHealth] \(event)")
        queue.async {
            let line = "[\(stamp)] \(event)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
            trimIfNeeded()
        }
    }

    private static func trimIfNeeded() {
        guard let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
              size > maxBytes,
              let text = try? String(contentsOf: fileURL, encoding: .utf8)
        else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.suffix(lines.count / 2).joined(separator: "\n")
        try? kept.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    // MARK: - Device list watching

    private static var lastSeen: [AudioDeviceID: String] = [:]
    private static var listening = false

    /// Records every device that appears or disappears, by name.
    ///
    /// This is the signal that mattered: the mic vanishing and coming back four seconds later
    /// is what preceded the hang, and nothing in the app noticed at the time. A device list
    /// that changes wholesale means coreaudiod itself restarted — worth knowing when reading
    /// back a bad afternoon.
    static func startWatchingDevices() {
        guard !listening else { return }
        listening = true
        lastSeen = currentDevices()
        record("sledovanie zariadení spustené — \(lastSeen.count) vstupov: \(lastSeen.values.sorted().joined(separator: ", "))")

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue) { _, _ in
            let now = currentDevices()
            let added   = now.filter { lastSeen[$0.key] == nil }
            let removed = lastSeen.filter { now[$0.key] == nil }
            lastSeen = now
            for (_, name) in removed { record("➖ zariadenie zmizlo: \(name)") }
            for (_, name) in added   { record("➕ zariadenie pribudlo: \(name)") }
        }
    }

    private static func currentDevices() -> [AudioDeviceID: String] {
        Dictionary(AudioDeviceManager.inputDevices().map { ($0.id, $0.name) },
                   uniquingKeysWith: { first, _ in first })
    }
}
