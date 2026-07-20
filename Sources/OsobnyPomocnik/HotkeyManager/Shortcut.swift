import AppKit

// MARK: - Model

struct Shortcut: Codable, Equatable, Sendable {
    var keyCode: Int
    var modifierFlags: UInt  // NSEvent.ModifierFlags rawValue

    // MARK: Defaults
    static let defaultReadText    = Shortcut(keyCode: 15, modifierFlags: [.command, .shift])
    static let defaultOCR         = Shortcut(keyCode: 31, modifierFlags: [.command, .shift])
    static let defaultDictate     = Shortcut(keyCode: 2,  modifierFlags: [.command, .shift])
    static let defaultSmartDictate = Shortcut(keyCode: 5,  modifierFlags: [.command, .shift])
    static let defaultInsertFromMemory = Shortcut(keyCode: 9, modifierFlags: [.control, .option])

    init(keyCode: Int, modifierFlags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags.rawValue
    }

    fileprivate init(keyCode: Int, rawModifiers: UInt) {
        self.keyCode = keyCode
        self.modifierFlags = rawModifiers
    }

    var nsModifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlags) }

    var displayString: String {
        var s = ""
        let m = nsModifiers
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option)  { s += "⌥" }
        if m.contains(.shift)   { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        s += Self.keyName(for: keyCode)
        return s
    }

    static func keyName(for keyCode: Int) -> String {
        let map: [Int: String] = [
            0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",
            11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",31:"O",32:"U",
            34:"I",37:"L",38:"J",40:"K",45:"N",46:"M",47:",",48:"⇥",49:"␣",
            51:"⌫",53:"⎋",123:"←",124:"→",125:"↓",126:"↑"
        ]
        return map[keyCode] ?? "?"
    }
}

// MARK: - Store

@MainActor
final class ShortcutStore {
    static let shared = ShortcutStore()
    private init() {}

    var readText: Shortcut {
        get { load("sc.readText") ?? .defaultReadText }
        set { save(newValue, for: "sc.readText"); sync() }
    }
    var ocr: Shortcut {
        get { load("sc.ocr") ?? .defaultOCR }
        set { save(newValue, for: "sc.ocr"); sync() }
    }
    var dictate: Shortcut {
        get { load("sc.dictate") ?? .defaultDictate }
        set { save(newValue, for: "sc.dictate"); sync() }
    }
    var smartDictate: Shortcut {
        get { load("sc.smartDictate") ?? .defaultSmartDictate }
        set { save(newValue, for: "sc.smartDictate"); sync() }
    }
    var insertFromMemory: Shortcut {
        get { load("sc.insertFromMemory") ?? .defaultInsertFromMemory }
        set { save(newValue, for: "sc.insertFromMemory"); sync() }
    }

    private func load(_ key: String) -> Shortcut? {
        // Both keys must exist (object(forKey:) returns nil if absent)
        guard UserDefaults.standard.object(forKey: key + ".kc") != nil,
              UserDefaults.standard.object(forKey: key + ".mf") != nil else { return nil }
        let kc = UserDefaults.standard.integer(forKey: key + ".kc")
        // modifierFlags is UInt; store as Int bit-pattern to survive UserDefaults round-trip
        let mf = UInt(bitPattern: UserDefaults.standard.integer(forKey: key + ".mf"))
        return Shortcut(keyCode: kc, rawModifiers: mf)
    }

    private func save(_ s: Shortcut, for key: String) {
        UserDefaults.standard.set(s.keyCode, forKey: key + ".kc")
        UserDefaults.standard.set(Int(bitPattern: s.modifierFlags), forKey: key + ".mf")
        UserDefaults.standard.synchronize()
    }

    private func sync() {
        HotkeyManager.shared.updateShortcuts(
            readText: readText, ocr: ocr, dictate: dictate, smartDictate: smartDictate,
            insertFromMemory: insertFromMemory
        )
    }
}
