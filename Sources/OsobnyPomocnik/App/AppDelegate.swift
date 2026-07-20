import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var axRetryTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.markSection("Aplikácia spustená (PID \(ProcessInfo.processInfo.processIdentifier))")
        PermissionsChecker.shared.requestAllIfNeeded()
        _ = UpdaterController.shared // starts Sparkle's background update checks
        _ = RemoteConfig.shared      // starts feature-flag fetch
        menuBarController = MenuBarController()
        setupHotkeys()
        startHotkeyManagerOrRetry()

        if !UserDefaults.standard.bool(forKey: "onboarding.firstLaunchShown") {
            UserDefaults.standard.set(true, forKey: "onboarding.firstLaunchShown")
            OnboardingWindowController.shared.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLogger.log("[AppDelegate] applicationWillTerminate")
        axRetryTimer?.invalidate()
        HotkeyManager.shared.stop()
    }

    // MARK: - Accessibility retry

    /// Tries to start the event tap. If Accessibility isn't granted yet,
    /// polls every 2 s until it is (user may grant it while the app is running).
    private func startHotkeyManagerOrRetry() {
        if AXIsProcessTrusted() {
            HotkeyManager.shared.start()
            menuBarController?.setAccessibilityWarning(false)
        } else {
            menuBarController?.setAccessibilityWarning(true)
            axRetryTimer?.invalidate()
            axRetryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard AXIsProcessTrusted() else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.axRetryTimer?.invalidate()
                    self.axRetryTimer = nil
                    HotkeyManager.shared.start()
                    self.menuBarController?.setAccessibilityWarning(false)
                }
            }
        }
    }

    // MARK: - Hotkey handlers

    private func setupHotkeys() {
        HotkeyManager.shared.onReadText = { [weak self] in
            Task { @MainActor in await self?.handleReadText() }
        }
        HotkeyManager.shared.onOCR = { [weak self] in
            self?.handleOCR()
        }
        HotkeyManager.shared.onDictate = { [weak self] in
            Task { @MainActor in self?.handleDictate() }
        }
        HotkeyManager.shared.onSmartDictate = { [weak self] in
            Task { @MainActor in self?.handleSmartDictate() }
        }
        HotkeyManager.shared.onInsertFromMemory = { [weak self] in
            self?.handleInsertFromMemory()
        }
        HotkeyManager.shared.onEnterStopDictation = { [weak self] in
            let engine = DictationEngine.shared
            guard engine.isRecording else { return }
            DictationSounds.playStop()
            Task { @MainActor in await self?.finishDictation(engine: engine, label: "enterAutoStop") }
        }
    }

    func handleReadText() async {
        AppLogger.log("[AppDelegate] handleReadText — skratka stlačená")
        guard let text = await TextExtractor.shared.extractSelected(), !text.isEmpty else {
            AppLogger.log("[AppDelegate] handleReadText — žiadny text na pasteboarde")
            menuBarController?.showError("Nie je označený žiadny text.")
            return
        }
        AppLogger.log("[AppDelegate] handleReadText — text získaný (\(text.count) znakov), spúšťam TTS")
        TTSEngine.shared.speak(text)
        ControlPanelWindowController.shared.show()
    }

    func handleOCR() {
        AppLogger.log("[AppDelegate] handleOCR — skratka stlačená")
        OCROverlayWindowController.shared.onRectSelected = { rect in
            Task { @MainActor in
                do {
                    let text = try await OCREngine.shared.recognize(in: rect)
                    guard !text.isEmpty else {
                        AppLogger.log("[AppDelegate] handleOCR — OCR nenašlo text")
                        ControlPanelWindowController.shared.showStatus("OCR nenašlo žiadny text.")
                        return
                    }
                    AppLogger.log("[AppDelegate] handleOCR — rozpoznaných \(text.count) znakov")
                    TTSEngine.shared.speak(text)
                    ControlPanelWindowController.shared.show()
                } catch {
                    AppLogger.log("[AppDelegate] handleOCR — zlyhalo: \(error.localizedDescription)")
                    ControlPanelWindowController.shared.showStatus("OCR zlyhalo: \(error.localizedDescription)")
                }
            }
        }
        OCROverlayWindowController.shared.show()
    }

    func handleDictate() {
        AppLogger.log("[AppDelegate] handleDictate — skratka stlačená (isRecording: \(DictationEngine.shared.isRecording))")
        let engine = DictationEngine.shared
        if engine.isRecording {
            DictationSounds.playStop()
            Task { @MainActor in await self.finishDictation(engine: engine, label: "handleDictate") }
        } else {
            // Show the indicator immediately — startRecording() now has a multi-second
            // grace period for slow-to-connect mics (Bluetooth/Continuity), so the user
            // needs feedback that something is happening before that resolves.
            DictationIndicatorController.shared.show()
            Task { @MainActor in
                do {
                    let smart = engine.smartAlwaysOn && RemoteConfig.shared.smartDictationAllowed
                    try await engine.startRecording(smart: smart)
                    DictationSounds.playStart()
                } catch {
                    AppLogger.log("[AppDelegate] handleDictate — startRecording zlyhalo: \(error.localizedDescription)")
                    DictationIndicatorController.shared.hide()
                    let msg = engine.connectionError ?? error.localizedDescription
                    menuBarController?.showError(msg)
                }
            }
        }
    }

    /// Same flow as handleDictate, but captures screenshot + app context at start
    /// and rewrites the transcript for that context (Slack tone, AI prompt clarity, …) before inserting.
    /// No-ops while Smart diktovanie is remotely disabled for this user (feature-flags.json) —
    /// keeps the shortcut harmless instead of erroring for regular users.
    func handleSmartDictate() {
        guard RemoteConfig.shared.smartDictationAllowed else {
            AppLogger.log("[AppDelegate] handleSmartDictate — ignorované (smartDictationAllowed=false)")
            return
        }
        AppLogger.log("[AppDelegate] handleSmartDictate — skratka stlačená (isRecording: \(DictationEngine.shared.isRecording))")
        let engine = DictationEngine.shared
        if engine.isRecording {
            DictationSounds.playStop()
            Task { @MainActor in await self.finishDictation(engine: engine, label: "handleSmartDictate") }
        } else {
            DictationIndicatorController.shared.show()
            Task { @MainActor in
                do {
                    try await engine.startRecording(smart: true)
                    DictationSounds.playStart()
                } catch {
                    AppLogger.log("[AppDelegate] handleSmartDictate — startRecording zlyhalo: \(error.localizedDescription)")
                    DictationIndicatorController.shared.hide()
                    let msg = engine.connectionError ?? error.localizedDescription
                    menuBarController?.showError(msg)
                }
            }
        }
    }

    /// Shared "stop → transcribe → insert (or remember)" tail for both dictation flows.
    /// - If no audio was ever captured, surfaces a clear "audio didn't work" notice.
    /// - If audio worked but transcript came back empty, just hides (nothing to insert).
    /// - If there's a focused editable field, inserts there.
    /// - Otherwise saves to DictationMemoryStore and shows a notice with the recall shortcut.
    private func finishDictation(engine: DictationEngine, label: String) async {
        guard let text = await engine.stopAndTranscribe(), !text.isEmpty else {
            if engine.didLiveInsert {
                AppLogger.log("[AppDelegate] \(label) — live-insert dokončený")
                DictationIndicatorController.shared.hide()
            } else if !engine.lastRecordingCapturedAudio {
                AppLogger.log("[AppDelegate] \(label) — žiadne audio sa nezaznamenalo")
                engine.showNotice("⚠️ Audio sa nezaznamenalo. Skontroluj mikrofón.")
            } else {
                AppLogger.log("[AppDelegate] \(label) — prázdny transkript, nič sa nevkladá")
                DictationIndicatorController.shared.hide()
            }
            return
        }

        guard !engine.didLiveInsert else {
            AppLogger.log("[AppDelegate] \(label) — live-insert dokončený (fallback path)")
            DictationIndicatorController.shared.hide()
            return
        }

        switch TextInserter.shared.insertOrRemember(text) {
        case .inserted:
            AppLogger.log("[AppDelegate] \(label) — vložené (\(text.count) znakov)")
            DictationIndicatorController.shared.hide()
        case .savedToMemory:
            AppLogger.log("[AppDelegate] \(label) — žiadne pole nebolo zvolené, uložené do pamäte (\(text.count) znakov)")
            engine.showNotice("⚠️ Nebolo zvolené pole na vloženie. Text uložený do pamäte (⌃⌥V).")
        }
    }

    /// Inserts the last dictated text that couldn't be auto-inserted (⌃⌥V by default).
    func handleInsertFromMemory() {
        AppLogger.log("[AppDelegate] handleInsertFromMemory — skratka stlačená")
        guard let text = DictationMemoryStore.shared.consume() else {
            menuBarController?.showError("Pamäť diktovania je prázdna.")
            return
        }
        TextInserter.shared.insert(text)
    }
}

// MARK: - Dictation audio feedback

// ponytail: loaded once and held — NSSound(named:)?.play() is silently a no-op because
// the object is released by ARC before it finishes playing (no retained reference).
private enum DictationSounds {
    private static let start: NSSound? = load("Tink")
    private static let stop_:  NSSound? = load("Pop")

    private static func load(_ name: String) -> NSSound? {
        let s = NSSound(contentsOfFile: "/System/Library/Sounds/\(name).aiff", byReference: false)
        s?.volume = 1.0
        return s
    }

    static func playStart() { play(start) }
    static func playStop()  { play(stop_) }

    private static func play(_ sound: NSSound?) {
        guard let sound else { return }
        if sound.isPlaying { sound.stop(); sound.currentTime = 0 }
        sound.play()
    }
}
