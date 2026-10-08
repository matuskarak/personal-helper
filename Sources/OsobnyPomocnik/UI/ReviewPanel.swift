import AppKit
import SwiftUI

/// Smart result shown for checking/editing before it's pasted (SmartRewriteEngine.reviewMode,
/// 2026-09-27). Our app has to become active for the text field to take typing, so the target
/// app is remembered and re-activated before the paste.
@MainActor
final class ReviewPanelController: NSObject, NSWindowDelegate {
    static let shared = ReviewPanelController()

    private var window: NSWindow?
    private var target: NSRunningApplication?
    private var textView: NSTextView?   // the editor — read at insert time, WYSIWYG
    private var onAction: (String) -> Void = { _ in }

    /// `onAction` gets what the user did: inserted | edited | original | cancelled | copied.
    /// `originalTitle`: an edit of selected text shows the selection there, not a transcript.
    func present(text: String, original: String, originalTitle: String = "Pôvodný prepis",
                 changes: String, markdown: Bool,
                 onAction: @escaping (String) -> Void) {
        close(parking: false)
        target = NSWorkspace.shared.frontmostApplication
        self.onAction = onAction
        let engine = SmartRewriteEngine.shared

        // Shows the text exactly as it will be pasted (bold, paragraphs, lists), not Markdown.
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isRichText = markdown
        tv.allowsUndo = true
        // The card behind the editor (Theme.surfaceCard) shows through — no stock white box.
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: ReviewLayout.editorInsetX, height: ReviewLayout.editorInsetY)
        if markdown, let attr = RichText.attributed(text) {
            // Fonts stay as RichText made them — they are what gets pasted (WYSIWYG).
            tv.textStorage?.setAttributedString(attr)
        } else {
            // Plain text pastes without styling, so the editor can use the app's reading font.
            tv.string = text
            tv.font = NSFont(name: "AtkinsonHyperlegible-Regular", size: 14)
                ?? NSFont.systemFont(ofSize: 14)
            tv.textColor = .textColor
            let para = NSMutableParagraphStyle()
            para.lineSpacing = 3
            tv.defaultParagraphStyle = para
            tv.textStorage?.addAttribute(.paragraphStyle, value: para,
                                         range: NSRange(location: 0, length: tv.string.utf16.count))
        }
        textView = tv
        let initial = tv.string

