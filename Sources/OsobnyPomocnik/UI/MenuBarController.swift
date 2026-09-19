import AppKit
import SwiftUI
import Observation

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    /// Set in `init` — lets the standalone first-launch onboarding window (which has no
    /// other reference to AppDelegate's private `menuBarController`) reuse the existing
    /// "open Settings" code path instead of building its own window.
    private(set) static weak var shared: MenuBarController?

    private var statusItem: NSStatusItem
    private var preferencesWindowController: NSWindowController?
    private var accessibilityWarningActive = false

    // Placeholders refreshed in menuWillOpen
    private var micSubmenuItem      = NSMenuItem(title: "Mikrofón", action: nil, keyEquivalent: "")
    private var historySubmenuItem  = NSMenuItem(title: "História diktovania", action: nil, keyEquivalent: "")
    private var pendingSubmenuItem  = NSMenuItem(title: "Čakajúce nahrávky", action: nil, keyEquivalent: "")
    private var restartItem         = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var diagnosticsItem     = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var ocrItem             = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var realtimeItem        = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        Self.shared = self
        updateStatusIcon()
        buildMenu()
        observeRecording()
    }

    /// The pill is the primary "you're recording" signal, but it can be dragged off-screen,
    /// parked on another display, or just missed — the menu bar icon is the one place that's
    /// always in the same spot, so it gets its own state too.
    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let recording = DictationEngine.shared.isRecording
        // Idle = brand logo (monochrome template PNG from Resources/MenuBarIcon*.png, tinted by
        // the system per light/dark). Transient states stay SF Symbols — clearer at 18 pt.
        let symbol = accessibilityWarningActive ? "exclamationmark.triangle.fill"
                   : recording ? "record.circle.fill" : nil
        let image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: "Ozvena") }
            ?? NSImage(named: "MenuBarIcon")
        image?.isTemplate = true
        image?.accessibilityDescription = "Ozvena"
        button.image = image
        button.toolTip = accessibilityWarningActive
            ? "Chýba Accessibility povolenie – System Settings → Privacy → Accessibility"
            : (recording ? "Diktovanie beží" : nil)
    }

    /// Bridges DictationEngine's @Observable state into this AppKit-only controller — there's
    /// no SwiftUI view here to pick the change up automatically, so re-subscribing after every
    /// firing is the standard manual pattern for Observation outside a View body.
    private func observeRecording() {
        withObservationTracking {
            _ = DictationEngine.shared.isRecording
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateStatusIcon()
                self?.observeRecording()
            }
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(NSMenuItem(title: "Čítať označený text", action: #selector(readText), keyEquivalent: "r")
            .configured { $0.keyEquivalentModifierMask = [.command, .shift]; $0.target = self })

        // Entitlement-gated (licenčný backend, RemoteConfig) — shown/hidden in refreshDynamicItems.
        ocrItem = NSMenuItem(title: "OCR oblasť", action: #selector(startOCR), keyEquivalent: "o")
            .configured { $0.keyEquivalentModifierMask = [.command, .shift]; $0.target = self }
        menu.addItem(ocrItem)

        realtimeItem = NSMenuItem(title: "Diktovanie (realtime)", action: #selector(toggleDictationRealtime), keyEquivalent: "s")
            .configured { $0.keyEquivalentModifierMask = [.command, .shift]; $0.target = self }
        menu.addItem(realtimeItem)

        menu.addItem(NSMenuItem(title: "Diktovanie (po nahraní)", action: #selector(toggleDictationBatch), keyEquivalent: "d")
            .configured { $0.keyEquivalentModifierMask = [.command, .shift]; $0.target = self })

        menu.addItem(NSMenuItem(title: "Vložiť z pamäte", action: #selector(insertFromMemory), keyEquivalent: "v")
            .configured { $0.keyEquivalentModifierMask = [.control, .option]; $0.target = self })

        // History submenu — populated in menuWillOpen
        historySubmenuItem.submenu = NSMenu()
        menu.addItem(historySubmenuItem)

        // Recordings whose transcription failed — hidden entirely when there are none, so it
        // only shows up when there's actually something to recover.
        pendingSubmenuItem.submenu = NSMenu()
        menu.addItem(pendingSubmenuItem)

        menu.addItem(.separator())

        // Mic submenu — populated lazily when IT opens (see rebuildMicSubmenu)
        let micSub = NSMenu()
        micSub.delegate = self
        micSubmenuItem.submenu = micSub
        menu.addItem(micSubmenuItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Nastavenia…", action: #selector(openPreferences), keyEquivalent: ",")
            .configured { $0.target = self })

        menu.addItem(NSMenuItem(title: "Skontrolovať aktualizácie…", action: #selector(checkForUpdates), keyEquivalent: "")
            .configured { $0.target = self })

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Ukončiť", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // Developer-only items, shown/hidden in refreshDynamicItems.
        // ponytail: these used to be `isAlternate` items revealed by holding ⌥, but an
        // alternate must share the key equivalent of the item above it — "" vs ⌘Q on
        // "Ukončiť" — so AppKit ignored the pairing and drew them as ordinary rows. Plain
        // show/hide is what the ⌥ trick was approximating anyway, and it's predictable.
        diagnosticsItem = NSMenuItem(title: "Diagnostika — zobraziť log…", action: #selector(openLogViewer), keyEquivalent: "")
        diagnosticsItem.target = self
        diagnosticsItem.isHidden = true
        menu.addItem(diagnosticsItem)

        restartItem = NSMenuItem(title: "Reštartovať aplikáciu", action: #selector(restartApp), keyEquivalent: "")
        restartItem.target = self
        restartItem.isHidden = true
        menu.addItem(restartItem)

        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        // Must run synchronously: AppKit lays the menu out as soon as this returns, so a
        // `Task { @MainActor in … }` applied its isHidden/title changes too late and the
        // first open always showed the previous state — which is why "Reštartovať aplikáciu"
        // stayed visible with Developer mode off. menuWillOpen is always called on the main
        // thread, so assuming isolation here is safe.
        // nonisolated(unsafe): same "menuWillOpen is always main-thread" assumption that
        // assumeIsolated itself rests on — NSMenu just isn't Sendable, so the compiler can't
        // see the reference never actually crosses threads here.
        nonisolated(unsafe) let menu = menu
        MainActor.assumeIsolated {
            if menu === micSubmenuItem.submenu {
                rebuildMicSubmenu(menu)
            } else {
                refreshDynamicItems()
            }
        }
    }

    /// Built only when the mic submenu itself opens — enumerating input devices means
    /// several CoreAudio HAL property reads per device, each routed through every installed
    /// HAL plugin (this machine runs five third-party ones: SoundSource/ARK, BlackHole,
    /// eqMac…). Doing that synchronously on EVERY main-menu open was the dropdown lag;
    /// hovering "Mikrofón" is the one moment the fresh list is actually needed.
    private func rebuildMicSubmenu(_ sub: NSMenu) {
        let engine = DictationEngine.shared
        let devices = AudioDeviceManager.inputDevices()
        let resolvedUID = engine.resolvedInputDeviceUID(devices: devices)

        // Devices ordered by priority (rank shown), then any other connected devices not
        // yet prioritized. Clicking one makes it #1; "Systémový" clears the priority list.
        sub.removeAllItems()
        let sysItem = NSMenuItem(title: "Systémový (predvolený)", action: #selector(selectMicSystem), keyEquivalent: "")
        sysItem.target = self
        sysItem.state = resolvedUID == nil ? .on : .off
        sub.addItem(sysItem)

        if !devices.isEmpty { sub.addItem(.separator()) }

        // Keyed by stableKey (see AudioInputDevice.stableKey), not raw uid — the priority
        // list is stored as stableKeys so a USB mic still matches after a different port.
        let deviceByKey = Dictionary(devices.map { ($0.stableKey, $0) }, uniquingKeysWith: { first, _ in first })
        let resolvedKey = devices.first(where: { $0.uid == resolvedUID })?.stableKey
        let prioritized = engine.micPriority.compactMap { deviceByKey[$0] }
        let rest = devices.filter { !engine.micPriority.contains($0.stableKey) }

        for (index, dev) in prioritized.enumerated() {
            let item = NSMenuItem(title: "\(index + 1). \(dev.name)", action: #selector(selectMic(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dev.stableKey
            item.state = dev.stableKey == resolvedKey ? .on : .off
            sub.addItem(item)
        }
        if !prioritized.isEmpty && !rest.isEmpty { sub.addItem(.separator()) }
        for dev in rest {
            let item = NSMenuItem(title: dev.name, action: #selector(selectMic(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dev.stableKey
            item.state = dev.stableKey == resolvedKey ? .on : .off
            sub.addItem(item)
        }
    }

    private func refreshDynamicItems() {
        // History submenu — most recent first, click to insert at the current focus.
        let historyMenu = NSMenu()
        let recentHistory = DictationHistoryStore.shared.entries.suffix(10).reversed()
        if recentHistory.isEmpty {
            let empty = NSMenuItem(title: "Zatiaľ žiadna história", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            historyMenu.addItem(empty)
        } else {
            for entry in recentHistory {
                // Preview and payload must be the SAME text. They weren't: the row showed the
                // raw transcript while the click pasted the Smart-rewritten one, so the list
                // you read wasn't the list you got — which is how you end up picking the wrong
                // row and concluding "it inserted an older dictation".
                let text = entry.rewrittenText ?? entry.text
                let oneLine = text.replacingOccurrences(of: "\n", with: " ")
                let preview = oneLine.count > 60 ? String(oneLine.prefix(60)) + "…" : oneLine
                let item = NSMenuItem(title: preview, action: #selector(insertHistoryEntry(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = text
                historyMenu.addItem(item)
            }
            historyMenu.addItem(.separator())
            let clearItem = NSMenuItem(title: "Vymazať históriu", action: #selector(clearHistory), keyEquivalent: "")
            clearItem.target = self
            historyMenu.addItem(clearItem)
        }
        historySubmenuItem.submenu = historyMenu

        // Pending (failed) recordings
        let pendingItems = PendingDictationStore.shared.pending
        pendingSubmenuItem.isHidden = pendingItems.isEmpty
        if !pendingItems.isEmpty {
            pendingSubmenuItem.title = "Čakajúce nahrávky (\(pendingItems.count))"
            let pendingMenu = NSMenu()
            for item in pendingItems.reversed() {
                let entry = NSMenuItem(title: item.displayName, action: #selector(retryPending(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = item.id.uuidString
                pendingMenu.addItem(entry)
            }
            pendingMenu.addItem(.separator())
            let clear = NSMenuItem(title: "Zmazať všetky čakajúce", action: #selector(clearPending), keyEquivalent: "")
            clear.target = self
            pendingMenu.addItem(clear)
            pendingSubmenuItem.submenu = pendingMenu
        }

        let dev = DeveloperMode.isEnabled
        restartItem.isHidden     = !dev
        diagnosticsItem.isHidden = !dev
        ocrItem.isHidden         = !RemoteConfig.shared.ocrAllowed
        realtimeItem.isHidden    = !RemoteConfig.shared.realtimeAllowed
    }

    @objc private func openLogViewer() {
        LogViewerWindowController.shared.show()
    }

    // MARK: - Mic selection

    @objc private func selectMicSystem() {
        DictationEngine.shared.micPriority = []
    }

    /// Makes the clicked device the top priority (moves it to the front, no duplicates).
    @objc private func selectMic(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        var priority = DictationEngine.shared.micPriority
        priority.removeAll { $0 == key }
        priority.insert(key, at: 0)
        DictationEngine.shared.micPriority = priority
    }

    // MARK: - Actions

    @objc private func readText() {
        Task { @MainActor in await (NSApp.delegate as? AppDelegate)?.handleReadText() }
    }

    @objc private func startOCR() {
        (NSApp.delegate as? AppDelegate)?.handleOCR()
    }

    @objc private func toggleDictationRealtime() {
        (NSApp.delegate as? AppDelegate)?.handleDictate(mode: .realtime)
    }

    @objc private func toggleDictationBatch() {
        (NSApp.delegate as? AppDelegate)?.handleDictate(mode: .batch)
    }

    @objc private func insertFromMemory() {
        (NSApp.delegate as? AppDelegate)?.handleInsertFromMemory()
    }

    @objc private func retryPending(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw),
              let item = PendingDictationStore.shared.pending.first(where: { $0.id == id })
        else { return }
        AppLogger.log("[MenuBarController] retryPending — \(item.displayName)")
        DictationIndicatorController.shared.show()
        Task { @MainActor in await DictationEngine.shared.retryPending(item) }
    }

    @objc private func clearPending() {
        guard confirmDestructive(title: "Zmazať všetky čakajúce nahrávky?",
                                  message: "Nedá sa vrátiť späť — nahrávky sa stratia bez prepisu.") else { return }
        AppLogger.log("[MenuBarController] clearPending — mažem \(PendingDictationStore.shared.pending.count) nahrávok")
        PendingDictationStore.shared.removeAll()
    }

    /// Blocking Áno/Zrušiť dialog for a menu action that can't undo itself — the SwiftUI
    /// tabs use `.confirmationDialog`, this is the AppKit-menu equivalent of the same rule.
    private func confirmDestructive(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Zmazať")
        alert.addButton(withTitle: "Zrušiť")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func insertHistoryEntry(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        // Logged because an unattributed TextInserter.insert() in app.log is indistinguishable
        // from a rogue paste — this is the one path that inserts text nobody just dictated.
        AppLogger.log("[MenuBarController] insertHistoryEntry — z histórie (\(text.count) znakov)")
        TextInserter.shared.insert(text)
    }

    @objc private func clearHistory() {
        guard confirmDestructive(title: "Vymazať celú históriu diktovania?",
                                  message: "Nedá sa vrátiť späť — zmažú sa všetky uložené prepisy.") else { return }
        DictationHistoryStore.shared.clearAll()
    }

    @objc func openPreferences() {
        if preferencesWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Nastavenia"
            window.minSize = NSSize(width: 680, height: 480)
            window.center()
            window.contentView = FirstMouseHostingView(rootView: PreferencesView())
            window.isReleasedWhenClosed = false
            preferencesWindowController = NSWindowController(window: window)
            // Remembers size AND position across launches (restores immediately if a saved
            // frame exists, overriding the centered default above) — a user who resizes once
            // for larger text shouldn't have to redo it every time.
            preferencesWindowController?.windowFrameAutosaveName = "PreferencesWindow"
        }
        preferencesWindowController?.showWindow(nil)
        preferencesWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

    }

    @objc private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        UpdaterController.shared.checkForUpdates()
    }

    /// Developer-mode helper — relaunches the .app bundle and quits this instance,
    /// so testing doesn't need a Terminal round-trip.
    @objc private func restartApp() {
        AppLogger.log("[MenuBarController] Developer mode — restarting app")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: - Public helpers

    func setAccessibilityWarning(_ on: Bool) {
        accessibilityWarningActive = on
        updateStatusIcon()
    }

    /// Surfaces a standalone message in the same floating pill used during dictation,
    /// instead of a blocking NSAlert dialog — keeps one consistent notice style app-wide.
    func showError(_ message: String) {
        // Order matters: show() must mount the pill *before* notice changes, otherwise
        // the view's onChange(of: notice) — which drives the auto-hide timer — never fires.
        DictationIndicatorController.shared.show()
        // Give the pill's view a moment to actually mount before notice changes —
        // otherwise onChange(of: notice) has no prior render to diff against and never fires.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            DictationEngine.shared.showNotice(message)
        }
    }
}

// MARK: - Helpers

private extension NSMenuItem {
    func configured(_ configure: (NSMenuItem) -> Void) -> NSMenuItem {
        configure(self)
        return self
    }
}
