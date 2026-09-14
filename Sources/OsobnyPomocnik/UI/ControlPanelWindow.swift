import AppKit
import SwiftUI
import Observation

// MARK: - Snap positions

enum PanelSnapPosition: String, CaseIterable {
    case topLeft, topCenter, topRight
    case centerLeft, centerRight
    case bottomLeft, bottomCenter, bottomRight

    var label: String {
        switch self {
        case .topLeft:      return "↖  Ľavý horný roh"
        case .topCenter:    return "↑  Horný stred"
        case .topRight:     return "↗  Pravý horný roh"
        case .centerLeft:   return "←  Ľavý kraj"
        case .centerRight:  return "→  Pravý kraj"
        case .bottomLeft:   return "↙  Ľavý dolný roh"
        case .bottomCenter: return "↓  Dolný stred"
        case .bottomRight:  return "↘  Pravý dolný roh"
        }
    }
}

/// Expanded/collapsed lives outside the view so the controller can collapse the pill every
/// time it is shown and size the window to match the content.
@Observable
@MainActor
final class ControlPanelState {
    var expanded = false
}

// MARK: - Window controller

@MainActor
final class ControlPanelWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ControlPanelWindowController()
    let state = ControlPanelState()

    /// Saved as the pill's top-left corner (not origin): expanding grows downward, so the
    /// anchor the user chose stays put across collapse/expand cycles.
    private static let topLeftKey = "controlPanel.topLeft"
    private static let margin: CGFloat = 20

    /// Geometry from Vyvoj/Komponenty/citanie-pilulka.md: 52 pt circle, expanded = circle +
    /// divider + 5 × 40 pt buttons. The shadow is drawn in SwiftUI, so the window keeps a
    /// transparent `shadowPad` margin on every side.
    static let pillWidth: CGFloat = 52
    static let collapsedHeight: CGFloat = 52
    static let expandedHeight: CGFloat = 52 + 9 + 5 * 40 + 5 * 2 + 6   // 277
    static let shadowPad: CGFloat = 12

    private init() {
        // NSPanel + .nonactivatingPanel, not a plain NSWindow — this is the actual fix, not
        // FirstMouseHostingView. On macOS, clicking ANY plain NSWindow of a background app
        // activates that app as a side effect of the window becoming key, independent of
        // acceptsFirstMouse (which only avoids the window server "swallowing" the very first
        // click). .nonactivatingPanel is the one style bit that's documented to suppress that:
        // "the panel does not activate the owning application when brought forward." It must
        // be part of the styleMask passed to init — changing styleMask afterward is a known
        // AppKit/WindowServer desync bug that silently breaks this again. Mirrors
        // DictationIndicatorController's NSPanel, which never had this problem.
        let w = NSPanel(
            contentRect: NSRect(x: 0, y: 0,
                                width: Self.pillWidth + 2 * Self.shadowPad,
                                height: Self.collapsedHeight + 2 * Self.shadowPad),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        w.isFloatingPanel = true
        w.backgroundColor = .clear
        w.isOpaque = false
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.isMovable = true
        w.isMovableByWindowBackground = true
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Floating pills are always dark, whatever the system appearance (client decision
        // 2026-09-11) — pinning the appearance makes the material and semantic colours follow.
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = FirstMouseHostingView(rootView: ControlPanelView(state: state))
        super.init(window: w)
        w.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Show / Hide

    func show() {
        state.expanded = false
        resize(animated: false)
        restoreOrDefaultPosition()
        // makeKeyAndOrderFront, not just orderFront: the panel's Space/Esc keyboard shortcuts
        // (pause/stop) need it to be key to receive key events. For a NORMAL window, becoming
        // key requires — and triggers — app activation; a .nonactivatingPanel is specifically
        // exempted from that, so this brings only the panel forward and lets it receive
        // keystrokes, without activating the app or moving any other of the app's windows
        // (e.g. an open Preferences window stays wherever it was, behind other apps).
        window?.makeKeyAndOrderFront(nil)
    }

    func hide() { window?.orderOut(nil) }
    func showStatus(_ msg: String) { print("[ControlPanel] \(msg)") }

    func toggleExpanded() {
        state.expanded.toggle()
        resize(animated: true)
    }

    /// Screen rect of the pill's speed button — where the "Rýchlosť …" toast anchors.
    var speedButtonFrame: NSRect {
        guard let f = window?.frame else { return .zero }
        // top pad + circle + divider block + 3 buttons above (pause, stop, restart)
        let fromTop = Self.shadowPad + Self.collapsedHeight + 9 + 3 * 42
        return NSRect(x: f.minX + Self.shadowPad, y: f.maxY - fromTop - 40, width: Self.pillWidth, height: 40)
    }

    /// Grows downward from the current top edge; flips to growing upward when the bottom of
    /// the screen is in the way (pill snapped to a bottom corner).
    private func resize(animated: Bool) {
        guard let w = window else { return }
        let h = (state.expanded ? Self.expandedHeight : Self.collapsedHeight) + 2 * Self.shadowPad
        var f = w.frame
        f.origin.y = f.maxY - h
        f.size.height = h
        if let screen = w.screen ?? NSScreen.main, f.minY < screen.visibleFrame.minY {
            f.origin.y = w.frame.minY
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        w.setFrame(f, display: true, animate: animated && !reduceMotion)
    }

    // MARK: Snap

    func snap(to position: PanelSnapPosition) {
        guard let w = window, let screen = NSScreen.main else { return }
        let pt = computeOrigin(position, window: w, screen: screen)
        w.setFrameOrigin(pt)
        saveTopLeft()
    }

    // MARK: NSWindowDelegate — persist after drag

    nonisolated func windowDidMove(_ notification: Notification) {
        Task { @MainActor in self.saveTopLeft() }
    }

    // MARK: Helpers

    private func restoreOrDefaultPosition() {
        guard let w = window, let screen = NSScreen.main else { return }
        if let arr = UserDefaults.standard.array(forKey: Self.topLeftKey) as? [Double], arr.count == 2 {
            let pt = NSPoint(x: arr[0], y: arr[1] - w.frame.height)
            if screen.frame.contains(pt) {
                w.setFrameOrigin(pt)
                return
            }
        }
        w.setFrameOrigin(computeOrigin(.centerRight, window: w, screen: screen))
    }

    private func saveTopLeft() {
        guard let f = window?.frame else { return }
        UserDefaults.standard.set([f.minX, f.maxY], forKey: Self.topLeftKey)
    }

    private func computeOrigin(_ pos: PanelSnapPosition,
                                window w: NSWindow,
                                screen: NSScreen) -> NSPoint {
        let f  = screen.visibleFrame
        let m  = Self.margin
        let ww = w.frame.width
        let wh = w.frame.height
        switch pos {
        case .topLeft:      return NSPoint(x: f.minX + m,       y: f.maxY - wh - m)
        case .topCenter:    return NSPoint(x: f.midX - ww / 2,  y: f.maxY - wh - m)
        case .topRight:     return NSPoint(x: f.maxX - ww - m,  y: f.maxY - wh - m)
        case .centerLeft:   return NSPoint(x: f.minX + m,       y: f.midY - wh / 2)
        case .centerRight:  return NSPoint(x: f.maxX - ww - m,  y: f.midY - wh / 2)
        case .bottomLeft:   return NSPoint(x: f.minX + m,       y: f.minY + m)
        case .bottomCenter: return NSPoint(x: f.midX - ww / 2,  y: f.minY + m)
        case .bottomRight:  return NSPoint(x: f.maxX - ww - m,  y: f.minY + m)
        }
    }
}

// MARK: - Voice wave

private struct VoiceWaveView: View {
    let isActive: Bool

    private static let barCount = 4
    private static let flatHeights: [CGFloat] = Array(repeating: 3, count: barCount)
    private static let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    @State private var heights: [CGFloat] = flatHeights

    private let ticker = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<Self.barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.HUD.blue)
                    .frame(width: 3, height: heights[i])
                    .animation(.easeInOut(duration: 0.15), value: heights[i])
            }
        }
        .frame(width: 24, height: 18)
        .onReceive(ticker) { _ in
            guard isActive else {
                // ponytail: same trap as the dictation pill's equalizer — this window's
                // hosting view outlives any single playback, so re-assigning the identical
                // flat array kept invalidating @State (and re-laying-out the panel) forever
                // while nothing was being read aloud.
                if heights != Self.flatHeights { heights = Self.flatHeights }
                return
            }
            // Reduce Motion: a steady "playing" shape instead of the pulsing bars.
            let next = Self.reduceMotion ? [9, 15, 11, 7] : (0..<Self.barCount).map { _ in CGFloat.random(in: 4...16) }
            if heights != next { heights = next }
        }
        .onChange(of: isActive) { _, active in
            if !active {
                withAnimation(.easeInOut(duration: 0.18)) {
                    heights = Self.flatHeights
                }
            }
        }
    }
}

