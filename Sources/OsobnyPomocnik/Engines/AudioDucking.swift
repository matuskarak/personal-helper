import Cocoa
import CoreAudio
import AudioToolbox
import Observation

/// Optional feature (off by default): lower or pause other system audio while dictating, so
/// background music/video doesn't bleed into the mic or distract mid-sentence. Toggle lives in
/// Nastavenia → Diktovanie → Ostatné zvuky.
///
/// - `.duck` — set the default output device's volume to `duckLevel` (0 = mute) and restore the
///   exact original value afterward. Fully reliable, works regardless of what's playing.
/// - `.pause` (rewritten 2026-10-10 — the MediaRemote "is anything playing" check is locked on
///   macOS 26 and always said no, so pause never did anything). Who plays is read from CoreAudio's
///   process objects (public since macOS 14.2): every process with a running output stream.
///   Spotify / Hudba / TV are paused and resumed by AppleScript, which also reports their real
///   state. Everything else (browser video, IPTV players) gets one Play/Pause media key — it
///   goes to the system's "now playing" app — and is verified: if the key started something
///   that was silent instead, it is undone at once. Running output ≠ audible (Discord, Beeper
///   keep a silent stream open), so the key is only sent when such an app is outputting.
///
/// `skipWithHeadphones`: with headphones the mic doesn't hear the music — nothing to do.
@Observable
@MainActor
final class AudioDucking {
    static let shared = AudioDucking()

