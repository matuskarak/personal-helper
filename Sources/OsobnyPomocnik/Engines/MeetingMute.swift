import AppKit
import ApplicationServices
import Observation

/// Mutes the user's microphone in Discord while dictating and unmutes it afterwards — so the
/// people in a call don't hear the dictation (user 2026-10-13).
///
/// macOS has no per-app microphone mute (muting the device would mute us too; a virtual audio
/// driver like Krisp/SoundSource is weeks of work), so this drives the app's own Mute control
/// through Accessibility. Discord's user panel exposes it as an AXCheckBox/AXSwitch "Mute" whose
/// value is the real state (0/1) — so we SET it, never blindly toggle: already muted → untouched,
/// and afterwards we unmute only what we muted. Electron builds its AX tree only after
/// `AXManualAccessibility` is set, hence the short retry on first use.
/// ponytail: Discord only; Zoom/Teams/Meet go into `targets` the same way once their control is mapped.
@Observable
@MainActor
final class MeetingMute {
    static let shared = MeetingMute()

    var discordEnabled: Bool {
        didSet { UserDefaults.standard.set(discordEnabled, forKey: "dictation.muteDiscord") }
    }

    private var muteTask: Task<Bool, Never>?

    private init() {
        discordEnabled = UserDefaults.standard.object(forKey: "dictation.muteDiscord") as? Bool ?? true
    }

    func start() {
        guard discordEnabled, muteTask == nil,
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.hnc.Discord").first?.processIdentifier
        else { return }
        muteTask = Task.detached(priority: .userInitiated) { Self.setMuted(true, pid: pid) }
    }

    /// Same choke point as AudioDucking.restore() — every recording exit path runs it.
    func restore() {
        guard let task = muteTask else { return }
        muteTask = nil
        Task.detached(priority: .userInitiated) {
            guard await task.value,
                  let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.hnc.Discord").first?.processIdentifier
            else { return }
            _ = Self.setMuted(false, pid: pid)
        }
    }

    /// true = we changed the state (so the caller owns undoing it).
    nonisolated private static func setMuted(_ muted: Bool, pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var control: AXUIElement?
        for attempt in 0..<5 {
            control = findMuteSwitch(app)
            if control != nil { break }
            if attempt < 4 { Thread.sleep(forTimeInterval: 0.25) }
        }
        guard let control, let value = intValue(control) else {
            AppLogger.log("[MeetingMute] Discord: prepínač Mute nenájdený (okno zatvorené?)")
            return false
        }
        guard (value != 0) != muted else { return false }   // already in the wanted state
        AXUIElementPerformAction(control, kAXPressAction as CFString)
        let now = intValue(control).map { $0 != 0 }
        AppLogger.log("[MeetingMute] Discord \(muted ? "🔇 stlmený" : "🎙 odstlmený") (overené: \(now.map { $0 == muted ? "áno" : "NIE" } ?? "?"))")
        return now == muted
    }

    nonisolated private static func findMuteSwitch(_ app: AXUIElement) -> AXUIElement? {
        var visited = 0
        func walk(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
            visited += 1
            guard depth < 40, visited < 5000 else { return nil }
            if (string(e, kAXRoleAttribute) == kAXCheckBoxRole as String),
               ["mute", "unmute", "ztlumit", "zrušit ztlumení"].contains((string(e, kAXDescriptionAttribute) ?? "").lowercased()) {
                return e
            }
            for child in children(e) { if let hit = walk(child, depth + 1) { return hit } }
            return nil
        }
        for window in children(app, kAXWindowsAttribute) { if let hit = walk(window, 0) { return hit } }
        return nil
    }

    nonisolated private static func children(_ e: AXUIElement, _ attr: String = kAXChildrenAttribute) -> [AXUIElement] {
        var v: AnyObject?
        AXUIElementCopyAttributeValue(e, attr as CFString, &v)
        return v as? [AXUIElement] ?? []
    }

    nonisolated private static func string(_ e: AXUIElement, _ attr: String) -> String? {
        var v: AnyObject?
        AXUIElementCopyAttributeValue(e, attr as CFString, &v)
        return v as? String
    }

    nonisolated private static func intValue(_ e: AXUIElement) -> Int? {
        var v: AnyObject?
        AXUIElementCopyAttributeValue(e, kAXValueAttribute as CFString, &v)
        return (v as? NSNumber)?.intValue
    }
}
