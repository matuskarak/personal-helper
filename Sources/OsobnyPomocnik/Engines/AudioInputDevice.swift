@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transportType: UInt32 // kept for diagnostics/logging only — not used to block selection
}

/// Enumerates Core Audio input devices and applies a selected one to an AVAudioEngine's input unit.
enum AudioDeviceManager {

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

    /// Sets the system-wide default input device. Works cooperatively with SoundSource
    /// (unlike AudioUnitSetProperty which bypasses it and causes HAL lock deadlocks).
    @discardableResult
    static func setSystemDefaultInput(_ device: AudioInputDevice) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var deviceID = device.id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID
        )
        if status != noErr {
            AppLogger.log("[AudioDeviceManager] Failed to set system default input '\(device.name)' (OSStatus \(status))")
        }
        return status == noErr
    }

    /// Returns the current system default input device ID.
    static func systemDefaultInputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : nil
    }

    /// Routes the AVAudioEngine's input node to use the given Core Audio device via
    /// AudioUnitSetProperty. NOTE: this bypasses SoundSource and can deadlock against
    /// its Ark HAL plugin — prefer setSystemDefaultInput when SoundSource may be active.
    @discardableResult
    static func applyInputDevice(_ device: AudioInputDevice, to engine: AVAudioEngine) -> Bool {
        guard let audioUnit = engine.inputNode.audioUnit else {
            AppLogger.log("[AudioDeviceManager] inputNode.audioUnit is nil — cannot set device")
            return false
        }
        var deviceID = device.id
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            AppLogger.log("[AudioDeviceManager] Failed to set input device '\(device.name)' (OSStatus \(status))")
            return false
        }
        return true
    }

    // MARK: - Core Audio property helpers

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
