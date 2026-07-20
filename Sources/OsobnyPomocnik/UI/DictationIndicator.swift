import AppKit
import SwiftUI

/// Persisted pill placement — a manually dragged position takes over from the
/// "always centered" default until the user resets it in Preferences.
enum PillPosition {
    private static let followKey = "indicator.followFocusedField"
    private static let xKey = "indicator.customX"
    private static let yKey = "indicator.customY"

    static var followFocusedField: Bool {
        get { UserDefaults.standard.bool(forKey: followKey) }
        set { UserDefaults.standard.set(newValue, forKey: followKey) }
    }

    static var custom: CGPoint? {
        get {
            guard UserDefaults.standard.object(forKey: xKey) != nil else { return nil }
            return CGPoint(x: UserDefaults.standard.double(forKey: xKey),
                            y: UserDefaults.standard.double(forKey: yKey))
        }
        set {
            if let p = newValue {
                UserDefaults.standard.set(p.x, forKey: xKey)
                UserDefaults.standard.set(p.y, forKey: yKey)
            } else {
                UserDefaults.standard.removeObject(forKey: xKey)
                UserDefaults.standard.removeObject(forKey: yKey)
            }
        }
    }

    static func reset() { custom = nil }
}

/// Small floating window shown during active dictation.
@MainActor
final class DictationIndicatorController: NSWindowController, NSWindowDelegate {
    static let shared = DictationIndicatorController()

    // Guards windowDidMove so our own auto-centering/follow-field repositioning
    // isn't mistaken for a user drag and saved as a custom position.
    private var isProgrammaticMove = false

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 90),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false // shadow is drawn inside SwiftUI; the native window shadow was a rectangular halo around our rounded card
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true // drag anywhere on the pill to reposition
        let hostingView = NSHostingView(rootView: DictationIndicatorView())
        hostingView.sizingOptions = [.preferredContentSize]
        window.contentView = hostingView
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(from caller: String = #function) {
        AppLogger.log("[Indicator] show() ← \(caller) | window visible: \(window?.isVisible == true)")
        reposition()
        window?.orderFront(nil)
    }

    func hide(from caller: String = #function) {
        let e = DictationEngine.shared
        AppLogger.log("[Indicator] hide() ← \(caller) | isRecording=\(e.isRecording) isMicReady=\(e.isMicReady) btNeg=\(e.btNegotiating) err=\(e.connectionError ?? "nil")")
        window?.orderOut(nil)
    }

    // MARK: - Positioning

    /// The monitor the user is actually looking at — the screen under the mouse
    /// cursor, since this menu-bar app has no key window to derive it from.
    private func activeScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func centeredOrigin(on screen: NSScreen, size: NSSize) -> NSPoint {
        NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + 80)
    }

    private func applyPosition(_ origin: NSPoint) {
        isProgrammaticMove = true
        window?.setFrameOrigin(origin)
        isProgrammaticMove = false
    }

    private func reposition() {
        guard let window else { return }
        let size = window.frame.size

        if PillPosition.followFocusedField, let axFrame = FocusValidator.focusedElementFrame() {
            // Flip AX's top-left/Y-down space into AppKit's bottom-left/Y-up space.
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let fieldFrame = CGRect(x: axFrame.origin.x,
                                     y: primaryHeight - axFrame.origin.y - axFrame.height,
                                     width: axFrame.width, height: axFrame.height)
            let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: fieldFrame.midX, y: fieldFrame.midY)) }) ?? activeScreen()
            var x = fieldFrame.midX - size.width / 2
            var y = fieldFrame.maxY + 10
            if let screen {
                x = min(max(x, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
                y = min(y, screen.frame.maxY - size.height - 8)
            }
            applyPosition(NSPoint(x: x, y: y))
            return
        }

        if let custom = PillPosition.custom {
            // Saved position may belong to a monitor that's since been unplugged.
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -50, dy: -50).contains(custom) }) {
                applyPosition(custom)
                return
            }
            PillPosition.reset()
        }

        if let screen = activeScreen() {
            applyPosition(centeredOrigin(on: screen, size: size))
        }
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowDidMove(_ notification: Notification) {
        Task { @MainActor in
            guard !isProgrammaticMove, let window else { return }
            PillPosition.custom = window.frame.origin
        }
    }
}

// MARK: - Mic with built-in level equalizer

private struct MicEqualizerView: View {
    let isActive: Bool
    let tint: Color    // caller decides based on voice detection

    private static let barCount = 4
    private static let maxBarHeight: CGFloat = 15

    @State private var heights: [CGFloat] = Array(repeating: 3, count: barCount)
    // ponytail: static — prevents re-renders (every 16ms from audioLevel) from resetting
    // the subscription before the timer fires. Reading audioLevel directly inside the closure
    // (not as a captured `let` param) avoids stale-closure: the timer always gets the fresh value.
    private static let ticker = Timer.publish(every: 0.035, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.14))
                .frame(width: 30, height: 30)
            Circle()
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
                .frame(width: 30, height: 30)
            HStack(spacing: 2.5) {
                ForEach(0..<Self.barCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.2)
                        .fill(tint)
                        .frame(width: 2.5, height: heights[i])
                        .animation(.easeInOut(duration: 0.08), value: heights[i])
                }
            }
        }
        .frame(width: 30, height: 30)
        .animation(.easeInOut(duration: 0.25), value: tint == .blue)
        .onReceive(Self.ticker) { _ in
            guard isActive else {
                heights = Array(repeating: 3, count: Self.barCount)
                return
            }
            let base = CGFloat(DictationEngine.shared.audioLevel) * Self.maxBarHeight
            heights = (0..<Self.barCount).map { _ in
                max(3, min(Self.maxBarHeight, base * CGFloat.random(in: 0.55...1.2)))
            }
        }
    }
}

