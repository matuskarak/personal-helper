import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var axRetryTimer: Timer?

    // Continuously tracks the last real app to become frontmost — used by URL-scheme triggers
    // (see handleGetURL) where receiving the Apple Event has already activated US, so by the
    // time we run, the system-wide "focused app" AX query would wrongly report our own app
    // instead of the field the user was actually dictating into.
    private var lastExternalAppPID: pid_t?

    /// Apps whose activation must never overwrite `lastExternalAppPID`: ourselves, and
    /// Logi Options+'s own processes. The Action Ring is itself an on-screen overlay — opening
    /// it and picking a command necessarily activates Logi's process first, pulling focus out
    /// of the field the user was dictating into. If we tracked that as "the target app" we'd
    /// aim the pill/insertion at Logi Options+ instead of the field itself.
    private func isIgnorableForFocusTracking(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier else { return false }
        return id == Bundle.main.bundleIdentifier || id.hasPrefix("com.logi.") || id.hasPrefix("com.logitech.")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.markSection("Aplikácia spustená (PID \(ProcessInfo.processInfo.processIdentifier))")
        #if DEBUG
        DictationQualityEngine.selfCheck()
        AppProfile.selfCheck()
        #endif
        PermissionsChecker.shared.requestAllIfNeeded()
        _ = UpdaterController.shared // starts Sparkle's background update checks
        _ = RemoteConfig.shared      // starts feature-flag fetch
        menuBarController = MenuBarController()
        setupHotkeys()
        ShortcutStore.shared.sync() // load persisted (incl. extra-mapped) shortcuts before the tap starts
        startHotkeyManagerOrRetry()
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  !self.isIgnorableForFocusTracking(app)
            else { return }
            self.lastExternalAppPID = app.processIdentifier
        }

        if !UserDefaults.standard.bool(forKey: "onboarding.firstLaunchShown") {
            UserDefaults.standard.set(true, forKey: "onboarding.firstLaunchShown")
            OnboardingWindowController.shared.show()
        }
    }

    /// Fires while `NSWorkspace.shared.frontmostApplication` still reports the OUTGOING app —
    /// the one instant this trigger's target is reliably knowable. A URL-scheme trigger
    /// (osobnypomocnik://..., used by Logi Options+ Smart Actions) delivers an Apple Event
    /// that forces macOS to activate us, which stomps the very focus/AX context Smart
    /// diktovanie and the pill positioning depend on — capture it here before that happens.
    func applicationWillBecomeActive(_ notification: Notification) {
        if let prev = NSWorkspace.shared.frontmostApplication, !isIgnorableForFocusTracking(prev) {
            lastExternalAppPID = prev.processIdentifier
            AppLogger.log("[AppDelegate] applicationWillBecomeActive — captured \(prev.bundleIdentifier ?? "?") (\(prev.processIdentifier)) as the trigger's real target")
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
        HotkeyManager.shared.onDictateRealtime = { [weak self] in
            Task { @MainActor in self?.handleDictate(mode: .realtime) }
        }
        HotkeyManager.shared.onDictateBatch = { [weak self] in
            Task { @MainActor in self?.handleDictate(mode: .batch) }
        }
        HotkeyManager.shared.onSmartStop = { [weak self] in
            Task { @MainActor in self?.handleSmartStop() }
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

    // MARK: - URL scheme (osobnypomocnik://<action>)

    /// External trigger for tools whose synthesized keystrokes don't reach our global
    /// CGEventTap (e.g. Logi Options+ Smart Actions posted straight to the frontmost app —
    /// see HotkeyManager for why that's architecturally invisible to us). Point a Logi
    /// Smart Action / Shortcuts.app action at e.g. osobnypomocnik://dictate instead of a
    /// keyboard-shortcut action and it triggers the same handler as the real hotkey.
    @objc func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        guard
            let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
            let url = URL(string: urlString), url.scheme == "osobnypomocnik",
            let action = url.host
        else { return }
        AppLogger.log("[AppDelegate] URL trigger: \(url)")
        // Receiving this Apple Event has already activated us — the pill's "follow the
        // focused field" AX lookup would otherwise wrongly target our own app instead of
        // the one the user was actually dictating into (see DictationIndicatorController).
        AppLogger.log("[AppDelegate] URL trigger — lastExternalAppPID=\(lastExternalAppPID.map(String.init) ?? "nil")")
        DictationIndicatorController.shared.externalAppPIDOverride = lastExternalAppPID

        // Receiving this Apple Event just forced macOS to activate us — hand focus straight
        // back to whatever we were triggered from (applicationWillBecomeActive captured it)
        // before touching anything AX/paste-related, which all depend on that app being the
        // real frontmost one. Give the window server a beat to actually complete the handoff.
        if let pid = lastExternalAppPID, let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.dispatch(action: action)
            }
        } else {
            dispatch(action: action)
        }
    }

    private func dispatch(action: String) {
        switch action {
        case "readText":         Task { @MainActor in await self.handleReadText() }
        case "ocr":               handleOCR()
        // "dictate"/"smartDictate" kept for existing Logi/Shortcuts.app triggers.
        case "dictate", "dictateRealtime": handleDictate(mode: .realtime)
        case "dictateBatch", "transcribe": handleDictate(mode: .batch)
        case "smartDictate", "smartStop":  handleSmartStop()
        case "insertFromMemory":  handleInsertFromMemory()
        default: AppLogger.log("[AppDelegate] URL trigger — neznáma akcia: \(action)")
        }
    }

    func handleReadText() async {
        AppLogger.log("[AppDelegate] handleReadText — skratka stlačená")
        guard let text = await TextExtractor.shared.extractSelected(), !text.isEmpty else {
            AppLogger.log("[AppDelegate] handleReadText — žiadny text na pasteboarde")
            menuBarController?.showError("⚠️ Nie je označený žiadny text.")
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

    /// Start/stop for one dictation mode. The start shortcut picks the mode; while
    /// recording, ONLY the same mode's shortcut stops it (raw insert) — the other mode's
    /// shortcut is deliberately ignored so muscle memory stays unambiguous: what started
    /// the dictation is what stops it. Smart stop is the one exception (handleSmartStop).
    func handleDictate(mode: DictationEngine.TranscriptionMode) {
        let engine = DictationEngine.shared
        AppLogger.log("[AppDelegate] handleDictate(\(mode.rawValue)) — skratka stlačená (isRecording: \(engine.isRecording))")
        if engine.isRecording {
            guard engine.transcriptionMode == mode else {
                AppLogger.log("[AppDelegate] handleDictate(\(mode.rawValue)) — ignorované, beží \(engine.transcriptionMode.rawValue) diktovanie (zastaví ho len jeho vlastná skratka alebo Smart)")
                return
            }
            DictationSounds.playStop()
            Task { @MainActor in await self.finishDictation(engine: engine, label: "handleDictate(\(mode.rawValue))", smart: false) }
        } else {
            // Show the indicator immediately — startRecording() now has a multi-second
            // grace period for slow-to-connect mics (Bluetooth/Continuity), so the user
            // needs feedback that something is happening before that resolves.
            DictationIndicatorController.shared.show()
            Task { @MainActor in
                do {
                    try await engine.startRecording(mode: mode)
                    DictationSounds.playStart()
                } catch {
                    AppLogger.log("[AppDelegate] handleDictate(\(mode.rawValue)) — startRecording zlyhalo: \(error.localizedDescription)")
                    // Pill is already showing (from show() above) — just surface the reason in it.
                    if engine.connectionError == nil {
                        menuBarController?.showError("⚠️ \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// Smart stop: ends the running dictation (either mode) and rewrites the transcript
    /// with screen context before inserting. Pressed with no dictation running it does
    /// nothing at all — Smart is a way of FINISHING a dictation, not a mode of its own.
    func handleSmartStop() {
        let engine = DictationEngine.shared
        guard engine.isRecording else {
            AppLogger.log("[AppDelegate] handleSmartStop — ignorované (nebeží diktovanie)")
            return
        }
        guard RemoteConfig.shared.smartDictationAllowed else {
            AppLogger.log("[AppDelegate] handleSmartStop — ignorované (smartDictationAllowed=false)")
            return
        }
        AppLogger.log("[AppDelegate] handleSmartStop — ukončujem so Smart spracovaním")
        DictationSounds.playStop()
        Task { @MainActor in await self.finishDictation(engine: engine, label: "handleSmartStop", smart: true) }
    }

    private func finishDictation(engine: DictationEngine, label: String, smart: Bool = false) async {
        guard let text = await engine.stopAndTranscribe(smart: smart), !text.isEmpty else {
            if engine.didLiveInsert {
                AppLogger.log("[AppDelegate] \(label) — live-insert dokončený")
                DictationIndicatorController.shared.hide()
            } else if !engine.lastRecordingCapturedAudio {
                AppLogger.log("[AppDelegate] \(label) — žiadne audio sa nezaznamenalo")
                engine.showNotice("⚠️ Audio sa nezaznamenalo. Skontroluj mikrofón.")
            } else if engine.notice != nil {
                // transcribeLocal() already raised a sticky notice explaining an empty
                // result (e.g. no-speech-detected on real audio) — leave the pill up so
                // the user actually sees why nothing was inserted, instead of it vanishing.
                AppLogger.log("[AppDelegate] \(label) — prázdny transkript s vysvetľujúcim upozornením")
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
            DictationSounds.playInserted()
            if engine.notice == nil {
                DictationIndicatorController.shared.hide()
            }
            // else: a non-sticky notice (e.g. Smart rewrite fell back to raw transcript) is
            // already showing — let the pill's own auto-clear timer dismiss it so the user
            // actually sees why the inserted text looks different, instead of it vanishing
            // the instant the paste succeeds.
        case .savedToMemory:
            AppLogger.log("[AppDelegate] \(label) — žiadne pole nebolo zvolené, uložené do pamäte (\(text.count) znakov)")
            engine.showNotice("⚠️ Nebolo zvolené pole na vloženie. Text uložený do pamäte (⌃⌥V).")
        }
    }

    /// Inserts the last dictated text that couldn't be auto-inserted (⌃⌥V by default).
    func handleInsertFromMemory() {
        AppLogger.log("[AppDelegate] handleInsertFromMemory — skratka stlačená")
        // The "saved to memory" notice told the user about this exact shortcut — using it
        // is the notice doing its job, so dismiss the pill instead of leaving it sitting
        // there (same dismissal path as clicking the pill away).
        DictationIndicatorController.shared.hide(from: "handleInsertFromMemory")
        guard let text = DictationMemoryStore.shared.consume() else {
            menuBarController?.showError("⚠️ Pamäť diktovania je prázdna.")
            return
        }
        TextInserter.shared.insert(text)
    }
}

// MARK: - Dictation audio feedback

// ponytail: loaded once and held — NSSound(named:)?.play() is silently a no-op because
// the object is released by ARC before it finishes playing (no retained reference).
//
// Played on a background queue, never the caller's thread: NSSound.play() BLOCKS while
// CoreAudio spins up an idle output device — measured 580ms cold / 11ms warm. Called
// synchronously from handleDictate's stop branch, that block sat between the user's
// stop keypress and stopAudio(), delaying every transcription start by ~0.4s.
private enum DictationSounds {
    private static let soundQ = DispatchQueue(label: "sk.matuskarak.osobny-pomocnik.sounds", qos: .userInteractive)
    private static let start:    NSSound? = load("Tink")
    private static let stop_:    NSSound? = load("Pop")
    private static let inserted: NSSound? = load("Submarine")

    private static func load(_ name: String) -> NSSound? {
        let s = NSSound(contentsOfFile: "/System/Library/Sounds/\(name).aiff", byReference: false)
        s?.volume = 1.0
        return s
    }

    static func playStart()    { play(start) }
    static func playStop()     { play(stop_) }
    static func playInserted() { play(inserted) }

    private static func play(_ sound: NSSound?) {
        soundQ.async {
            guard let sound else { return }
            if sound.isPlaying { sound.stop(); sound.currentTime = 0 }
            sound.play()
        }
    }
}
