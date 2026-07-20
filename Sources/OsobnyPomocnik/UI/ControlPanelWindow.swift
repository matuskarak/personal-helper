import AppKit
import SwiftUI

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

// MARK: - Window controller

@MainActor
final class ControlPanelWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ControlPanelWindowController()

    private static let originKey = "controlPanel.origin"
    private static let margin: CGFloat = 20

    private init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 56, height: 182),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.backgroundColor = .clear
        w.isOpaque = false
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.isMovable = true
        w.isMovableByWindowBackground = true
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentView = NSHostingView(rootView: ControlPanelView())
        super.init(window: w)
        w.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Show / Hide

    func show() {
        restoreOrDefaultPosition()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() { window?.orderOut(nil) }
    func showStatus(_ msg: String) { print("[ControlPanel] \(msg)") }

    // MARK: Snap

    func snap(to position: PanelSnapPosition) {
        guard let w = window, let screen = NSScreen.main else { return }
        let pt = computeOrigin(position, window: w, screen: screen)
        w.setFrameOrigin(pt)
        saveOrigin(pt)
    }

    // MARK: NSWindowDelegate — persist after drag

    nonisolated func windowDidMove(_ notification: Notification) {
        Task { @MainActor in
            guard let pt = self.window?.frame.origin else { return }
            self.saveOrigin(pt)
        }
    }

    // MARK: Helpers

    private func restoreOrDefaultPosition() {
        guard let w = window, let screen = NSScreen.main else { return }
        if let arr = UserDefaults.standard.array(forKey: Self.originKey) as? [Double],
           arr.count == 2 {
            let pt = NSPoint(x: arr[0], y: arr[1])
            if screen.frame.contains(pt) {
                w.setFrameOrigin(pt)
                return
            }
        }
        w.setFrameOrigin(computeOrigin(.centerRight, window: w, screen: screen))
    }

    private func saveOrigin(_ pt: NSPoint) {
        UserDefaults.standard.set([pt.x, pt.y], forKey: Self.originKey)
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

    private static let barCount = 5
    private static let flatHeights: [CGFloat] = Array(repeating: 2, count: barCount)

    @State private var heights: [CGFloat] = flatHeights

    private let ticker = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<Self.barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.85))
                    .frame(width: 2.5, height: heights[i])
                    .animation(.easeInOut(duration: 0.15), value: heights[i])
            }
        }
        .frame(width: 28, height: 18)
        .onReceive(ticker) { _ in
            heights = isActive
                ? (0..<Self.barCount).map { _ in CGFloat.random(in: 4...17) }
                : Self.flatHeights
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
    @State private var tts   = TTSEngine.shared
    @State private var store = RecentTextStore.shared

    /// Currently running auto-hide countdown (cancelled on interaction / when speaking starts)
    @State private var autoHideTask: Task<Void, Never>?

    // Reads the user preference; 0 = nikdy (never)
    private var autoHideSecs: Int {
        let v = UserDefaults.standard.object(forKey: "controlPanel.autoHideSecs")
        return v as? Int ?? 60   // default: 1 minúta
    }

    var body: some View {
        VStack(spacing: 0) {
            VoiceWaveView(isActive: tts.isSpeaking && !tts.isPaused)
                .padding(.top, 10)
                .padding(.bottom, 7)

            pillDivider

            VStack(spacing: 1) {
                panelButton(
                    systemName: tts.isPaused ? "play.fill" : "pause.fill",
                    tint:       tts.isSpeaking ? .accentColor : .secondary,
                    help:       tts.isPaused ? "Pokračovať (Space)" : "Pozastaviť (Space)",
                    disabled:   !tts.isSpeaking,
                    shortcut:   KeyboardShortcut(.space, modifiers: [])
                ) { tts.isPaused ? tts.resume() : tts.pause(); resetAutoHide() }

                panelButton(
                    systemName: "stop.fill",
                    tint:       tts.isSpeaking ? .red : .secondary,
                    help:       "Zastaviť (Esc)",
                    disabled:   !tts.isSpeaking,
                    shortcut:   KeyboardShortcut(.escape, modifiers: [])
                ) { tts.stop(); resetAutoHide() }

                panelButton(
                    systemName: "arrow.counterclockwise",
                    tint:       store.lastText != nil ? .primary : .secondary,
                    help:       "Znova čítať",
                    disabled:   store.lastText == nil,
                    shortcut:   nil
                ) { tts.replayLast(); resetAutoHide() }

                pillDivider.padding(.vertical, 3)

                panelButton(
                    systemName: "xmark",
                    tint:       .secondary,
                    help:       "Zavrieť",
                    disabled:   false,
                    shortcut:   nil
                ) { autoHideTask?.cancel(); tts.stop(); ControlPanelWindowController.shared.hide() }
            }
            .padding(.bottom, 7)
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.11), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .padding(8)
        .frame(width: 56)
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

    // MARK: - Helpers

    private var pillDivider: some View {
        Divider().padding(.horizontal, 7)
    }

    @ViewBuilder
    private func panelButton(
        systemName: String,
        tint: Color,
        help: String,
        disabled: Bool,
        shortcut: KeyboardShortcut?,
        action: @escaping () -> Void
    ) -> some View {
        let btn = Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundStyle(disabled ? Color.secondary.opacity(0.28) : tint)
                .frame(width: 30, height: 27)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)

        if let shortcut { btn.keyboardShortcut(shortcut) } else { btn }
    }
}
