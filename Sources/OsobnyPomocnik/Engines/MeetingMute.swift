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
///
/// Window closed (Discord keeps running in the menu bar — the usual case during a call, measured
/// 2026-10-13: 0 windows, no AX tree) → fallback: Discord's own GLOBAL keybind "Toggle Mute",
/// which the user sets to `keybindDisplay` in Discord → Settings → Keybinds. That one only
/// toggles (state unknown), so it's pressed once at start and once at the end — net zero; if the
/// user was already muted, the call hears the dictation (said in the settings caption).
/// ponytail: Discord only; Zoom/Teams/Meet the same way once their control is mapped.
@Observable
@MainActor
final class MeetingMute {
    static let shared = MeetingMute()

    var discordEnabled: Bool {
        didSet { UserDefaults.standard.set(discordEnabled, forKey: "dictation.muteDiscord") }
    }

    private var muteTask: Task<Bool, Never>?
    private var toggledByKey = false

    static let keybindDisplay = "⌃⌥⇧⌘M"

    private init() {
        discordEnabled = UserDefaults.standard.object(forKey: "dictation.muteDiscord") as? Bool ?? true
    }

    func start() {
        guard discordEnabled, muteTask == nil,
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.hnc.Discord").first?.processIdentifier
        else { return }
        if Self.hasWindow(pid: pid) {
            muteTask = Task.detached(priority: .userInitiated) { Self.setMuted(true, pid: pid) }
        } else {
            Self.pressKeybind()
            toggledByKey = true
            AppLogger.log("[MeetingMute] Discord bez okna — stlačená skratka Toggle Mute \(Self.keybindDisplay)")
        }
    }

    /// Same choke point as AudioDucking.restore() — every recording exit path runs it.
    func restore() {
        if toggledByKey {
            toggledByKey = false
            Self.pressKeybind()
            AppLogger.log("[MeetingMute] Discord — skratka Toggle Mute späť")
        }
        guard let task = muteTask else { return }
        muteTask = nil
        Task.detached(priority: .userInitiated) {
            guard await task.value,
                  let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.hnc.Discord").first?.processIdentifier
            else { return }
            _ = Self.setMuted(false, pid: pid)
        }
    }

    nonisolated private static func hasWindow(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        return !children(app, kAXWindowsAttribute).isEmpty
    }

    /// Posted at the HID level so Discord's global-keybind listener sees it like a real key press.
    nonisolated private static func pressKeybind() {
        let m: CGKeyCode = 46   // kVK_ANSI_M
        let flags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: m, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
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
