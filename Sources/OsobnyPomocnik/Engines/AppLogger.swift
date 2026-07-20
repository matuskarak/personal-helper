import Darwin
import Foundation

/// Simple file-based logger — writes alongside console prints so logs survive
/// even when running as a packaged .app (where stdout isn't easily visible).
/// Log file: ~/Library/Logs/OsobnyPomocnik/app.log
///
/// IMPORTANT: never call `log(_:)` from a realtime audio callback (e.g. an
/// AVAudioEngine tap). File I/O there can stall the CoreAudio render thread and
/// has been linked to SwiftUI/AttributeGraph crashes during testing. Only call
/// from @MainActor code paths or cooperative-pool tasks.
enum AppLogger {
    // ponytail: single background serial queue owns the file handle — no lock needed,
    // no open/close per call, no syscall on the caller's thread.
    private static let logQ = DispatchQueue(label: "com.osobny.log", qos: .utility)
    private static var handle: FileHandle?
    private static var pendingBytes = 0
    private static let maxBytes = 1_000_000

    static let logFileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/OsobnyPomocnik", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app.log")
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        print(message)
        // Timestamp on calling thread (DateFormatter.string is thread-safe for read-only use).
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        logQ.async { writeToFile(data) }
    }

    /// Marks the start of a new dictation attempt without discarding earlier
    /// app-lifecycle history (useful when correlating a crash with prior actions).
    static func markSection(_ title: String) {
        log("— \(title) —")
    }

    // Called only from logQ — no locking needed.
    private static func writeToFile(_ data: Data) {
        if handle == nil { openHandle() }
        try? handle?.write(contentsOf: data)
        pendingBytes += data.count
        if pendingBytes > maxBytes { trim() }
    }

    private static func openHandle() {
        let path = logFileURL.path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: logFileURL)
        try? handle?.seekToEnd()
        // Approximate existing file size so trim fires at the right time.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int {
            pendingBytes = size
        }
    }

    private static func trim() {
        try? handle?.close()
        handle = nil
        pendingBytes = 0
        guard let content = try? String(contentsOf: logFileURL, encoding: .utf8) else { return }
        let half = String(content.suffix(content.count / 2))
        try? half.write(to: logFileURL, atomically: true, encoding: .utf8)
        openHandle()
    }

    // MARK: - Crash signal logging

    /// File descriptor kept open for the lifetime of the process so the signal
    /// handler below can write to it without doing any unsafe setup work.
    private static var crashFD: Int32 = -1

    /// Installs handlers for the common fatal signals so a crash leaves a
    /// breadcrumb in app.log right before the process dies. Uses only
    /// async-signal-safe APIs (raw `write`, `StaticString` — no Swift String
    /// allocation) since arbitrary Foundation calls aren't safe inside a
    /// signal handler.
    static func installCrashHandlers() {
        crashFD = open(logFileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard crashFD >= 0 else { return }

        let handler: @convention(c) (Int32) -> Void = { sig in
            let msg: StaticString
            switch sig {
            case SIGSEGV: msg = "💥 CRASH: SIGSEGV (segmentation fault / bad memory access)\n"
            case SIGABRT: msg = "💥 CRASH: SIGABRT (fatal error / assertion failure)\n"
            case SIGILL:  msg = "💥 CRASH: SIGILL (illegal instruction)\n"
            case SIGBUS:  msg = "💥 CRASH: SIGBUS (bus error)\n"
            case SIGFPE:  msg = "💥 CRASH: SIGFPE (floating point exception)\n"
            default:      msg = "💥 CRASH: unknown signal\n"
            }
            msg.withUTF8Buffer { buf in
                _ = write(AppLogger.crashFD, buf.baseAddress, buf.count)
            }
            signal(sig, SIG_DFL)
            raise(sig)
        }

        signal(SIGSEGV, handler)
        signal(SIGABRT, handler)
        signal(SIGILL,  handler)
        signal(SIGBUS,  handler)
        signal(SIGFPE,  handler)
    }
}
