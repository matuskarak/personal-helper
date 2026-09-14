import Cocoa
import CoreAudio
import AudioToolbox
import Observation

/// Optional feature (off by default): lower or pause other system audio while dictating, so
/// background music/video doesn't bleed into the mic or distract mid-sentence. Toggle lives in
/// Nastavenia → Diktovanie, right next to the shadow-compare card.
///
/// Two independent mechanisms, picked by `mode`:
/// - `.duck` — set the default output device's volume to `duckLevel` (0 covers "mute completely",
///   no separate toggle needed) and restore the exact original value afterward. Fully reliable,
///   works regardless of what's playing.
/// - `.pause` — actually pause playback via a simulated media key, which the user asked for
///   because a quiet-but-audible background track can still derail a sentence. macOS has no
///   public API to pause an arbitrary app, so this uses the private MediaRemote framework to
///   check whether anything is playing before ever touching the play/pause key — see
///   `isSomethingPlaying` for why that check is mandatory, not optional.
///
///   Measured 2026-09-12: on this machine (macOS 26.5, Spotify actively playing),
///   `MRMediaRemoteGetNowPlayingInfo` came back with an EMPTY info dict — a known lockdown of
///   this private API for processes without Apple's internal `com.apple.private.mediaremote`
///   entitlement on recent macOS versions, not a bug here. The safe fallback (treat "can't tell"
///   as "not playing", never send the key) is working as designed, but the practical result is
///   that `.pause` may currently do nothing on modern macOS even with real audio playing. `.duck`
///   doesn't depend on this API at all and is unaffected — it's the mode to point users at.
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

    private var savedVolume: Float?
    private var savedDeviceID: AudioDeviceID?

    // Guards the race where restore() runs before the async "is anything playing?" check
    // answers (very short dictations) — bumping it makes a late answer a no-op instead of
    // sending a pause key after we've already moved on and possibly re-armed for next time.
    private var pauseGeneration = 0
    private var didSendPauseKey = false

    private static let crashRecoveryKey = "dictation.duckAudioCrashRecovery"

    private init() {
        enabled   = UserDefaults.standard.bool(forKey: "dictation.duckAudioEnabled")
        mode      = Mode(rawValue: UserDefaults.standard.string(forKey: "dictation.duckAudioMode") ?? "") ?? .duck
        duckLevel = UserDefaults.standard.object(forKey: "dictation.duckAudioLevel") as? Float ?? 0.15
    }

    func startDucking() {
        guard enabled else { return }
        switch mode {
        case .duck:  duckVolume()
        case .pause: attemptPause()
        }
    }

    /// Called from DictationEngine.stopAudio() — the single choke point every recording exit
    /// path (success, cancel, error) runs through. Must be idempotent: most calls duck nothing
    /// and this is a no-op.
    func restore() {
        pauseGeneration += 1
        if didSendPauseKey {
            sendMediaPlayPauseKey()
            didSendPauseKey = false
            AppLogger.log("[AudioDucking] ▶️ resume key sent")
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

    // MARK: - Pause (simulated media key)

    private func attemptPause() {
        pauseGeneration += 1
        let myGeneration = pauseGeneration
        Self.isSomethingPlaying { [weak self] playing in
            Task { @MainActor in
                guard let self, self.pauseGeneration == myGeneration else { return }
                guard playing else {
                    AppLogger.log("[AudioDucking] ⏭ pause skip — nothing detected as playing")
                    return
                }
                self.sendMediaPlayPauseKey()
                self.didSendPauseKey = true
                AppLogger.log("[AudioDucking] ⏸ pause key sent")
            }
        }
    }

    // ponytail: NX_KEYTYPE_PLAY (from <IOKit/hidsystem/ev_keymap.h>, not bridged to Swift) is
    // the well-known raw value 16 every "simulate the media key" snippet hardcodes — no header
    // to import it from cleanly.
    private static let nxKeyTypePlay: Int32 = 16

    private func sendMediaPlayPauseKey() {
        for keyDown in [true, false] {
            let flags = keyDown ? 0xa00 : 0xb00
            let data1 = (Int(Self.nxKeyTypePlay) << 16) | flags
            guard let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1
            ) else { continue }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// MediaRemote.framework is private/undocumented (dlopen only, no header, no API guarantee
    /// across macOS versions). Every failure path calls back `false` — a missing/renamed symbol
    /// must never fall through to blindly toggling play/pause, since that would START playback
    /// that wasn't happening, the opposite of what this feature is for.
    private static func isSomethingPlaying(_ completion: @escaping @Sendable (Bool) -> Void) {
        typealias GetNowPlayingInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, URL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework") as CFURL),
              let pointer = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString)
        else {
            completion(false)
            return
        }
        let getNowPlayingInfo = unsafeBitCast(pointer, to: GetNowPlayingInfoFn.self)
        getNowPlayingInfo(DispatchQueue.main) { info in
            let rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
            completion(rate > 0)
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
