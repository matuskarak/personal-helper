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
    private var pendingText = ""   // what Zrušiť / closing the window parks in memory
    private var onAction: (String) -> Void = { _ in }

    /// `onAction` gets what the user did: inserted | edited | original | cancelled | copied.
    func present(text: String, original: String, changes: String, markdown: Bool,
                 onAction: @escaping (String) -> Void) {
        close(parking: false)
        target = NSWorkspace.shared.frontmostApplication
        pendingText = markdown ? RichText.plain(text) : text
        self.onAction = onAction
        let engine = SmartRewriteEngine.shared

        let view = ReviewView(
            text: text, original: original, changes: changes,
            showChanges: engine.reviewShowChanges, showOriginal: engine.reviewShowOriginal,
            onInsert: { [weak self] edited in
                self?.insert(edited, markdown: markdown, action: edited == text ? "inserted" : "edited")
            },
            onInsertOriginal: { [weak self] in self?.insert(original, markdown: false, action: "original") },
            onCopy: { [weak self] edited in
                self?.onAction("copied")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(markdown ? RichText.plain(edited) : edited, forType: .string)
            },
            onCancel: { [weak self] in self?.close(parking: true) }
        )
        let hosting = NSHostingView(rootView: view)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Ozvena — kontrola textu"
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

    private func insert(_ text: String, markdown: Bool, action: String) {
        let app = target
        close(parking: false)
        app?.activate()
        // Give the target a moment to take focus back — ⌘V sent earlier lands in our own app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [onAction] in
            AppLogger.log("[ReviewPanel] vkladám (\(text.count) znakov, \(action))")
            TextInserter.shared.insert(text, markdown: markdown)
            onAction(action)
        }
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

private struct ReviewView: View {
    @State var text: String
    let original: String
    let changes: String
    let showChanges: Bool
    let showOriginal: Bool
    let onInsert: (String) -> Void
    let onInsertOriginal: () -> Void
    let onCopy: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showChanges, !changes.isEmpty {
                Text("AI zmenila: \(changes)")
                    .font(Theme.body(12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // ponytail: Markdown shown as-is (**tučné**) — a rich-text editor when users ask for it.
            TextEditor(text: $text)
                .font(Theme.body(14))
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
            if showOriginal {
                DisclosureGroup("Pôvodný prepis") {
                    Text(original)
                        .font(Theme.body(12)).foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .font(Theme.body(12))
            }
            HStack {
                Button("Zrušiť", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Kopírovať") { onCopy(text) }
                Spacer()
                if showOriginal { Button("Vložiť pôvodný", action: onInsertOriginal) }
                Button("Vložiť  ⌘↩") { onInsert(text) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
            .font(Theme.body(13))
        }
        .padding(20)
        .frame(width: 540)
        .background(Theme.surfaceBase)
    }
}
