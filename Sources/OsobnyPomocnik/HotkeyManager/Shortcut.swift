import AppKit

// MARK: - Model

struct Shortcut: Codable, Equatable, Sendable {
    var keyCode: Int
    var modifierFlags: UInt  // NSEvent.ModifierFlags rawValue

    // MARK: Defaults
    static let defaultReadText    = Shortcut(keyCode: 15, modifierFlags: [.command, .shift])
    static let defaultOCR         = Shortcut(keyCode: 31, modifierFlags: [.command, .shift])
    // Dictation scheme: the START shortcut picks the transcription mode (S = realtime,
    // D = record-then-transcribe), the STOP shortcut picks the processing (same key = raw
    // insert, A = Smart rewrite). See AppDelegate.handleDictate/handleSmartStop.
    static let defaultDictateRealtime = Shortcut(keyCode: 1, modifierFlags: [.command, .shift])  // S
    static let defaultDictateBatch    = Shortcut(keyCode: 2, modifierFlags: [.command, .shift])  // D
    static let defaultSmartStop       = Shortcut(keyCode: 0, modifierFlags: [.command, .shift])  // A
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
            51:"⌫",53:"⎋",123:"←",124:"→",125:"↓",126:"↑",
            // Top-row digits
            18:"1",19:"2",20:"3",21:"4",23:"5",22:"6",26:"7",28:"8",25:"9",29:"0",
            // Numeric keypad — labelled distinctly since it's a different physical key
            // than the top-row digit with the same face value (different keyCode).
            82:"Num0",83:"Num1",84:"Num2",85:"Num3",86:"Num4",87:"Num5",
            88:"Num6",89:"Num7",91:"Num8",92:"Num9",
            65:"Num.",67:"Num*",69:"Num+",75:"Num/",76:"NumEnter",78:"Num-",81:"Num="
        ]
        if let name = map[keyCode] { return name }
        if let f = fKeyNumber(forKeyCode: keyCode) { return "F\(f)" }
        return "?"
    }

    // MARK: - Function keys
    // macOS's virtual keycode set only goes up to F20 — there's no defined keycode for F21+,
    // so that's the real ceiling here regardless of how many F-keys a keyboard claims to have.
    private static let fKeyCodes: [Int: Int] = [
        1:122, 2:120, 3:99, 4:118, 5:96, 6:97, 7:98, 8:100, 9:101, 10:109,
        11:103, 12:111, 13:105, 14:107, 15:113, 16:106, 17:64, 18:79, 19:80, 20:90
    ]
    static func fKeyCode(_ n: Int) -> Int { fKeyCodes[n] ?? fKeyCodes[1]! }
    private static func fKeyNumber(forKeyCode kc: Int) -> Int? {
        fKeyCodes.first(where: { $0.value == kc })?.key
    }
}

// MARK: - Store

/// Each action can have several shortcuts mapped to it (e.g. a laptop-keyboard combo and a
/// separate external-keyboard combo) — up to `maxPerAction`. Index 0 is the "primary" one shown
/// first; any of the list triggers the action.
@MainActor
final class ShortcutStore {
    static let shared = ShortcutStore()
    private init() {}

    static let maxPerAction = 3

    enum Action: String, CaseIterable {
        case readText, ocr, dictateRealtime, dictateBatch, smartStop, insertFromMemory

        var defaultShortcut: Shortcut {
            switch self {
            case .readText:         .defaultReadText
            case .ocr:               .defaultOCR
            case .dictateRealtime:  .defaultDictateRealtime
            case .dictateBatch:     .defaultDictateBatch
            case .smartStop:        .defaultSmartStop
            case .insertFromMemory:  .defaultInsertFromMemory
            }
        }

        /// Pre-mode-split storage key whose stored list this action inherits, if any.
        /// ponytail: the old generic `dictate` list is deliberately NOT migrated — mapping
        /// it onto one of the two new mode actions would collide with the other one's
        /// default (both defaulted to ⌘⇧D historically). New defaults S/D/A apply instead;
        /// a custom smart shortcut carries over to smartStop, same gesture, new meaning.
        fileprivate var legacyRawValue: String? {
            self == .smartStop ? "smartDictate" : nil
        }
    }

    func shortcuts(for action: Action) -> [Shortcut] {
        if let list = storedList(rawValue: action.rawValue) { return list }
        if let legacy = action.legacyRawValue, let list = storedList(rawValue: legacy) { return list }
        return [action.defaultShortcut]
    }

    private func storedList(rawValue: String) -> [Shortcut]? {
        if let data = UserDefaults.standard.data(forKey: "sc.\(rawValue).list"),
           let list = try? JSONDecoder().decode([Shortcut].self, from: data),
           !list.isEmpty {
            return Array(list.prefix(Self.maxPerAction))
        }
        // Migrate the old single-shortcut keys (sc.<action>.kc/.mf) if present.
        let legacyKey = "sc.\(rawValue)"
        if UserDefaults.standard.object(forKey: legacyKey + ".kc") != nil,
           UserDefaults.standard.object(forKey: legacyKey + ".mf") != nil {
            let kc = UserDefaults.standard.integer(forKey: legacyKey + ".kc")
            let mf = UInt(bitPattern: UserDefaults.standard.integer(forKey: legacyKey + ".mf"))
            return [Shortcut(keyCode: kc, rawModifiers: mf)]
        }
        return nil
    }

    func setShortcuts(_ list: [Shortcut], for action: Action) {
        let clamped = Array(list.prefix(Self.maxPerAction))
        guard let data = try? JSONEncoder().encode(clamped) else { return }
        UserDefaults.standard.set(data, forKey: "sc.\(action.rawValue).list")
        sync()
    }

    func resetAllToDefaults() {
        for action in Action.allCases {
            // Write the default explicitly rather than just removing the key — shortcuts(for:)
            // falls back to legacy pre-migration keys when the list key is absent, which would
            // resurrect an old custom shortcut instead of actually resetting to default.
            setShortcuts([action.defaultShortcut], for: action)
        }
    }

    /// Pushes the persisted shortcuts into HotkeyManager — must run once at launch (the
    /// manager's cache otherwise stays at hardcoded defaults until the user opens Preferences
    /// and edits something) and again after every edit.
    func sync() {
        HotkeyManager.shared.updateShortcuts(
            readText: shortcuts(for: .readText),
            ocr: shortcuts(for: .ocr),
            dictateRealtime: shortcuts(for: .dictateRealtime),
            dictateBatch: shortcuts(for: .dictateBatch),
            smartStop: shortcuts(for: .smartStop),
            insertFromMemory: shortcuts(for: .insertFromMemory)
        )
    }
}
