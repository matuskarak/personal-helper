@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transportType: UInt32 // also decides whether to expect a link-warmup delay (see below)

    /// Identity used for persisting priority order and de-duplicating a device across
    /// reconnections — unlike `uid`, this ignores anything that changes when the *same*
    /// physical device is plugged into a different port.
    ///
    /// Many USB audio devices have no real hardware serial number, so CoreAudio's UID for
    /// them embeds the USB topology instead: `AppleUSBAudioEngine:<Manufacturer>:<Product>:
    /// <serial-or-location>:<streamIndex>`. Reconnecting the exact same mic to a different
    /// port then produces a different `uid`, which showed up as the same device
    /// accumulating multiple permanently-"Nedostupné" ghost entries in the priority list.
    /// Bluetooth (MAC-based) and built-in devices don't have this problem — this only
    /// normalizes the one driver prefix known to cause it.
    ///
    /// Trade-off: two genuinely distinct units of the identical mic model would collapse
    /// into one entry. Accepted deliberately — far rarer than the port-hopping case, and
    /// even then falling back to whichever unit is connected beats an ever-growing ghost list.
    var stableKey: String { Self.stableKey(forUID: uid) }

    /// Pure string form of `stableKey`, usable on a persisted UID string with no live
    /// device to query — needed to migrate/de-duplicate an existing priority list.
    static func stableKey(forUID uid: String) -> String {
        guard uid.hasPrefix("AppleUSBAudioEngine:") else { return uid }
        let parts = uid.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return uid }
        return parts[0...2].joined(separator: ":")
    }

    /// Bluetooth and Continuity mics negotiate the audio link before real samples flow,
    /// delivering zeroed buffers meanwhile — so for those, "chunks are arriving" isn't
    /// enough to call the mic live. Wired/built-in/virtual devices have no such handshake:
    /// chunks arriving at all means it's live, and silence just means nobody spoke yet.
    var needsLinkWarmup: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
            || transportType == kAudioDeviceTransportTypeContinuityCaptureWired
            || transportType == kAudioDeviceTransportTypeContinuityCaptureWireless
    }

    /// True only for a real Bluetooth link — gates the "Inicializujem Bluetooth…" label
    /// so a USB mic never claims to be doing Bluetooth setup.
    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Transport as its original four-char code ('usb ', 'blue', 'bltn'…) for logging.
    var transportFourCC: String {
        let b = [UInt8((transportType >> 24) & 0xff), UInt8((transportType >> 16) & 0xff),
                 UInt8((transportType >> 8) & 0xff), UInt8(transportType & 0xff)]
        return String(bytes: b, encoding: .ascii) ?? "????"
    }
}

/// Enumerates Core Audio input devices and applies a selected one to an AVAudioEngine's input unit.
enum AudioDeviceManager {

    /// Loads the CoreAudio HAL into this process ahead of the first dictation.
    ///
    /// Measured over 191 dictations: opening the mic took a median 8 ms — except on the first
    /// dictation after launch, where it took 0.7–9.7 s (median 7.6 s). The cost is the HAL's
    /// one-time bootstrap in a cold process: connecting to coreaudiod and loading every
    /// installed driver plugin, which on this machine includes third-party ones (SoundSource's
    /// ARK, ParrotAudioPlugin). The first enumeration pays it; every call after is warm.
    ///
    /// ponytail: enumerates devices, deliberately without opening one. Opening would warm the
    /// device path too, but it lights up the orange "mic in use" indicator at launch while
    /// nothing is recording — a worse trade than shaving off the remaining milliseconds.
    /// If the first dictation is still slow, opening + immediately closing is the next step.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            let t0 = Date()
            let devices = inputDevices()
            AppLogger.log("[AudioDeviceManager] HAL warm-up: \(devices.count) vstupných zariadení za \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        }
    }

    static func inputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard status == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs)
        guard status == noErr else { return [] }

        return deviceIDs.compactMap { devID in
            guard hasInputStreams(devID),
                  let name = deviceName(devID),
                  let uid  = deviceUID(devID) else { return nil }
            return AudioInputDevice(id: devID, uid: uid, name: name, transportType: transportType(devID))
        }
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope:    kAudioDevicePropertyScopeInput,
            mElement:  kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        return size > 0
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func transportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &type)
        return type
    }

    private static func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}

