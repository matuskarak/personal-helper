import AppKit

extension NSMenu {
    /// The app had no main menu at all, which quietly broke every text field in it: macOS
    /// routes ⌘C/⌘V/⌘X/⌘A/⌘Z through the Edit menu's key equivalents, so with no menu there
    /// is no way to paste anywhere in the app — you can only type, character by character.
    /// That makes an API key practically unenterable.
    ///
    /// An `.accessory` app never displays this menu (no Dock icon, no menu bar of its own),
    /// but NSApplication matches key equivalents against it regardless — which is the whole
    /// point of building it. `nil` targets send each action down the responder chain, so
    /// whatever field is focused handles it.
    static func osobnyPomocnikMenu() -> NSMenu {
        let main = NSMenu()

        // macOS treats the first item as the application menu whether or not it's shown —
        // ⌘Q lives here, and it didn't work before either.
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Skryť Osobný pomocník", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Ukončiť Osobný pomocník", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Upraviť")
        edit.addItem(withTitle: "Späť", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Znova", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Vystrihnúť", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Kopírovať", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Vložiť", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Vybrať všetko", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        return main
    }
}
