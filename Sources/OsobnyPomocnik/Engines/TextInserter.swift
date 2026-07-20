import Cocoa

enum InsertOutcome {
    case inserted
    case savedToMemory
}

/// Inserts text into the currently active field by placing it on the pasteboard and simulating ⌘V.
final class TextInserter: Sendable {
    static let shared = TextInserter()
    private init() {}

    /// Inserts into the focused editable field if one exists right now; otherwise
    /// saves the text to DictationMemoryStore instead of pasting into nothing.
    @MainActor
    func insertOrRemember(_ text: String) -> InsertOutcome {
        guard FocusValidator.hasEditableFocus() else {
            DictationMemoryStore.shared.store(text)
            AppLogger.log("[TextInserter] No editable field focused — saved \(text.count) chars to memory")
            return .savedToMemory
        }
        insert(text)
        return .inserted
    }

    @MainActor
    func insert(_ text: String) {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let axTrusted = AXIsProcessTrusted()
        AppLogger.log("[TextInserter] insert(\(text.count) chars) — frontmost: \(frontApp?.localizedName ?? "?") (\(frontApp?.bundleIdentifier ?? "?")), AXTrusted: \(axTrusted)")

        let pasteboard = NSPasteboard.general
        // Save current clipboard
        let savedTypes = pasteboard.types ?? []
        let savedData: [(NSPasteboard.PasteboardType, Data)] = savedTypes.compactMap { type in
            pasteboard.data(forType: type).map { (type, $0) }
        }

        // Put dictated text on clipboard
        pasteboard.clearContents()
        let setOK = pasteboard.setString(text, forType: .string)
        AppLogger.log("[TextInserter] pasteboard.setString success: \(setOK), changeCount: \(pasteboard.changeCount)")

        // Simulate ⌘V
        let src = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 9 /* V */, keyDown: true)
        let keyUp   = CGEvent(keyboardEventSource: src, virtualKey: 9,         keyDown: false)
        guard keyDown != nil, keyUp != nil else {
            AppLogger.log("[TextInserter] ⚠️ Failed to create CGEvent for ⌘V — Accessibility permission likely missing/revoked")
            return
        }
        keyDown?.flags = .maskCommand
        keyUp?.flags   = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
        AppLogger.log("[TextInserter] ⌘V posted")

        // Restore clipboard after a delay long enough for the target app to actually
        // process the paste before we put the user's original clipboard content back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSPasteboard.general.clearContents()
            for (type, d) in savedData {
                NSPasteboard.general.setData(d, forType: type)
            }
            AppLogger.log("[TextInserter] clipboard restored")
        }
    }

    /// Types text directly into the focused field via CGEvent Unicode injection — no clipboard used.
    /// Works universally (native + browser). Used for realtime live-insert deltas.
    @MainActor
    func typeText(_ text: String) {
        let utf16 = Array(text.utf16)
        guard !utf16.isEmpty else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
        down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Sends n backspace events — used to erase live-inserted text before a correction paste.
    @MainActor
    func deleteChars(_ n: Int) {
        guard n > 0 else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<n {
            let down = CGEvent(keyboardEventSource: src, virtualKey: 51 /* kVK_Delete */, keyDown: true)
            let up   = CGEvent(keyboardEventSource: src, virtualKey: 51,                  keyDown: false)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
        AppLogger.log("[TextInserter] deleteChars(\(n)) — live-insert correction")
    }
}