// MARK: - DeviceCapture

/// Captures audio directly from a CoreAudio device, bypassing AVAudioEngine and
/// SoundSource's Ark HAL plugin. Use for explicit device selection so SoundSource
/// cannot intercept or deadlock the capture.
final class DeviceCapture: @unchecked Sendable {

    let deviceID: AudioDeviceID
    /// Native input format of the device (Float32 non-interleaved, device sample rate).
    let format: AVAudioFormat
    /// Called on the CoreAudio IO thread with each buffer — must be realtime-safe.
    var onBuffer: (AVAudioPCMBuffer) -> Void = { _ in }

    private var procID: AudioDeviceIOProcID?
    private var context: UnsafeMutableRawPointer?

    private init(deviceID: AudioDeviceID, format: AVAudioFormat) {
        self.deviceID = deviceID
        self.format   = format
    }

    /// Returns nil if the device has no readable input stream format.
    static func make(deviceID: AudioDeviceID) -> DeviceCapture? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope:    kAudioDevicePropertyScopeInput,
            mElement:  kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(deviceID), &addr, 0, nil, &size, &asbd)
        guard status == noErr else {
            AppLogger.log("[DeviceCapture] make(\(deviceID)) — kAudioDevicePropertyStreamFormat failed OSStatus \(status)")
            return nil
        }
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else {
            AppLogger.log("[DeviceCapture] make(\(deviceID)) — AVAudioFormat init failed (sr:\(asbd.mSampleRate) ch:\(asbd.mChannelsPerFrame) fmt:\(asbd.mFormatID))")
            return nil
        }
        AppLogger.log("[DeviceCapture] make(\(deviceID)) — format \(fmt.sampleRate)Hz \(fmt.channelCount)ch ✓")
        return DeviceCapture(deviceID: deviceID, format: fmt)
    }

    /// Starts the IO proc. Set `onBuffer` before calling. Returns false on failure.
    @discardableResult
    func start() -> Bool {
        let retained = Unmanaged.passRetained(self).toOpaque()
        context = retained
        let status = AudioDeviceCreateIOProcID(deviceID, Self.ioProc, retained, &procID)
        guard status == noErr else {
            Unmanaged<DeviceCapture>.fromOpaque(retained).release()
            context = nil
            return false
        }
        guard AudioDeviceStart(deviceID, procID) == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, procID!)
            procID = nil
            Unmanaged<DeviceCapture>.fromOpaque(retained).release()
            context = nil
            return false
        }
        return true
    }

    func stop() {
        if let id = procID {
            AudioDeviceStop(deviceID, id)
            AudioDeviceDestroyIOProcID(deviceID, id)
            procID = nil
        }
        if let ctx = context {
            Unmanaged<DeviceCapture>.fromOpaque(ctx).release()
            context = nil
        }
    }

    // MARK: IO Proc — realtime audio thread, NO AppLogger / Swift runtime allocations beyond AVAudioPCMBuffer

    private static let ioProc: AudioDeviceIOProc = { _, _, inInputData, _, _, _, clientData in
        guard let ptr = clientData else { return noErr }
        let cap   = Unmanaged<DeviceCapture>.fromOpaque(ptr).takeUnretainedValue()
        let list  = inInputData.pointee
        let first = list.mBuffers
        guard let src = first.mData, first.mDataByteSize > 0 else { return noErr }

        let bpf        = cap.format.streamDescription.pointee.mBytesPerFrame
        let frameCount = bpf > 0 ? first.mDataByteSize / bpf : 0
        guard frameCount > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: cap.format, frameCapacity: frameCount) else { return noErr }
        pcm.frameLength = frameCount

        // Copy each channel — non-interleaved: one AudioBuffer per channel in the list.
        if let ch = pcm.floatChannelData {
            withUnsafePointer(to: list.mBuffers) { bufPtr in
                let nBufs = Int(list.mNumberBuffers)
                let nCh   = Int(cap.format.channelCount)
                for i in 0..<min(nBufs, nCh) {
                    let buf = bufPtr[i]
                    if let s = buf.mData { memcpy(ch[i], s, Int(buf.mDataByteSize)) }
                }
            }
        }

        cap.onBuffer(pcm)
        return noErr
    }
}