// MARK: - Main view

struct ControlPanelView: View {
    /// citanie-pilulka.md: "0.28s cubic-bezier(.2,.8,.2,1)". `nil` under Reduce Motion —
    /// the window resize (`resize(animated:)`) checks the same flag so both stay in sync.
    static let expandAnim: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.28)
    let state: ControlPanelState
    @State private var tts   = TTSEngine.shared
    @State private var store = RecentTextStore.shared
    @State private var triggerHovered = false

    /// Currently running auto-hide countdown (cancelled on interaction / when speaking starts)
    @State private var autoHideTask: Task<Void, Never>?

    // Reads the user preference; 0 = nikdy (never)
    private var autoHideSecs: Int {
        let v = UserDefaults.standard.object(forKey: "controlPanel.autoHideSecs")
        return v as? Int ?? 60   // default: 1 minúta
    }

    private typealias C = ControlPanelWindowController
    private let radius = ControlPanelWindowController.pillWidth / 2   // circle when collapsed

    var body: some View {
        VStack(spacing: 0) {
            trigger
            controls
        }
        .frame(width: C.pillWidth,
               height: state.expanded ? C.expandedHeight : C.collapsedHeight,
               alignment: .top)
        .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                Theme.HUD.background
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.HUD.border, lineWidth: 1))
        .shadow(color: Theme.HUD.shadow, radius: 15, y: 7)
        .padding(C.shadowPad)
        .animation(.easeOut(duration: 0.22), value: state.expanded)
        .contextMenu {
            Text("Pozícia pilulky")
            Divider()
            ForEach(PanelSnapPosition.allCases, id: \.self) { pos in
                Button(pos.label) {
                    ControlPanelWindowController.shared.snap(to: pos)
                }
            }
        }
        // Start timer when panel appears (if not speaking)
        .onAppear { scheduleAutoHide() }
        // When speaking ends → start timer; when starts → cancel
        .onChange(of: tts.isSpeaking) { _, speaking in
            speaking ? autoHideTask?.cancel() : scheduleAutoHide()
        }
    }

    /// The whole circle is the click target — no chevron (designed and rejected by the client).
    private var trigger: some View {
        Button {
            ControlPanelWindowController.shared.toggleExpanded()
            resetAutoHide()
        } label: {
            VoiceWaveView(isActive: tts.isSpeaking && !tts.isPaused)
                .frame(width: C.pillWidth, height: C.collapsedHeight)
                .background(triggerHovered ? Color.white.opacity(0.05) : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointingHandCursor()
        .onHover { triggerHovered = $0 }
        .accessibilityLabel(state.expanded ? "Ovládanie čítania, rozbalené" : "Ovládanie čítania, zbalené")
        .accessibilityHint(state.expanded ? "Kliknutím zbalíš tlačidlá" : "Kliknutím rozbalíš tlačidlá")
    }

    /// Always in the hierarchy (clipped away when collapsed) so Space/Esc keep working.
    private var controls: some View {
        VStack(spacing: 2) {
            Rectangle().fill(Theme.HUD.divider).frame(width: 28, height: 1).padding(.vertical, 4)

            HUDButton(icon: tts.isPaused ? "play.fill" : "pause.fill",
                      label: tts.isPaused ? "Pokračovať (Space)" : "Pozastaviť (Space)",
                      disabled: !tts.isSpeaking,
                      shortcut: KeyboardShortcut(.space, modifiers: [])) {
                tts.isPaused ? tts.resume() : tts.pause(); resetAutoHide()
            }
            HUDButton(icon: "stop.fill", label: "Zastaviť (Esc)", disabled: !tts.isSpeaking,
                      shortcut: KeyboardShortcut(.escape, modifiers: [])) {
                tts.stop(); resetAutoHide()
            }
            HUDButton(icon: "arrow.counterclockwise", label: "Čítať od začiatku",
                      disabled: store.lastText == nil) {
                tts.replayLast(); resetAutoHide()
            }
            HUDButton(text: TTSEngine.format(tts.speed),
                      label: "Rýchlosť čítania \(TTSEngine.format(tts.speed)), kliknutím prepneš na ďalšiu") {
                let next = tts.cycleSpeed()
                HUDToast.show("Rýchlosť \(TTSEngine.format(next))",
                              leftOf: ControlPanelWindowController.shared.speedButtonFrame)
                resetAutoHide()
            }
            HUDButton(icon: "xmark", label: "Zavrieť", muted: true) {
                autoHideTask?.cancel(); tts.stop(); ControlPanelWindowController.shared.hide()
            }
        }
        .padding(.bottom, 6)
        .accessibilityHidden(!state.expanded)
    }

    // MARK: - Auto-hide

    private func scheduleAutoHide() {
        let secs = autoHideSecs
        guard secs > 0, !tts.isSpeaking else { return }
        autoHideTask?.cancel()
        autoHideTask = Task {
            try? await Task.sleep(for: .seconds(secs))
            guard !Task.isCancelled else { return }
            ControlPanelWindowController.shared.hide()
        }
    }

    private func resetAutoHide() {
        scheduleAutoHide()
    }
}

// MARK: - Button

/// 40×40 icon (or short text) button from the pill spec: no chrome at rest, tinted
/// background + brighter glyph on hover, all glyphs share one style.
private struct HUDButton: View {
    var icon: String? = nil
    var text: String? = nil
    let label: String
    var disabled = false
    var muted = false
    var shortcut: KeyboardShortcut? = nil
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        let lit = hovered && !disabled
        let btn = Button(action: action) {
            Group {
                if let icon {
                    Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                } else {
                    Text(text ?? "").font(Theme.bodyBold(13))
                }
            }
            .foregroundStyle(lit ? Theme.HUD.text : (muted ? Theme.HUD.iconMuted : Theme.HUD.icon))
            .frame(width: 40, height: 40)
            .background(RoundedRectangle(cornerRadius: 12).fill(lit ? Theme.HUD.hover : .clear))
            .contentShape(Rectangle())
            .opacity(disabled ? 0.35 : 1)
        }
        .buttonStyle(.plain).pointingHandCursor()
        .disabled(disabled)
        .help(label)
        .accessibilityLabel(label)
        .onHover { hovered = $0 }

        if let shortcut { btn.keyboardShortcut(shortcut) } else { btn }
    }
}

