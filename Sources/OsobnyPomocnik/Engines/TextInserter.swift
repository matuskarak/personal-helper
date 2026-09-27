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
    func insertOrRemember(_ text: String, markdown: Bool = false) -> InsertOutcome {
        // Memory (⌃⌥V) pastes plain text — keep it free of Markdown markers.
        let remembered = markdown ? RichText.plain(text) : text
        switch FocusValidator.hasEditableFocus() {
        case false:
            DictationMemoryStore.shared.store(remembered)
            AppLogger.log("[TextInserter] No editable field focused — saved \(text.count) chars to memory")
            return .savedToMemory
        case nil:
            // Can't tell — paste, and keep a copy in case the paste went nowhere.
            DictationMemoryStore.shared.store(remembered)
            AppLogger.log("[TextInserter] focus neznámy — vkladám a kópiu nechávam v pamäti (⌃⌥V)")
        case true:
            break
        }
        insert(text, markdown: markdown)
        return .inserted
    }

    @MainActor
    func insert(_ text: String, markdown: Bool = false) {
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
        var setOK: Bool
        if markdown {
            // Browsers take HTML, native editors (Mail, Notes, Word) RTF, plain fields the text.
            setOK = pasteboard.setString(RichText.plain(text), forType: .string)
            pasteboard.setString(RichText.html(text), forType: .html)
            if let rtf = RichText.rtf(text) { pasteboard.setData(rtf, forType: .rtf) }
        } else {
            setOK = pasteboard.setString(text, forType: .string)
        }
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

// MARK: - Markdown → rich paste

/// The Markdown subset Smart formatting emits (AppCategory.formattingRules): **bold**,
/// "- " / "1. " lists, "#" headings, blank-line paragraphs. Nothing else is interpreted.
enum RichText {
    static func html(_ md: String) -> String {
        var out: [String] = []
        var list: String?   // "ul" / "ol" while inside a list
        var para: [String] = []
        func flushPara() { if !para.isEmpty { out.append("<p>\(para.joined(separator: "<br>"))</p>"); para = [] } }
        func closeList() { if let l = list { out.append("</\(l)>"); list = nil } }

        for raw in md.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let item = listItem(line)
            if let item {
                flushPara()
                if list != item.tag { closeList(); out.append("<\(item.tag)>"); list = item.tag }
                out.append("<li>\(inline(item.text))</li>")
            } else if line.hasPrefix("#") {
                flushPara(); closeList()
                out.append("<h3>\(inline(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))</h3>")
            } else if line.isEmpty {
                flushPara(); closeList()
            } else {
                closeList(); para.append(inline(line))
            }
        }
        flushPara(); closeList()
        return "<meta charset=\"utf-8\"><div style=\"font-family: -apple-system, Helvetica, sans-serif\">"
            + out.joined() + "</div>"
    }

    static func plain(_ md: String) -> String {
        md.components(separatedBy: "\n").map { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            var text = line.hasPrefix("#") ? line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) : raw
            if line.hasPrefix("- ") || line.hasPrefix("* ") { text = "• " + line.dropFirst(2) }
            return text.replacingOccurrences(of: "**", with: "")
        }.joined(separator: "\n")
    }

    /// RTF with the system font — HTML imported by AppKit would otherwise come out in Times.
    @MainActor
    static func rtf(_ md: String) -> Data? {
        guard let data = html(md).data(using: .utf8),
              let attr = try? NSMutableAttributedString(data: data, options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        else { return nil }
        let full = NSRange(location: 0, length: attr.length)
        attr.enumerateAttribute(.font, in: full) { value, range, _ in
            let old = value as? NSFont
            let bold = old?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
            let size = (old?.pointSize ?? 12) > 14 ? 15.0 : NSFont.systemFontSize   // <h3> stays a bit larger
            attr.addAttribute(.font, value: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size), range: range)
        }
        return try? attr.data(from: full, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    private static func listItem(_ line: String) -> (tag: String, text: String)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") { return ("ul", String(line.dropFirst(2))) }
        if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
           line[line.index(after: dot)...].hasPrefix(" ") {
            return ("ol", String(line[line.index(dot, offsetBy: 2)...]))
        }
        return nil
    }

    private static func inline(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return escaped.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<b>$1</b>", options: .regularExpression)
    }

    #if DEBUG
    static func selfCheck() {
        let h = html("Ahoj Peter,\n\nCena je **12 000 €**.\n- a\n- b\n1. x")
        assert(h.contains("<b>12 000 €</b>"), "bold")
        assert(h.contains("<ul><li>a</li><li>b</li></ul><ol><li>x</li></ol>"), "lists, switch ul→ol")
        assert(h.contains("<p>Ahoj Peter,</p>"), "paragraph")
        assert(html("a < b").contains("a &lt; b"), "escaping")
        assert(plain("## Nadpis\n- **a**") == "Nadpis\n• a", "plain strips markers")
        AppLogger.log("[RichText] selfCheck OK")
    }
    #endif
}