    enum Mode: String { case duck, pause }

    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "dictation.duckAudioEnabled") }
    }
    var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "dictation.duckAudioMode") }
    }
    /// Target system volume while ducking, 0...1. 0 = úplné stlmenie.
    var duckLevel: Float {
        didSet { UserDefaults.standard.set(duckLevel, forKey: "dictation.duckAudioLevel") }
    }
    var skipWithHeadphones: Bool {
        didSet { UserDefaults.standard.set(skipWithHeadphones, forKey: "dictation.duckSkipHeadphones") }
    }

    private var savedVolume: Float?
    private var savedDeviceID: AudioDeviceID?

    /// The async pause (osascript + key verification) — restore() waits for it, so a very short
    /// dictation can't resume before the pause has even happened.
    private var pauseTask: Task<PauseState, Never>?
    struct PauseState { var scripted: [String] = []; var sentKey = false }

    private static let crashRecoveryKey = "dictation.duckAudioCrashRecovery"

    private init() {
        enabled   = UserDefaults.standard.bool(forKey: "dictation.duckAudioEnabled")
        mode      = Mode(rawValue: UserDefaults.standard.string(forKey: "dictation.duckAudioMode") ?? "") ?? .duck
        duckLevel = UserDefaults.standard.object(forKey: "dictation.duckAudioLevel") as? Float ?? 0.15
        skipWithHeadphones = UserDefaults.standard.object(forKey: "dictation.duckSkipHeadphones") as? Bool ?? true
    }

    func startDucking() {
        guard enabled else { return }
        if skipWithHeadphones, Self.headphonesConnected() {
            AppLogger.log("[AudioDucking] ⏭ slúchadlá — nestišujem")
            return
        }
        switch mode {
        case .duck:  duckVolume()
        case .pause: pauseTask = Task { await Self.pausePlaying() }
        }
    }

    /// Called from DictationEngine.stopAudio() — the single choke point every recording exit
    /// path (success, cancel, error) runs through. Must be idempotent: most calls duck nothing
    /// and this is a no-op.
    func restore() {
        if let task = pauseTask {
            pauseTask = nil
            Task { await Self.resume(await task.value) }
        }
        if let vol = savedVolume, let dev = savedDeviceID {
            setVolume(vol, device: dev)
            AppLogger.log("[AudioDucking] 🔊 restore — device=\(dev) to=\(Int(vol * 100))%")
            savedVolume = nil
            savedDeviceID = nil
            UserDefaults.standard.removeObject(forKey: Self.crashRecoveryKey)
        }
    }

    // MARK: - Duck (volume)

    private func duckVolume() {
        guard let device = Self.defaultOutputDevice() else {
            AppLogger.log("[AudioDucking] ⏭ duck skip — no default output device")
            return
        }
        guard Self.isVolumeSettable(device: device), let current = Self.volume(device: device) else {
            AppLogger.log("[AudioDucking] ⏭ duck skip — volume not settable on this device")
            return
        }
        savedVolume = current
        savedDeviceID = device
        UserDefaults.standard.set(current, forKey: Self.crashRecoveryKey)
        setVolume(duckLevel, device: device)
        AppLogger.log("[AudioDucking] 🔇 duck — device=\(device) from=\(Int(current * 100))% to=\(Int(duckLevel * 100))%")
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    // "VirtualMainVolume" is the AudioHardwareService (AudioToolbox) property — the one System
    // Settings' own volume slider and the media keys use. Unlike the plain AudioObject
    // VolumeScalar, it works on built-in speakers too, which typically expose no single
    // settable "master" element at the AudioObject level (confirmed on this machine: the plain
    // AudioObject call reported not-settable on built-in output).
    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope:    kAudioDevicePropertyScopeOutput,
            mElement:  kAudioObjectPropertyElementMain)
    }

    private static func isVolumeSettable(device: AudioDeviceID) -> Bool {
        var address = volumeAddress()
        var settable: DarwinBoolean = false
        return AudioHardwareServiceIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func volume(device: AudioDeviceID) -> Float? {
        var address = volumeAddress()
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioHardwareServiceGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private func setVolume(_ value: Float, device: AudioDeviceID) {
        var address = Self.volumeAddress()
        var v = value
        AudioHardwareServiceSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    // MARK: - Headphones

    /// Default output is Bluetooth / USB, or the built-in jack with headphones plugged in.
    /// ponytail: a Bluetooth/USB speaker counts as headphones too — CoreAudio can't tell them
    /// apart; the toggle is there for that case.
    static func headphonesConnected() -> Bool {
        guard let dev = defaultOutputDevice() else { return false }
        var transport: UInt32 = 0
        guard get(dev, kAudioDevicePropertyTransportType, &transport) else { return false }
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeUSB:
            return true
        case kAudioDeviceTransportTypeBuiltIn:
            var source: UInt32 = 0
            return get(dev, kAudioDevicePropertyDataSource, &source, scope: kAudioDevicePropertyScopeOutput)
                && source == 0x6864706E // 'hdpn' — headphone jack
        default:
            return false
        }
    }

    nonisolated private static func get<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &address, 0, nil, &size, &value) == noErr
    }

    // MARK: - Pause

    /// Apps whose real play state AppleScript knows — paused/resumed exactly, no guessing.
    nonisolated private static let alwaysOpen = ["com.hnc.Discord", "com.automattic.beeper", "com.tinyspeck.slackmacgap",
                                                 "com.microsoft.teams", "us.zoom.xos", "com.apple.FaceTime", "net.whatsapp", "ru.keepcoder.Telegram"]
    nonisolated private static let scriptable = ["com.spotify.client", "com.apple.Music", "com.apple.TV"]

    /// Bundle IDs of processes with a running output stream right now (not us). Helper
    /// processes keep their own ID (com.google.Chrome.helper) — fine, they only count.
    nonisolated static func outputtingApps() -> Set<String> {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        var result = Set<String>()
        for id in ids {
            var running: UInt32 = 0, pid: pid_t = 0
            var bundle: CFString = "" as CFString
            guard get(id, kAudioProcessPropertyIsRunningOutput, &running), running != 0,
                  get(id, kAudioProcessPropertyPID, &pid), pid != me,
                  get(id, kAudioProcessPropertyBundleID, &bundle), !(bundle as String).isEmpty else { continue }
            result.insert(bundle as String)
        }
        return result
    }

    nonisolated private static func pausePlaying() async -> PauseState {
        var state = PauseState()
        let before = outputtingApps()
        // `tell application id` would LAUNCH a closed app — only ask running ones.
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for id in scriptable where running.contains(id) {
            if await osascript("tell application id \"\(id)\" to if player state is playing then\npause\nreturn \"paused\"\nend if") == "paused" {
                state.scripted.append(id)
            }
        }
        // Chat/call apps hold a silent output stream open all the time — they'd trigger the key
        // on every dictation (and the key could then start a paused video). Measured 2026-10-10:
        // Discord, Beeper. ponytail: prefix list, extend when another one shows up in the log.
        let others = before.subtracting(scriptable).filter { id in !alwaysOpen.contains { id.hasPrefix($0) } }
        if !others.isEmpty {
            sendMediaPlayPauseKey()
            try? await Task.sleep(for: .milliseconds(700))
            // The key goes to the "now playing" app, which may be a paused one — then it STARTED
            // playback instead. Anything newly outputting, or a player we just paused, = undo.
            let started = outputtingApps().subtracting(before)
            var resumedScripted = false
            for id in state.scripted where await osascript("tell application id \"\(id)\" to return player state as text") == "playing" {
                resumedScripted = true
            }
            if started.isEmpty && !resumedScripted {
                state.sentKey = true
            } else {
                sendMediaPlayPauseKey()
                AppLogger.log("[AudioDucking] ↩️ kláves spustil iné prehrávanie (\(started.sorted().joined(separator: ", "))) — vrátené")
            }
        }
        AppLogger.log("[AudioDucking] ⏸ pause — výstup: \(before.sorted().joined(separator: ", ")) | AppleScript: \(state.scripted.joined(separator: ", ")) | kláves: \(state.sentKey)")
        return state
    }

    nonisolated private static func resume(_ state: PauseState) async {
        // Key first: once a scripted player plays again it becomes "now playing" and the key would hit it.
        if state.sentKey { sendMediaPlayPauseKey() }
        for id in state.scripted { _ = await osascript("tell application id \"\(id)\" to play") }
        if state.sentKey || !state.scripted.isEmpty {
            AppLogger.log("[AudioDucking] ▶️ resume — AppleScript: \(state.scripted.joined(separator: ", ")) | kláves: \(state.sentKey)")
        }
    }

    /// osascript off the main thread (NSAppleScript would block it). macOS asks once per player
    /// for Automation permission ("Ozvena chce ovládať Spotify"); denied → empty result, no-op.
    nonisolated private static func osascript(_ source: String) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", source]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: ""); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    // ponytail: NX_KEYTYPE_PLAY (from <IOKit/hidsystem/ev_keymap.h>, not bridged to Swift) is
    // the well-known raw value 16 every "simulate the media key" snippet hardcodes — no header
    // to import it from cleanly.
    nonisolated private static let nxKeyTypePlay: Int32 = 16

    nonisolated private static func sendMediaPlayPauseKey() {
        for keyDown in [true, false] {
            let flags = keyDown ? 0xa00 : 0xb00
            let data1 = (Int(nxKeyTypePlay) << 16) | flags
            guard let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1
            ) else { continue }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Crash recovery

    /// If the app force-quit/crashed mid-dictation, `restore()` never ran and the system stayed
    /// ducked. Called once at launch (AppDelegate) — cheap insurance against a permanently quiet
    /// Mac after a crash.
    static func recoverStaleDuckIfNeeded() {
        guard let volume = UserDefaults.standard.object(forKey: crashRecoveryKey) as? Float,
              let device = defaultOutputDevice() else { return }
        var address = volumeAddress()
        var v = volume
        AudioHardwareServiceSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        UserDefaults.standard.removeObject(forKey: crashRecoveryKey)
        AppLogger.log("[AudioDucking] 🔧 recovered stale ducked volume after previous crash → \(Int(volume * 100))%")
    }
}