// MARK: - Toast

/// Short-lived confirmation bubble beside a HUD pill ("Rýchlosť 1.25×"). Its own tiny panel:
/// the pill window is exactly pill-sized and a wider transparent window would swallow clicks.
@MainActor
enum HUDToast {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(_ text: String, leftOf anchor: NSRect, for duration: Duration = .milliseconds(1100)) {
        hideTask?.cancel()
        let content = NSHostingView(rootView:
            Text(text)
                .font(Theme.bodyBold(12))
                .foregroundStyle(Theme.HUD.text)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.HUD.background))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.HUD.border, lineWidth: 1))
                .shadow(color: Theme.HUD.shadow, radius: 10, y: 4)
                .padding(10)
        )
        let p = panel ?? makePanel()
        panel = p
        p.contentView = content
        let size = content.fittingSize
        p.setContentSize(size)
        var x = anchor.minX - size.width + 2
        if let screen = NSScreen.main, x < screen.visibleFrame.minX { x = anchor.maxX - 2 }   // pill at left edge → toast on the right
        p.setFrameOrigin(NSPoint(x: x, y: anchor.midY - size.height / 2))
        p.orderFront(nil)
        hideTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            p.orderOut(nil)
        }
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.level = .floating
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.appearance = NSAppearance(named: .darkAqua)
        return p
    }
}
