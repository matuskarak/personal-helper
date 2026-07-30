import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem
    private var preferencesWindowController: NSWindowController?

    // Placeholders refreshed in menuWillOpen
    private var micSubmenuItem      = NSMenuItem(title: "Mikrofón", action: nil, keyEquivalent: "")
    private var historySubmenuItem  = NSMenuItem(title: "História diktovania", action: nil, keyEquivalent: "")
    private var restartItem         = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var diagnosticsItem     = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "accessibility", accessibilityDescription: "Osobný pomocník")
            button.image?.isTemplate = true
        }
        super.init()
        buildMenu()
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(NSMenuItem(title: "Čítať označený text", action: #selector(readText), keyEquivalent: "r")
            .configured { $0.keyEquivalentModifierMask = [.command, .shift]; $0.target = self })

        menu.addItem(NSMenuItem(title: "OCR oblasť", action: #selector(startOCR), keyEquivalent: "o")
            .configured { $0.keyEquivalentModifierMask = [.command, .shift]; $0.target = self })

        menu.addItem(NSMenuItem(title: "Diktovanie", action: #selector(toggleDictation), keyEquivalent: "d")
            .configured { $0.keyEquivalentModifierMask = [.command, .shift]; $0.target = self })

        menu.addItem(NSMenuItem(title: "Smart diktovanie", action: #selector(toggleSmartAlwaysOn), keyEquivalent: "g")
            .configured { $0.keyEquivalentModifierMask = [.command, .shift]; $0.target = self; $0.tag = 42 })

        menu.addItem(NSMenuItem(title: "Vložiť z pamäte", action: #selector(insertFromMemory), keyEquivalent: "v")
            .configured { $0.keyEquivalentModifierMask = [.control, .option]; $0.target = self })

        // History submenu — populated in menuWillOpen
        historySubmenuItem.submenu = NSMenu()
        menu.addItem(historySubmenuItem)

        menu.addItem(.separator())

        // Mic submenu — populated in menuWillOpen
        micSubmenuItem.submenu = NSMenu()
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
        MainActor.assumeIsolated { refreshDynamicItems() }
    }

    private func refreshDynamicItems() {
        let engine = DictationEngine.shared
        let devices = AudioDeviceManager.inputDevices()
        let resolvedUID = engine.resolvedInputDeviceUID()

        // Rebuild mic submenu — devices ordered by priority (rank shown), then any
        // other connected devices not yet prioritized. Clicking one makes it #1;
        // clicking "Systémový" clears the whole priority list.
        let sub = NSMenu()
        let sysItem = NSMenuItem(title: "Systémový (predvolený)", action: #selector(selectMicSystem), keyEquivalent: "")
        sysItem.target = self
        sysItem.state = resolvedUID == nil ? .on : .off
        sub.addItem(sysItem)

        if !devices.isEmpty { sub.addItem(.separator()) }

        let deviceByUID = Dictionary(uniqueKeysWithValues: devices.map { ($0.uid, $0) })
        let prioritized = engine.micPriority.compactMap { deviceByUID[$0] }
        let rest = devices.filter { !engine.micPriority.contains($0.uid) }

        for (index, dev) in prioritized.enumerated() {
            let item = NSMenuItem(title: "\(index + 1). \(dev.name)", action: #selector(selectMic(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dev.uid
            item.state = dev.uid == resolvedUID ? .on : .off
            sub.addItem(item)
        }
        if !prioritized.isEmpty && !rest.isEmpty { sub.addItem(.separator()) }
        for dev in rest {
            let item = NSMenuItem(title: dev.name, action: #selector(selectMic(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dev.uid
            item.state = dev.uid == resolvedUID ? .on : .off
            sub.addItem(item)
        }
        micSubmenuItem.submenu = sub

        // History submenu — most recent first, click to insert at the current focus.
        let historyMenu = NSMenu()
        let recentHistory = DictationHistoryStore.shared.entries.suffix(10).reversed()
        if recentHistory.isEmpty {
            let empty = NSMenuItem(title: "Zatiaľ žiadna história", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            historyMenu.addItem(empty)
        } else {
            for entry in recentHistory {
                let oneLine = entry.text.replacingOccurrences(of: "\n", with: " ")
                let preview = oneLine.count > 60 ? String(oneLine.prefix(60)) + "…" : oneLine
                let item = NSMenuItem(title: preview, action: #selector(insertHistoryEntry(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.text
                historyMenu.addItem(item)
            }
            historyMenu.addItem(.separator())
            let clearItem = NSMenuItem(title: "Vymazať históriu", action: #selector(clearHistory), keyEquivalent: "")
            clearItem.target = self
            historyMenu.addItem(clearItem)
        }
        historySubmenuItem.submenu = historyMenu

        // Smart diktovanie — hidden for regular users while it's remotely disabled
        // (feature-flags.json); dev mode always sees it for testing.
        if let smartItem = statusItem.menu?.item(withTag: 42) {
            smartItem.isHidden = !RemoteConfig.shared.smartDictationAllowed
            smartItem.state = engine.smartAlwaysOn ? .on : .off
        }

        let dev = DeveloperMode.isEnabled
        restartItem.isHidden     = !dev
        diagnosticsItem.isHidden = !dev
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
        guard let uid = sender.representedObject as? String else { return }
        var priority = DictationEngine.shared.micPriority
        priority.removeAll { $0 == uid }
        priority.insert(uid, at: 0)
        DictationEngine.shared.micPriority = priority
    }

    // MARK: - Actions

    @objc private func readText() {
        Task { @MainActor in await (NSApp.delegate as? AppDelegate)?.handleReadText() }
    }

    @objc private func startOCR() {
        (NSApp.delegate as? AppDelegate)?.handleOCR()
    }

    @objc private func toggleDictation() {
        (NSApp.delegate as? AppDelegate)?.handleDictate()
    }


    @objc private func toggleSmartAlwaysOn() {
        DictationEngine.shared.smartAlwaysOn.toggle()
    }

    @objc private func insertFromMemory() {
        (NSApp.delegate as? AppDelegate)?.handleInsertFromMemory()
    }

    @objc private func insertHistoryEntry(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        TextInserter.shared.insert(text)
    }

    @objc private func clearHistory() {
        DictationHistoryStore.shared.clearAll()
    }

    @objc private func openPreferences() {
        if preferencesWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Nastavenia"
            window.center()
            window.contentView = FirstMouseHostingView(rootView: PreferencesView())
            window.isReleasedWhenClosed = false
            preferencesWindowController = NSWindowController(window: window)
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
        let name = on ? "exclamationmark.triangle.fill" : "accessibility"
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: name, accessibilityDescription: "Osobný pomocník")
            btn.image?.isTemplate = true
            btn.toolTip = on ? "⚠️ Chýba Accessibility povolenie – System Settings → Privacy → Accessibility" : nil
        }
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