        let view = ReviewView(
            editor: scroll, editorHeight: Self.fittedHeight(of: tv),
            targetName: target?.localizedName,
            original: original, originalTitle: originalTitle, changes: changes,
            showChanges: engine.reviewShowChanges, showOriginal: engine.reviewShowOriginal,
            onInsert: { [weak self] in
                guard let self, let tv = self.textView else { return }
                let action = tv.string == initial ? "inserted" : "edited"
                if markdown {
                    let attr = tv.attributedString()
                    self.insert(action: action) { TextInserter.shared.insert(attributed: attr) }
                } else {
                    let plain = tv.string
                    self.insert(action: action) { TextInserter.shared.insert(plain) }
                }
            },
            onInsertOriginal: { [weak self] in
                self?.insert(action: "original") { TextInserter.shared.insert(original) }
            },
            onCopy: { [weak self] in
                guard let self, let tv = self.textView else { return }
                self.onAction("copied")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([tv.attributedString()])
            },
            onCancel: { [weak self] in self?.close(parking: true) }
        )
        let hosting = NSHostingView(rootView: view)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        // Title stays set for VoiceOver / Mission Control; visually the SwiftUI header replaces it
        // and the app surface runs up under the traffic lights.
        w.title = "Ozvena — kontrola textu"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.backgroundColor = NSColor(Theme.surfaceBase)
        w.contentView = hosting
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
        AppLogger.log("[ReviewPanel] zobrazené (\(text.count) znakov) — cieľ: \(target?.bundleIdentifier ?? "?")")
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func insert(action: String, paste: @escaping () -> Void) {
        let app = target
        close(parking: false)
        app?.activate()
        // Give the target a moment to take focus back — ⌘V sent earlier lands in our own app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [onAction] in
            AppLogger.log("[ReviewPanel] vkladám (\(action))")
            paste()
            onAction(action)
        }
    }

    private var pendingText: String { textView?.string ?? "" }

    /// Editor height that fits the text (no dead space for a two-line reply, no wall for a long
    /// e-mail — past `editorMax` the editor scrolls).
    private static func fittedHeight(of tv: NSTextView) -> CGFloat {
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return ReviewLayout.editorMin }
        tc.containerSize = NSSize(width: ReviewLayout.contentWidth - 2 * ReviewLayout.editorInsetX,
                                  height: .greatestFiniteMagnitude)
        tc.widthTracksTextView = false
        lm.ensureLayout(for: tc)
        tc.widthTracksTextView = true
        let h = ceil(lm.usedRect(for: tc).height) + 2 * ReviewLayout.editorInsetY
        return min(max(h, ReviewLayout.editorMin), ReviewLayout.editorMax)
    }

    /// Cancel never throws the words away — they go to the ⌃⌥V slot like any unplaced text.
    private func close(parking: Bool) {
        guard let w = window else { return }
        window = nil
        w.delegate = nil
        w.close()
        if parking {
            onAction("cancelled")
            DictationMemoryStore.shared.store(pendingText)
            textView = nil
            AppLogger.log("[ReviewPanel] zrušené — text v pamäti (⌃⌥V)")
            target?.activate()
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Red close button = Zrušiť. (Programmatic closes clear the delegate first.)
        guard window != nil else { return }
        window = nil
        onAction("cancelled")
        DictationMemoryStore.shared.store(pendingText)
        AppLogger.log("[ReviewPanel] zavreté — text v pamäti (⌃⌥V)")
        target?.activate()
    }
}

/// One spacing rhythm (8 / 12 / 20) and one radius rule for the whole window:
/// cards 12 (same as Preferences `card()`), buttons + info row + inset blocks 8.
private enum ReviewLayout {
    static let width: CGFloat = 560
    static let pad: CGFloat = 20            // outer padding
    static let gap: CGFloat = 12            // between blocks
    static let contentWidth: CGFloat = width - 2 * pad
    static let editorInsetX: CGFloat = 12
    static let editorInsetY: CGFloat = 10
    static let editorMin: CGFloat = 96
    static let editorMax: CGFloat = 380
    static let cardRadius: CGFloat = 12
    static let controlRadius: CGFloat = 8
    /// Transparent titlebar: the traffic lights sit in this band above the header.
    static let titlebar: CGFloat = 30
}

private struct ReviewView: View {
    let editor: NSScrollView
    let editorHeight: CGFloat
    let targetName: String?
    let original: String
    let originalTitle: String
    let changes: String
    let showChanges: Bool
    let showOriginal: Bool
    let onInsert: () -> Void
    let onInsertOriginal: () -> Void
    let onCopy: () -> Void
    let onCancel: () -> Void

