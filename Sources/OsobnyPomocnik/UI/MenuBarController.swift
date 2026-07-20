import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem
    private var preferencesWindowController: NSWindowController?

    // Placeholders refreshed in menuWillOpen
    private var micSubmenuItem      = NSMenuItem(title: "Mikrofón", action: nil, keyEquivalent: "")
    private var dictUsageItem       = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var ttsUsageItem        = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var restartItem         = NSMenuItem(title: "", action: nil, keyEquivalent: "")

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

        menu.addItem(.separator())

        // Mic submenu — populated in menuWillOpen
        micSubmenuItem.submenu = NSMenu()
        menu.addItem(micSubmenuItem)

        // Usage — two lines (dictation + TTS), text set in menuWillOpen
        dictUsageItem.isEnabled = false
        ttsUsageItem.isEnabled  = false
        menu.addItem(dictUsageItem)
        menu.addItem(ttsUsageItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Nastavenia…", action: #selector(openPreferences), keyEquivalent: ",")
            .configured { $0.target = self })

        menu.addItem(NSMenuItem(title: "Skontrolovať aktualizácie…", action: #selector(checkForUpdates), keyEquivalent: "")
            .configured { $0.target = self })

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Ukončiť", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // Alternate item — replaces "Ukončiť" in the menu while ⌥ is held. Only
        // shown when Developer mode is on (toggled in refreshDynamicItems).
        restartItem = NSMenuItem(title: "Reštartovať aplikáciu", action: #selector(restartApp), keyEquivalent: "")
        restartItem.target = self
        restartItem.isAlternate = true
        restartItem.keyEquivalentModifierMask = [.option]
        restartItem.isHidden = true
        menu.addItem(restartItem)

        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        Task { @MainActor in self.refreshDynamicItems() }
    }

    private func refreshDynamicItems() {
        let engine = DictationEngine.shared
        let devices = AudioDeviceManager.inputDevices()
        let selectedUID = engine.selectedInputDeviceUID

        // Rebuild mic submenu
        let sub = NSMenu()
        let sysItem = NSMenuItem(title: "Systémový (predvolený)", action: #selector(selectMicSystem), keyEquivalent: "")
        sysItem.target = self
        sysItem.state = selectedUID == nil ? .on : .off
        sub.addItem(sysItem)

        if !devices.isEmpty { sub.addItem(.separator()) }

        for dev in devices {
            let item = NSMenuItem(title: dev.name, action: #selector(selectMic(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dev.uid
            item.state = dev.uid == selectedUID ? .on : .off
            sub.addItem(item)
        }
        micSubmenuItem.submenu = sub

        // Smart diktovanie — hidden for regular users while it's remotely disabled
        // (feature-flags.json); dev mode always sees it for testing.
        if let smartItem = statusItem.menu?.item(withTag: 42) {
            smartItem.isHidden = !RemoteConfig.shared.smartDictationAllowed
            smartItem.state = engine.smartAlwaysOn ? .on : .off
        }

        // Usage — dictation on one line, TTS on the next
        let dictMins = Double(engine.totalSecondsRecorded) / 60
        let dictCost = dictMins * engine.costPerMinute
        dictUsageItem.title = String(format: "Diktovanie: %.1f min (~$%.3f)", dictMins, dictCost)

        let tts = TTSEngine.shared
        if tts.mode == .googleCloud {
            let chars = Double(GoogleCloudTTSEngine.shared.totalCharactersUsed)
            let voice = GoogleCloudTTSEngine.shared.selectedVoiceName
            let ratePerChar: Double = voice.contains("Chirp3-HD") || voice.contains("Chirp-HD") ? 0.00016
                                    : (voice.contains("WaveNet") || voice.contains("Neural2"))  ? 0.000016
                                    : 0.000004
            ttsUsageItem.title = String(format: "Čítanie: ~$%.3f", chars * ratePerChar)
            ttsUsageItem.isHidden = false
        } else {
            ttsUsageItem.isHidden = true
        }

        restartItem.isHidden = !DeveloperMode.isEnabled
    }

    // MARK: - Mic selection

    @objc private func selectMicSystem() {
        DictationEngine.shared.selectedInputDeviceUID = nil
    }

    @objc private func selectMic(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        DictationEngine.shared.selectedInputDeviceUID = uid
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
            window.contentView = NSHostingView(rootView: PreferencesView())
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

    func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Osobný pomocník"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - Helpers

private extension NSMenuItem {
    func configured(_ configure: (NSMenuItem) -> Void) -> NSMenuItem {
        configure(self)
        return self
    }
}
