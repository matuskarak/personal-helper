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

    /// Set by callers whose trigger may have already activated our own app (URL-scheme /
    /// Apple Event triggers, e.g. Logi Options+) before show() runs — reposition() then asks
    /// this specific app's AX tree instead of the system-wide "focused app", which would
    /// otherwise resolve to us.
    var externalAppPIDOverride: pid_t?

    func show(from caller: String = #function) {
        AppLogger.log("[Indicator] show() ← \(caller) | window visible: \(window?.isVisible == true)")
        reposition()
        window?.orderFront(nil)
        externalAppPIDOverride = nil // one-shot: don't leak into the next, normally-triggered show()
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

        AppLogger.log("[Indicator] reposition() followField=\(PillPosition.followFocusedField) pidOverride=\(externalAppPIDOverride.map(String.init) ?? "nil")")
        if PillPosition.followFocusedField, let axFrame = FocusValidator.focusedElementFrame(pid: externalAppPIDOverride) {
            AppLogger.log("[Indicator] reposition() axFrame=\(axFrame)")
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
        } else if PillPosition.followFocusedField {
            AppLogger.log("[Indicator] reposition() — focusedElementFrame() returned nil, falling back")
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

struct MicEqualizerView: View {
    let isActive: Bool
    let tint: Color    // caller decides based on voice detection
    // When nil, reads DictationEngine.shared.audioLevel (the real dictation pill).
    // Callers with their own audio pipeline (e.g. the mic test, which records
    // independently of DictationEngine) pass their own level so the bars actually move.
    var level: Float? = nil

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
                // ponytail: only write when it would actually change. The ticker is a
                // static autoconnect() publisher that fires for the app's whole lifetime,
                // and re-assigning an identical array still invalidates @State — which
                // re-lays-out the entire enclosing view 28×/s forever. That cost showed up
                // as ~14% idle CPU with Preferences open (this view sits in the mic-test card).
                let atRest = heights.allSatisfy { $0 == 3 }
                if !atRest { heights = Array(repeating: 3, count: Self.barCount) }
                return
            }
            let base = CGFloat(level ?? DictationEngine.shared.audioLevel) * Self.maxBarHeight
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
        // A real Button (not onTapGesture) is required here: with isMovableByWindowBackground
        // on, plain content's mouseDownCanMoveWindow stays true and the window-drag machinery
        // swallows the click before any gesture recognizer sees it. Buttons are the one thing
        // AppKit reliably excludes from that, so clicking dismisses while dragging elsewhere
        // on the pill still works.
        Button {
            DictationIndicatorController.shared.hide(from: "tap")
        } label: {
            pillContent
        }
        .buttonStyle(.plain).pointingHandCursor()
            .onReceive(Self.levelTicker) { _ in
                // ponytail: the pill's NSHostingView is built once and never torn down —
                // hide() only orderOut's the window — so without this guard the noise-floor
                // buffer keeps churning @State (and a layout pass with it) for the app's
                // entire lifetime, while the pill isn't even on screen.
                guard engine.isRecording else { return }
                levelHistory[historyIndex] = engine.audioLevel
                historyIndex = (historyIndex + 1) % levelHistory.count
            }
            .background(RoundedRectangle(cornerRadius: 20).fill(.regularMaterial))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
            .padding(10)
            .animation(.easeInOut(duration: 0.2), value: isCompact)
            // Errors no longer auto-dismiss. A 3 s window meant a failure the user wasn't
            // looking at (pill centred on another screen, attention on the text field) vanished
            // before it was ever read. It stays until the pill is clicked away.
            .onChange(of: engine.connectionError) { _, err in
                AppLogger.log("[Indicator] connectionError changed → \(err ?? "nil") | isRecording=\(engine.isRecording) (sticky — waits for click)")
            }
            .onChange(of: engine.notice) { _, notice in
                AppLogger.log("[Indicator] notice changed → \(notice ?? "nil") | isRecording=\(engine.isRecording) sticky=\(engine.noticeIsSticky)")
                guard notice != nil else { return }
                // Sticky notices are the ones that report a failed action ("no field selected —
                // saved to memory"); those must survive until acknowledged. Only advisory ones
                // fade on their own.
                guard !engine.noticeIsSticky else { return }
                Task {
                    try? await Task.sleep(for: .seconds(6))
                    guard engine.notice != nil else {
                        AppLogger.log("[Indicator] notice auto-hide cancelled — notice already cleared (new session started)")
                        return
                    }
                    // Still recording: this was a passive heads-up (mic-quality hint) raised
                    // mid-session, not a reason to end it — clear the notice so the pill
                    // reverts to the live equalizer/timer and keeps recording, don't close it.
                    // Only hide outright once the session itself has actually finished.
                    if engine.isRecording {
                        AppLogger.log("[Indicator] notice auto-clear firing (6s elapsed) — still recording, reverting to normal view")
                        engine.clearNotice()
                    } else {
                        AppLogger.log("[Indicator] notice auto-hide firing (6s elapsed) | isRecording=false")
                        DictationIndicatorController.shared.hide(from: "notice-onChange")
                    }
                }
            }
            .onChange(of: engine.isRecording) { _, recording in
                AppLogger.log("[Indicator] isRecording → \(recording) | isMicReady=\(engine.isMicReady) btNeg=\(engine.btNegotiating) compact=\(engine.liveInsertEnabled && engine.liveInsertActive)")
                // The ticker above stops updating between sessions, so clear the noise-floor
                // window on start — otherwise the last session's levels linger and skew the
                // voice-detection tint for the first couple of seconds.
                if recording {
                    levelHistory = Array(repeating: 0, count: levelHistory.count)
                    historyIndex = 0
                }
            }
            .onChange(of: engine.isMicReady) { _, ready in
                AppLogger.log("[Indicator] isMicReady → \(ready) | btNeg=\(engine.btNegotiating) compact=\(engine.liveInsertEnabled && engine.liveInsertActive)")
            }
            .onChange(of: engine.btNegotiating) { _, neg in
                AppLogger.log("[Indicator] btNegotiating → \(neg)")
            }
    }

    /// Shown under any message that waits for acknowledgement — without it a pill that
    /// no longer disappears on its own just reads as stuck.
    private var dismissHint: some View {
        Text("Klikni na zatvorenie")
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
    }

    /// Elapsed recording time — SwiftUI's built-in timer-style Text ticks on its own,
    /// no polling/Timer needed.
    @ViewBuilder
    private var elapsedTimeLabel: some View {
        if let start = engine.recordingStartDate {
            Text(start, style: .timer)
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var pillContent: some View {
        if isCompact {
            // Live-insert mode: just the equalizer bubble — transcript is in the field
            VStack(spacing: 3) {
                MicEqualizerView(isActive: engine.isRecording, tint: equalizerTint)
                elapsedTimeLabel
            }
            .frame(maxHeight: .infinity, alignment: .center)
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(3)
                        dismissHint
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if let notice = engine.notice {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .foregroundStyle(.orange)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                        if engine.noticeIsSticky {
                            dismissHint
                        } else if engine.isRecording {
                            // A passive heads-up, not an interruption — say so, otherwise the
                            // pill quietly reverting to the equalizer a few seconds later reads
                            // as "something broke" rather than "recording never stopped".
                            Text("Len upozornenie — nahrávanie pokračuje")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if !engine.isMicReady {
                    ProgressView().controlSize(.small)
                    Text(engine.btNegotiating ? "Inicializujem Bluetooth…" : "Pripájam mikrofón…")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // frame(maxHeight: .infinity, alignment: .center) pins this block to the
                    // vertical middle of the row regardless of the sibling's height (e.g. the
                    // multi-line liveText box) — HStack's default centering isn't enough once
                    // this stack (equalizer + timer) isn't the tallest child anymore.
                    VStack(spacing: 2) {
                        MicEqualizerView(isActive: engine.isRecording, tint: equalizerTint)
                        elapsedTimeLabel
                    }
                    .frame(maxHeight: .infinity, alignment: .center)

                    if engine.liveText.isEmpty {
                        if engine.isWaitingForServer {
                            ProgressView().controlSize(.small)
                            Text("Čakám na server…")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else if engine.transcriptionMode != .realtime {
                            // Batch/local modes only get a transcript after recording stops —
                            // no interim words to show, unlike realtime's live deltas. Naming
                            // that explicitly avoids reading as a stuck/laggy live view.
                            Text("Nahrávam… (prepis až po zastavení)")
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
