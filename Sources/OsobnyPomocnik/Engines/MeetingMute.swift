import AppKit
import ApplicationServices
import CoreAudio
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
/// Needs the Discord window to exist — open, minimized (⌘M) or on another Space / full screen
/// (via AXMainWindow, see `windows`) all work, verified 2026-10-14.
/// Closed (red ×, Discord keeps running in the menu bar) = no AX tree at all, and the global
/// keybind route is dead too: Discord reads its keybinds from the HID device, so synthetic key
/// events (⌃O posted at HID level, with and without separate modifier events) never reach it
/// (measured 2026-10-14). Then the pill says so instead of failing silently.
/// ponytail: Discord only; Zoom/Teams/Meet the same way once their control is mapped.
@Observable
@MainActor
final class MeetingMute {
    static let shared = MeetingMute()

    var discordEnabled: Bool {
        didSet { UserDefaults.standard.set(discordEnabled, forKey: "dictation.muteDiscord") }
    }

    /// Every Discord action runs here, in order — a restore and the next start (⌘⇧X then ⌘⇧D
    /// 2 s later, 2026-10-14) must never overlap. The two vars below are touched only on it.
    nonisolated private static let queue = DispatchQueue(label: "sk.matuskarak.osobny-pomocnik.meeting-mute")
    nonisolated(unsafe) private static var mutedByUs = false
    nonisolated(unsafe) private static var cachedWindow: AXUIElement?

    private init() {
        discordEnabled = UserDefaults.standard.object(forKey: "dictation.muteDiscord") as? Bool ?? true
    }

    private static func discordPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.hnc.Discord").first?.processIdentifier
    }

    func start() {
        guard discordEnabled else { return }
        guard let pid = Self.discordPID() else { return }   // Discord not running — nothing to do
        Self.queue.async {
            guard !Self.mutedByUs else { return }
            guard Self.hasWindow(pid: pid) else {
                // Discord runs all day; only worth a word when it's actually in a call (mic open).
                let inCall = Self.discordUsesMic()
                AppLogger.log("[MeetingMute] Discord: okno nenájdené (v hovore: \(inCall))")
                if inCall {
                    DispatchQueue.main.async {
                        DictationEngine.shared.showNotice("Discord má zatvorené okno — mikrofón v ňom nestlmím. Okno len minimalizuj (⌘M).", sticky: false)
                    }
                }
                return
            }
            Self.mutedByUs = Self.setMuted(true, pid: pid)
        }
    }

    /// Same choke point as AudioDucking.restore() — every recording exit path (stop, ⌘⇧X, error) runs it.
    func restore() {
        Self.queue.async {
            guard Self.mutedByUs else { return }
            Self.mutedByUs = false
            guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.hnc.Discord").first?.processIdentifier
            else { return }
            _ = Self.setMuted(false, pid: pid)
        }
    }

    nonisolated private static func hasWindow(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        return !windows(app).isEmpty
    }

    /// AXWindows lists only windows on the CURRENT Space — Discord in full screen or on another
    /// desktop returned [] (2026-10-14), yet AXMainWindow/AXFocusedWindow still hand it over.
    nonisolated private static func windows(_ app: AXUIElement) -> [AXUIElement] {
        var result = children(app, kAXWindowsAttribute)
        // A window element stays valid while the window lives — reuse the last one found.
        if let w = cachedWindow, string(w, kAXRoleAttribute) == kAXWindowRole as String { result.append(w) }
        for attr in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            var v: AnyObject?
            guard AXUIElementCopyAttributeValue(app, attr as CFString, &v) == .success, let v,
                  CFGetTypeID(v) == AXUIElementGetTypeID() else { continue }
            let w = v as! AXUIElement
            if !result.contains(where: { CFEqual($0, w) }) { result.append(w) }
        }
        if result.isEmpty { result = remoteTokenWindows(app) }
        return result
    }

    /// Last resort (AltTab's technique): AX elements built from a remote token (pid + element id)
    /// reach windows the public attributes don't list. Private API — fine outside the App Store;
    /// if the symbol is ever gone, dlsym returns nil and this just finds nothing.
    nonisolated private static func remoteTokenWindows(_ app: AXUIElement) -> [AXUIElement] {
        typealias Fn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementCreateWithRemoteToken") else { return [] }
        let create = unsafeBitCast(sym, to: Fn.self)
        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        var found: [AXUIElement] = []
        for id: UInt64 in 0..<2000 {
            var token = Data(count: 20)
            token.withUnsafeMutableBytes { p in
                p.storeBytes(of: pid, toByteOffset: 0, as: pid_t.self)
                p.storeBytes(of: Int32(0), toByteOffset: 4, as: Int32.self)
                p.storeBytes(of: Int32(0x636f636f), toByteOffset: 8, as: Int32.self)   // "coco"
                p.storeBytes(of: id, toByteOffset: 12, as: UInt64.self)
            }
            if let el = create(token as CFData)?.takeRetainedValue(),
               string(el, kAXRoleAttribute) == kAXWindowRole as String { found.append(el) }
        }
        AppLogger.log("[MeetingMute] záložné hľadanie okna: \(found.count)")
        return found
    }

    /// Any Discord process (helpers included) with a running input stream = in a call.
    nonisolated private static func discordUsesMic() -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return false }
        return ids.contains { id in
            var running: UInt32 = 0, bundle: CFString = "" as CFString
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                               mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var s = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &running) == noErr, running != 0 else { return false }
            a.mSelector = kAudioProcessPropertyBundleID
            s = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &bundle) == noErr else { return false }
            return (bundle as String).hasPrefix("com.hnc.Discord")
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
        guard (value != 0) != muted else {   // already in the wanted state — leave it alone
            AppLogger.log("[MeetingMute] Discord už je \(muted ? "stlmený" : "odstlmený") — nič nemením")
            return false
        }
        AXUIElementPerformAction(control, kAXPressAction as CFString)
        // Discord applies the press asynchronously (~0.3–0.8 s) and ignores a second press that
        // comes too soon — read back until it changes, never press again blindly.
        var now = intValue(control).map { $0 != 0 }
        for _ in 0..<15 where now != muted {
            Thread.sleep(forTimeInterval: 0.1)
            now = intValue(control).map { $0 != 0 }
        }
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
        let listed = windows(app)
        for window in listed { if let hit = walk(window, 0) { cachedWindow = window; return hit } }
        // Discord has several windows (a 33 pt strip, overlays…) — finding one of them isn't finding
        // the main one (2026-10-14: "nenájdený" twice). Search everything the token scan reaches.
        for window in remoteTokenWindows(app) where !listed.contains(where: { CFEqual($0, window) }) {
            visited = 0
            if let hit = walk(window, 0) { cachedWindow = window; return hit }
        }
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