    @State private var originalExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: ReviewLayout.gap) {
            header
            if showChanges, !changes.isEmpty { changesRow }
            HostedView(view: editor)
                .frame(height: editorHeight)
                .background(Theme.surfaceCard)
                .clipShape(RoundedRectangle(cornerRadius: ReviewLayout.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: ReviewLayout.cardRadius)
                    .strokeBorder(Theme.border, lineWidth: 1))
            if showOriginal { originalSection }
            footer.padding(.top, 4)
        }
        .padding(.horizontal, ReviewLayout.pad)
        .padding(.top, ReviewLayout.titlebar)
        .padding(.bottom, ReviewLayout.pad)
        .frame(width: ReviewLayout.width, alignment: .leading)
        .background(Theme.surfaceBase)
        .tint(Theme.brandBlueSafe)
    }

    // MARK: - Blocks

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Skontroluj text pred vložením")
                .font(Theme.title(18))
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if let targetName, !targetName.isEmpty {
                Text("Vloží sa do aplikácie \(targetName)")
                    .font(Theme.body(12.5))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var changesRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.brandBlue)
                .accessibilityHidden(true)
            (Text("AI zmenila: ").font(Theme.bodyBold(12.5))
             + Text(changes).font(Theme.body(12.5)))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: ReviewLayout.controlRadius)
            .fill(Theme.brandBlue.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: ReviewLayout.controlRadius)
            .strokeBorder(Theme.brandBlue.opacity(0.22), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var originalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { originalExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(originalExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    Text(originalTitle).font(Theme.bodyBold(12.5))
                    Spacer()
                }
                .foregroundStyle(Theme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointingHandCursor()
            .accessibilityValue(originalExpanded ? "rozbalené" : "zbalené")

            if originalExpanded {
                Text(original)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: ReviewLayout.controlRadius)
                        .fill(Theme.textPrimary.opacity(0.04)))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: onCancel) {
                HStack(spacing: 6) {
                    Text("Zrušiť")
                    KeyHint("Esc")
                }
            }
            .buttonStyle(ReviewButtonStyle(kind: .quiet))
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Zrušiť")
            .accessibilityHint("Text ostane v pamäti, vložíš ho skratkou Control Option V")

            Button(action: onCopy) {
                Label("Kopírovať", systemImage: "doc.on.doc")
            }
            .buttonStyle(ReviewButtonStyle(kind: .quiet))

            Spacer(minLength: 8)

            if showOriginal {
                Button("Vložiť pôvodný", action: onInsertOriginal)
                    .buttonStyle(ReviewButtonStyle(kind: .secondary))
            }
            Button(action: onInsert) {
                HStack(spacing: 8) {
                    Text("Vložiť")
                    KeyHint("⌘↩", onAccent: true)
                }
            }
            .buttonStyle(ReviewButtonStyle(kind: .primary))
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("Vložiť")
            .accessibilityHint("Skratka Command Enter")
        }
    }
}

/// Small keycap-like hint next to a button label.
private struct KeyHint: View {
    let keys: String
    let onAccent: Bool
    init(_ keys: String, onAccent: Bool = false) { self.keys = keys; self.onAccent = onAccent }
    var body: some View {
        Text(keys)
            .font(Theme.body(12))
            .foregroundStyle(onAccent ? Color.white.opacity(0.9) : Theme.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(onAccent ? Color.white.opacity(0.16) : Theme.textPrimary.opacity(0.06)))
            .accessibilityHidden(true)
    }
}

/// Button hierarchy: one filled primary (brandBlueSafe carries white text in both modes),
/// an outlined secondary, and quiet text buttons for the non-committal actions.
private struct ReviewButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, kind: kind)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let kind: Kind
        @State private var hover = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(kind == .primary ? Theme.bodyBold(13) : Theme.body(13))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, kind == .quiet ? 10 : 14)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: ReviewLayout.controlRadius).fill(fill))
                .overlay {
                    if kind == .secondary {
                        RoundedRectangle(cornerRadius: ReviewLayout.controlRadius)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: ReviewLayout.controlRadius))
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { hover = $0 }
                .pointingHandCursor()
        }

        private var foreground: Color {
            switch kind {
            case .primary: .white
            case .secondary: Theme.textPrimary
            case .quiet: hover ? Theme.textPrimary : Theme.textSecondary
            }
        }

        private var fill: Color {
            let active = hover || configuration.isPressed
            switch kind {
            case .primary: return Theme.brandBlueSafe.opacity(configuration.isPressed ? 0.85 : 1)
            case .secondary: return active ? Theme.textPrimary.opacity(0.06) : Theme.surfaceCard
            case .quiet: return active ? Theme.textPrimary.opacity(0.06) : .clear
            }
        }
    }
}

private struct HostedView: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
