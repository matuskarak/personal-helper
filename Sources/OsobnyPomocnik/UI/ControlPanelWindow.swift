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
    /// Set by the controller's resize() whenever it decides a direction — mirrored here so the
    /// view can keep the trigger circle visually fixed and unfurl the buttons the other way
    /// instead of letting the whole stack (trigger included) slide to a new screen position.
    var growsUpward = false
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

    /// Window origin captured at the start of a trigger-circle drag — see `dragPanel()`.
    private var dragStartOrigin: NSPoint?

    /// Geometry from Vyvoj/Komponenty/citanie-pilulka.md: 52 pt circle, expanded = circle +
    /// divider + 5 × 40 pt buttons. The shadow is drawn in SwiftUI, so the window keeps a
    /// transparent `shadowPad` margin on every side.
    static let pillWidth: CGFloat = 52
    static let collapsedHeight: CGFloat = 52
    static let expandedHeight: CGFloat = 52 + 9 + 5 * 40 + 5 * 2 + 6   // 277
    // Must cover the shadow's actual bleed (radius 15, y 7 → up to 22pt below the shape),
    // or the window clips it into a hard-edged square — same bug as the dictation pill.
    static let shadowPad: CGFloat = 22
    /// Slowed from the citanie-pilulka.md spec's 0.28s (client felt it too snappy/jumpy,
    /// 2026-09-14) — kept as one constant so the window (`resize`) and content
    /// (`ControlPanelView.expandAnim`) never drift apart again.
    static let expandDuration: TimeInterval = 0.4

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

    // MARK: Trigger drag (click-vs-drag disambiguation)

    /// `isMovableByWindowBackground` alone can't be used on the trigger circle itself: AppKit
    /// moves the window under the cursor as the user drags, so SwiftUI's own tap recognizer —
    /// which only sees the pointer's position relative to the (also moving) view — measures
    /// almost no local movement and still fires a tap at mouse-up, expanding the panel right
    /// after every drag. Doing the drag ourselves from a `DragGesture` lets `endDragPanel` gate
    /// the tap on real on-screen movement instead — but SwiftUI's own `translation` turned out
    /// unusable for that: it's computed relative to the view we're simultaneously dragging out
    /// from under the cursor, so moving the window mid-gesture feeds back into it (measured:
    /// oscillating between two values instead of tracking the real drag distance). `NSEvent
    /// .mouseLocation` is screen-absolute and immune to that — read fresh every callback instead.
    private var dragStartMouseLocation: NSPoint?

    func dragPanel() {
        guard let w = window else { return }
        if dragStartOrigin == nil {
            dragStartOrigin = w.frame.origin
            dragStartMouseLocation = NSEvent.mouseLocation
        }
        guard let startOrigin = dragStartOrigin, let startMouse = dragStartMouseLocation else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - startMouse.x
        let dy = current.y - startMouse.y
        // A plain click still has a point or two of natural pointer jitter between mouse-down
        // and mouse-up — moving the window on every one of those made a tap visibly "shake"
        // right before it expanded. Below the same 3pt threshold endDragPanel() uses to call
        // it a tap, don't move the window at all.
        guard max(abs(dx), abs(dy)) >= 3 else { return }
        w.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
    }

    /// Returns true when the gesture was a tap (negligible movement) rather than a real drag.
    @discardableResult
    func endDragPanel() -> Bool {
        defer { dragStartOrigin = nil; dragStartMouseLocation = nil }
        guard let startMouse = dragStartMouseLocation else { return true }
        let current = NSEvent.mouseLocation
        let moved = max(abs(current.x - startMouse.x), abs(current.y - startMouse.y))
        guard moved < 3 else {
            saveTopLeft()
            return false
        }
        return true
    }

    /// Screen rect of the pill's speed button — where the "Rýchlosť …" toast anchors.
    var speedButtonFrame: NSRect {
        guard let f = window?.frame else { return .zero }
        // top pad + circle + divider block + 3 buttons above (pause, stop, restart)
        let fromTop = Self.shadowPad + Self.collapsedHeight + 9 + 3 * 42
        return NSRect(x: f.minX + Self.shadowPad, y: f.maxY - fromTop - 40, width: Self.pillWidth, height: 40)
    }

    /// Grows downward from the current top edge by default; flips to growing upward when the
    /// bottom of the screen is in the way (pill snapped to a bottom corner). `state.growsUpward`
    /// is decided only on expand (from real available space) and then reused as-is on the
    /// matching collapse — collapsing always reads the CURRENT live frame's fixed edge (top or
    /// bottom, whichever wasn't moving), never a value computed from scratch, so it returns to
    /// exactly where it started even after a drag mid-expanded. It's mirrored onto `state` (not
    /// just kept here) so the SwiftUI content can keep the trigger circle visually fixed and
    /// unfurl the buttons the other way, instead of the whole stack — trigger included —
    /// sliding to a new spot (see `ControlPanelView.body`).
    private func resize(animated: Bool) {
        guard let w = window else { return }
        let currentTop = w.frame.maxY
        let currentBottom = w.frame.minY
        let h = (state.expanded ? Self.expandedHeight : Self.collapsedHeight) + 2 * Self.shadowPad

        if state.expanded {
            if let screen = w.screen ?? NSScreen.main {
                let spaceBelow = currentBottom - screen.visibleFrame.minY
                let needed = h - w.frame.height
                state.growsUpward = spaceBelow < needed
            } else {
                state.growsUpward = false
            }
        }

        var f = w.frame
        f.size.height = h
        f.origin.y = state.growsUpward ? currentBottom : (currentTop - h)

        // Clamp fully on-screen for the pathological case (panel taller than the screen).
        if let screen = w.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            if f.maxY > vf.maxY { f.origin.y = vf.maxY - f.height }
            if f.minY < vf.minY { f.origin.y = vf.minY }
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated, !reduceMotion else {
            w.setFrame(f, display: true, animate: false)
            return
        }
        // Explicit animation group matching ControlPanelView.expandAnim's curve/duration
        // exactly — before, the window resize used AppKit's default animation while the SwiftUI
        // content inside animated on its own unrelated curve, so window bounds and content
        // height drifted apart mid-transition (the reported jerkiness).
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.expandDuration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            w.animator().setFrame(f, display: true)
        }
    }

    // MARK: Snap

    func snap(to position: PanelSnapPosition) {
        guard let w = window, let screen = DisplayPosition.activeScreen() else { return }
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
        guard let w = window, let screen = DisplayPosition.activeScreen() else { return }
        if let topLeft = DisplayPosition.load(Self.topLeftKey, screen: screen) {
            w.setFrameOrigin(NSPoint(x: topLeft.x, y: topLeft.y - w.frame.height))
            return
        }
        w.setFrameOrigin(computeOrigin(.centerRight, window: w, screen: screen))
    }

    private func saveTopLeft() {
        guard let f = window?.frame else { return }
        // Key by the screen the window actually ended up on (a drag can cross monitors),
        // not the mouse's screen — the two can briefly differ mid-drag.
        let screen = window?.screen ?? DisplayPosition.activeScreen()
        DisplayPosition.save(Self.topLeftKey, screen: screen, point: CGPoint(x: f.minX, y: f.maxY))
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
    /// Curve from citanie-pilulka.md, duration from `ControlPanelWindowController.expandDuration`
    /// (shared constant — this and the window resize must never drift apart). `nil` under
    /// Reduce Motion — `resize(animated:)` checks the same flag so both stay in sync.
    static let expandAnim: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: ControlPanelWindowController.expandDuration)
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
        // The trigger circle must stay visually fixed wherever it already is — the buttons
        // unfurl the other way instead, mirroring resize()'s choice of which window edge is
        // anchored (see ControlPanelState.growsUpward). Alignment pins the trigger to the same
        // edge the window itself keeps fixed, so the circle never appears to move.
        VStack(spacing: 0) {
            if state.growsUpward {
                controls
                trigger
            } else {
                trigger
                controls
            }
        }
        .frame(width: C.pillWidth,
               height: state.expanded ? C.expandedHeight : C.collapsedHeight,
               alignment: state.growsUpward ? .bottom : .top)
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
        .animation(Self.expandAnim, value: state.expanded)
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
    /// A plain `Button` + `isMovableByWindowBackground` doesn't work here: dragging the panel
    /// moves the window under the cursor, so the button's own (local) tap recognizer sees almost
    /// no movement and still fires — expanding the panel right after every drag. This drives the
    /// window move itself from a `DragGesture` instead, so `endDragPanel` can gate the tap on
    /// real on-screen movement (see ControlPanelWindowController.dragPanel/endDragPanel).
    private var trigger: some View {
        VoiceWaveView(isActive: tts.isSpeaking && !tts.isPaused)
            .frame(width: C.pillWidth, height: C.collapsedHeight)
            .background(triggerHovered ? Color.white.opacity(0.05) : .clear)
            .contentShape(Rectangle())
            .pointingHandCursor()
            .onHover { triggerHovered = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        ControlPanelWindowController.shared.dragPanel()
                    }
                    .onEnded { _ in
                        if ControlPanelWindowController.shared.endDragPanel() {
                            ControlPanelWindowController.shared.toggleExpanded()
                            resetAutoHide()
                        }
                    }
            )
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(state.expanded ? "Ovládanie čítania, rozbalené" : "Ovládanie čítania, zbalené")
            .accessibilityHint(state.expanded ? "Kliknutím zbalíš tlačidlá" : "Kliknutím rozbalíš tlačidlá")
            .accessibilityAction {
                ControlPanelWindowController.shared.toggleExpanded()
                resetAutoHide()
            }
    }

    private var divider: some View {
        Rectangle().fill(Theme.HUD.divider).frame(width: 28, height: 1).padding(.vertical, 4)
    }
    private var pauseButton: some View {
        HUDButton(icon: tts.isPaused ? "play.fill" : "pause.fill",
                  label: tts.isPaused ? "Pokračovať (Space)" : "Pozastaviť (Space)",
                  disabled: !tts.isSpeaking,
                  shortcut: KeyboardShortcut(.space, modifiers: [])) {
            tts.isPaused ? tts.resume() : tts.pause(); resetAutoHide()
        }
    }
    private var stopButton: some View {
        HUDButton(icon: "stop.fill", label: "Zastaviť (Esc)", disabled: !tts.isSpeaking,
                  shortcut: KeyboardShortcut(.escape, modifiers: [])) {
            tts.stop(); resetAutoHide()
        }
    }
    private var restartButton: some View {
        HUDButton(icon: "arrow.counterclockwise", label: "Čítať od začiatku",
                  disabled: store.lastText == nil) {
            tts.replayLast(); resetAutoHide()
        }
    }
    private var speedButton: some View {
        HUDButton(text: TTSEngine.format(tts.speed),
                  label: "Rýchlosť čítania \(TTSEngine.format(tts.speed)), kliknutím prepneš na ďalšiu") {
            let next = tts.cycleSpeed()
            HUDToast.show("Rýchlosť \(TTSEngine.format(next))",
                          leftOf: ControlPanelWindowController.shared.speedButtonFrame)
            resetAutoHide()
        }
    }
    private var closeButton: some View {
        HUDButton(icon: "xmark", label: "Zavrieť", muted: true) {
            autoHideTask?.cancel(); tts.stop(); ControlPanelWindowController.shared.hide()
        }
    }

    /// Always in the hierarchy (clipped away when collapsed) so Space/Esc keep working. Order
    /// mirrors around the divider (always the element touching the trigger) when growing
    /// upward, so "zavrieť" stays the button farthest from the trigger in both directions.
    private var controls: some View {
        VStack(spacing: 2) {
            if state.growsUpward {
                closeButton; speedButton; restartButton; stopButton; pauseButton; divider
            } else {
                divider; pauseButton; stopButton; restartButton; speedButton; closeButton
            }
        }
        .padding(state.growsUpward ? .top : .bottom, 6)
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