// MARK: - Main view

struct DictationIndicatorView: View {
    @State private var engine = DictationEngine.shared

    private static let lineHeight: CGFloat = 18
    private static let maxLines = 4

    // Rolling noise floor: min level over ~2s window (28 ticks × 70ms). Color turns blue
    // only when current level is clearly above the ambient baseline — not just any sound.
    @State private var levelHistory: [Float] = Array(repeating: 0, count: 28)
    @State private var historyIndex = 0

    private var equalizerTint: Color {
        let floor = levelHistory.min() ?? 0
        return engine.audioLevel > max(0.12, floor * 3.0) ? .blue : .red
    }

    /// Compact mode: live-insert active → no transcript needed in popup (it's already in the field).
    private var isCompact: Bool {
        engine.liveInsertEnabled && engine.liveInsertActive
    }

    /// Rough line-wrap estimate (chars-per-line at this pill's width/font) so the
    /// scroll box grows 1→4 lines with the text instead of jumping straight to the cap.
    private static func visibleLines(for text: String) -> Int {
        let charsPerLine = 45
        return min(maxLines, max(1, Int(ceil(Double(text.count) / Double(charsPerLine)))))
    }

    private static let levelTicker = Timer.publish(every: 0.07, on: .main, in: .common).autoconnect()

    var body: some View {
        pillContent
            .onReceive(Self.levelTicker) { _ in
                levelHistory[historyIndex] = engine.audioLevel
                historyIndex = (historyIndex + 1) % levelHistory.count
            }
            .background(RoundedRectangle(cornerRadius: 20).fill(.regularMaterial))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
            .padding(10)
            .animation(.easeInOut(duration: 0.2), value: isCompact)
            .onChange(of: engine.connectionError) { _, err in
                AppLogger.log("[Indicator] connectionError changed → \(err ?? "nil") | isRecording=\(engine.isRecording)")
                guard err != nil else { return }
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    // Guard: a new session may have started and cleared the error — don't hide it.
                    guard engine.connectionError != nil else {
                        AppLogger.log("[Indicator] connectionError auto-hide cancelled — error already cleared (new session started)")
                        return
                    }
                    AppLogger.log("[Indicator] connectionError auto-hide firing (3s elapsed) | isRecording=\(engine.isRecording)")
                    DictationIndicatorController.shared.hide(from: "connectionError-onChange")
                }
            }
            .onChange(of: engine.notice) { _, notice in
                AppLogger.log("[Indicator] notice changed → \(notice ?? "nil") | isRecording=\(engine.isRecording)")
                guard notice != nil else { return }
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    guard engine.notice != nil else {
                        AppLogger.log("[Indicator] notice auto-hide cancelled — notice already cleared (new session started)")
                        return
                    }
                    AppLogger.log("[Indicator] notice auto-hide firing (4s elapsed) | isRecording=\(engine.isRecording)")
                    DictationIndicatorController.shared.hide(from: "notice-onChange")
                }
            }
            .onChange(of: engine.isRecording) { _, recording in
                AppLogger.log("[Indicator] isRecording → \(recording) | isMicReady=\(engine.isMicReady) btNeg=\(engine.btNegotiating) compact=\(engine.liveInsertEnabled && engine.liveInsertActive)")
            }
            .onChange(of: engine.isMicReady) { _, ready in
                AppLogger.log("[Indicator] isMicReady → \(ready) | btNeg=\(engine.btNegotiating) compact=\(engine.liveInsertEnabled && engine.liveInsertActive)")
            }
            .onChange(of: engine.btNegotiating) { _, neg in
                AppLogger.log("[Indicator] btNegotiating → \(neg)")
            }
    }

    @ViewBuilder
    private var pillContent: some View {
        if isCompact {
            // Live-insert mode: just the equalizer bubble — transcript is in the field
            MicEqualizerView(isActive: engine.isRecording, tint: equalizerTint)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        } else {
            HStack(spacing: 12) {
                if engine.isRewriting {
                    ProgressView().controlSize(.small)
                    Text("Spracovávam s kontextom…")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if engine.isTranscribing {
                    ProgressView().controlSize(.small)
                    Text("Vkladám…")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let err = engine.connectionError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .frame(width: 18)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let notice = engine.notice {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .foregroundStyle(.orange)
                        .frame(width: 18)
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !engine.isMicReady {
                    ProgressView().controlSize(.small)
                    Text(engine.btNegotiating ? "Inicializujem Bluetooth…" : "Pripájam mikrofón…")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    MicEqualizerView(isActive: engine.isRecording, tint: equalizerTint)

                    if engine.liveText.isEmpty {
                        if engine.isWaitingForServer {
                            ProgressView().controlSize(.small)
                            Text("Čakám na server…")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("Počúvam…")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        // ponytail: real ScrollView, full text (no truncation). The earlier
                        // break was `.fixedSize` overriding the parent's height constraint —
                        // an explicit `.frame(height:)` instead grows 1→4 lines with the text
                        // and only scrolls (smoothly, bottom-anchored) past the cap.
                        ScrollView {
                            Text(engine.liveText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .defaultScrollAnchor(.bottom)
                        .scrollIndicators(.hidden)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: CGFloat(Self.visibleLines(for: engine.liveText)) * Self.lineHeight)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(width: 300)
            .frame(maxHeight: 90)
            .animation(.easeInOut(duration: 0.15), value: engine.liveText)
        }
    }
}
