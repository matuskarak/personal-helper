import Cocoa

final class HotkeyManager: @unchecked Sendable {
    static let shared = HotkeyManager()

    var onReadText: (() -> Void)?
    var onOCR: (() -> Void)?
    var onDictate: (() -> Void)?
    var onSmartDictate: (() -> Void)?
    var onInsertFromMemory: (() -> Void)?
    var onEnterStopDictation: (() -> Void)?

    // Cached shortcuts — written from MainActor, read from CGEventTap thread
    private var readTextSC: Shortcut         = .defaultReadText
    private var ocrSC: Shortcut              = .defaultOCR
    private var dictateSC: Shortcut          = .defaultDictate
    private var smartDictateSC: Shortcut     = .defaultSmartDictate
    private var insertFromMemorySC: Shortcut = .defaultInsertFromMemory

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private init() {}

    func start() {
        guard AXIsProcessTrusted() else {
            print("[HotkeyManager] Accessibility permission required")
            return
        }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let m = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return m.handle(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = eventTap else { print("[HotkeyManager] Failed to create event tap"); return }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }

    func updateShortcuts(
        readText: Shortcut, ocr: Shortcut, dictate: Shortcut, smartDictate: Shortcut,
        insertFromMemory: Shortcut
    ) {
        readTextSC         = readText
        ocrSC               = ocr
        dictateSC           = dictate
        smartDictateSC      = smartDictate
        insertFromMemorySC  = insertFromMemory
    }

    // MARK: - Event handling

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS auto-disables an event tap if its callback appears unresponsive
        // (e.g. main thread blocked elsewhere). Re-enable immediately so shortcuts
        // keep working instead of silently dying for the rest of the session.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                AppLogger.log("[HotkeyManager] ⚠️ Event tap disabled (\(type == .tapDisabledByTimeout ? "timeout" : "user input")) — re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }
        guard type == .keyDown else { return Unmanaged.passRetained(event) }

        if matches(event, shortcut: readTextSC) {
            DispatchQueue.main.async { self.onReadText?() }
            return nil
        }
        if matches(event, shortcut: ocrSC) {
            DispatchQueue.main.async { self.onOCR?() }
            return nil
        }
        if matches(event, shortcut: dictateSC) {
            DispatchQueue.main.async { self.onDictate?() }
            return nil
        }
        if matches(event, shortcut: smartDictateSC) {
            DispatchQueue.main.async { self.onSmartDictate?() }
            return nil
        }
        if matches(event, shortcut: insertFromMemorySC) {
            DispatchQueue.main.async { self.onInsertFromMemory?() }
            return nil
        }
        // Enter/numpad-Enter: always pass through so the field gets it (message sends).
        // Check dictation state on main (actor-safe); overhead is one async per Enter press.
        let kc = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if kc == 36 || kc == 76 {
            DispatchQueue.main.async {
                let e = DictationEngine.shared
                guard e.isRecording, e.liveInsertActive, e.enterAutoStop else { return }
                self.onEnterStopDictation?()
            }
        }
        return Unmanaged.passRetained(event)
    }

    private func matches(_ event: CGEvent, shortcut: Shortcut) -> Bool {
        let kc = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard kc == shortcut.keyCode else { return false }
        // Compare only the modifier bits (top 16 bits of CGEventFlags)
        let evMod = event.flags.rawValue & 0xFFFF0000
        let scMod = UInt64(shortcut.modifierFlags) & 0xFFFF0000
        return evMod == scMod
    }
}
