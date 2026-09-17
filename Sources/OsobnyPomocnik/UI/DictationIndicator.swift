import AppKit
import SwiftUI

/// Persisted pill placement — a manually dragged position takes over from the
/// "always centered" default until the user resets it in Preferences. Kept per physical
/// display (see `DisplayPosition`), so dragging the pill on the external monitor doesn't
/// affect where it shows up on the laptop screen, and vice versa.
enum PillPosition {
    private static let followKey = "indicator.followFocusedField"
    private static let positionsKey = "indicator.customPositions"

    static var followFocusedField: Bool {
        get { UserDefaults.standard.bool(forKey: followKey) }
        set { UserDefaults.standard.set(newValue, forKey: followKey) }
    }

    static func custom(on screen: NSScreen?) -> CGPoint? {
        DisplayPosition.load(positionsKey, screen: screen)
    }

    static func setCustom(_ point: CGPoint, on screen: NSScreen?) {
        DisplayPosition.save(positionsKey, screen: screen, point: point)
    }

    static func reset() { UserDefaults.standard.removeObject(forKey: positionsKey) }
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
        // Floating pills are always dark, whatever the system appearance (client decision 2026-09-11).
        window.appearance = NSAppearance(named: .darkAqua)
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
        if let hv = window?.contentView as? NSHostingView<DictationIndicatorView> { fit(to: hv.fittingSize) }
        reposition()
        window?.orderFront(nil)
        externalAppPIDOverride = nil // one-shot: don't leak into the next, normally-triggered show()
    }

    func hide(from caller: String = #function) {
        let e = DictationEngine.shared
        AppLogger.log("[Indicator] hide() ← \(caller) | isRecording=\(e.isRecording) isMicReady=\(e.isMicReady) btNeg=\(e.btNegotiating) err=\(e.connectionError ?? "nil")")
        window?.orderOut(nil)
    }

    /// Window = the content's ideal size. NSHostingView's own sizingOptions never resized this
    /// borderless panel, so the card was silently clipped to the 300 pt init width. Keeps the
    /// pill's horizontal centre and top edge where they were.
    func fit(to size: CGSize) {
        guard let window, size.width > 0, window.frame.size != size else { return }
        var f = window.frame
        f.origin.x += (f.width - size.width) / 2
        f.origin.y += f.height - size.height
        f.size = size
        isProgrammaticMove = true
        window.setFrame(f, display: true)
        isProgrammaticMove = false
    }

    // MARK: - Positioning

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
            let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: fieldFrame.midX, y: fieldFrame.midY)) }) ?? DisplayPosition.activeScreen()
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

        let screen = DisplayPosition.activeScreen()
        if let custom = PillPosition.custom(on: screen) {
            applyPosition(custom)
            return
        }

        if let screen {
            applyPosition(centeredOrigin(on: screen, size: size))
        }
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowDidMove(_ notification: Notification) {
        Task { @MainActor in
            guard !isProgrammaticMove, let window else { return }
            // Key by the screen the window actually ended up on (a drag can cross monitors),
            // not the mouse's screen — the two can briefly differ mid-drag.
            let screen = window.screen ?? DisplayPosition.activeScreen()
            PillPosition.setCustom(window.frame.origin, on: screen)
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
    /// The dictation pill draws its own 34 pt badge behind the bars; the mic-test card keeps the ring.
    var showsRing = true

    private static let barCount = 4
    private static let maxBarHeight: CGFloat = 15

    @State private var heights: [CGFloat] = Array(repeating: 3, count: barCount)
    // ponytail: static — prevents re-renders (every 16ms from audioLevel) from resetting
    // the subscription before the timer fires. Reading audioLevel directly inside the closure
    // (not as a captured `let` param) avoids stale-closure: the timer always gets the fresh value.
    private static let ticker = Timer.publish(every: 0.035, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            if showsRing {
                Circle()
                    .fill(tint.opacity(0.14))
                    .frame(width: 30, height: 30)
                Circle()
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1)
                    .frame(width: 30, height: 30)
            }
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
        .animation(.easeInOut(duration: 0.25), value: tint)
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

/// Visual spec: Vyvoj/Komponenty/diktovanie-pilulka.md — dark HUD card, 34 pt badge whose
/// colour carries the state (blue = working, amber = warning/data kept, red = failed),
/// title + meta line. The state machine below is unchanged from before the redesign.
struct DictationIndicatorView: View {
    @State private var engine = DictationEngine.shared

    private static let lineHeight: CGFloat = 18
    private static let maxLines = 4
    private static let maxColumnWidth: CGFloat = 300

    // Rolling noise floor: min level over ~2s window (28 ticks × 70ms). Bars go full white
    // only when current level is clearly above the ambient baseline — not just any sound.
    @State private var levelHistory: [Float] = Array(repeating: 0, count: 28)
    @State private var historyIndex = 0

    private var voiceTint: Color { voiceDetected ? .white : .white.opacity(0.45) }

    /// Batch/transcribe mode: once the user is clearly talking, the pill folds down to badge +
    /// timer after this delay — the "Nahrávam…" line has done its job by then. Live-insert
    /// reuses the same delay for the same reason (see `liveInsertCompact` below) — one collapse
    /// timing for the whole pill, not two.
    private static let autoCompactAfter: Duration = .seconds(5)
    private static let anim: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.25)
    @State private var autoCompact = false
    @State private var autoCompactTask: Task<Void, Never>?
    // Mirrors engine.liveInsertActive, but flipped through an explicit withAnimation, on the
    // same autoCompactAfter delay as the batch fold above, instead of isCompact reading the
    // engine property directly and collapsing the instant it flips. liveInsertActive turns true
    // on the FIRST delta — the same instant "Čakám na server…" is also swapping out — so an
    // immediate collapse stacked two layout changes in the same tick (visible as the pill
    // shearing/clipping mid-collapse). Giving it the same delay-then-withAnimation shape as
    // autoCompact means the collapse always starts from an already-settled, unchanging state.
    @State private var liveInsertCompact = false
    @State private var liveInsertCompactTask: Task<Void, Never>?

    private var voiceDetected: Bool {
        let floor = levelHistory.min() ?? 0
        return engine.audioLevel > max(0.12, floor * 3.0)
    }

    /// Compact mode: live-insert active (transcript is already in the field), or the batch
    /// auto-fold above. Anything that needs reading — notice, error, live text — unfolds it.
    private var isCompact: Bool {
        guard engine.isRecording, engine.isMicReady, engine.notice == nil, engine.connectionError == nil,
              engine.liveText.isEmpty else { return false }
        return (engine.liveInsertEnabled && liveInsertCompact) || autoCompact
    }

    private var isProcessing: Bool { engine.isRewriting || engine.isTranscribing }
    private var showsError: Bool { engine.connectionError != nil }
    private var showsNotice: Bool { engine.notice != nil }
    private var badgeColor: Color {
        showsError ? Theme.HUD.badgeError : showsNotice ? Theme.HUD.badgeWarning : Theme.HUD.badgeActive
    }

    private static func font(bold: Bool, _ size: CGFloat) -> NSFont {
        NSFont(name: bold ? "AtkinsonHyperlegible-Bold" : "AtkinsonHyperlegible-Regular", size: size) ?? .systemFont(ofSize: size)
    }
    private static func width(_ s: String, bold: Bool, _ size: CGFloat) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font(bold: bold, size)]).width)
    }
    /// Height the live transcript needs at the column width — grows 1→`maxLines` lines, then scrolls.
    private static func liveTextHeight(_ s: String) -> CGFloat {
        let h = (s as NSString).boundingRect(
            with: CGSize(width: maxColumnWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font(bold: false, 13)]).height
        return min(CGFloat(maxLines) * lineHeight, max(lineHeight, ceil(h) + 2))
    }
    /// Text column = widest string the current state shows (measured with the real font),
    /// capped at `maxColumnWidth` — so the pill hugs short states and wraps long ones.
    private var columnWidth: CGFloat {
        let strings: [(String, Bool, CGFloat)]
        if engine.isRewriting        { strings = [("Spracovávam s kontextom…", true, 13.5), ("Smart diktovanie", false, 11.5)] }
        else if engine.isTranscribing { strings = [("Prepisujem nahrávku…", true, 13.5), ("Zvyčajne pár sekúnd", false, 11.5)] }
        else if let err = engine.connectionError { strings = [(err, true, 12.5)] }
        else if showsNotice, let n = engine.notice { strings = [(n, true, 12.5)] }
        else if !engine.isMicReady   { strings = [("Inicializujem Bluetooth…", true, 13.5)] }
        else if engine.liveText.isEmpty {
            strings = [("Čakám na server…", true, 13.5), ("0:00 · prepis až po zastavení", false, 11.5)]
        } else { return Self.maxColumnWidth }
        let widest = strings.map { Self.width($0.0, bold: $0.1, $0.2) }.max() ?? 0
        return min(Self.maxColumnWidth, widest + 8)
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
            coreContent
        }
        .buttonStyle(.plain).pointingHandCursor()
        .accessibilityLabel("Diktovanie, kliknutím zavrieš")
            .onReceive(Self.levelTicker) { _ in
                // ponytail: the pill's NSHostingView is built once and never torn down —
                // hide() only orderOut's the window — so without this guard the noise-floor
                // buffer keeps churning @State (and a layout pass with it) for the app's
                // entire lifetime, while the pill isn't even on screen.
                guard engine.isRecording else { return }
                levelHistory[historyIndex] = engine.audioLevel
                historyIndex = (historyIndex + 1) % levelHistory.count
                // First clear voice in a batch session arms the auto-fold; realtime keeps its live text.
                if engine.transcriptionMode != .realtime, !autoCompact, autoCompactTask == nil, engine.isMicReady, voiceDetected {
                    autoCompactTask = Task {
                        try? await Task.sleep(for: Self.autoCompactAfter)
                        guard !Task.isCancelled, engine.isRecording else { return }
                        withAnimation(Self.anim) { autoCompact = true }
                    }
                }
            }
            .background {
                ZStack {
                    Rectangle().fill(.regularMaterial)
                    Theme.HUD.background
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.HUD.border, lineWidth: 1))
            .shadow(color: Theme.HUD.shadow, radius: 14, y: 12)
            // Room for the blur to fade out on every side — the window is sized to fit
            // exactly this padded box, so anything less clips the shadow into a hard edge.
            .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 30)
            // Ideal size regardless of the window, then the window follows (see `fit(to:)`).
            .fixedSize()
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { DictationIndicatorController.shared.fit(to: g.size) }
                    .onChange(of: g.size) { _, size in DictationIndicatorController.shared.fit(to: size) }
            })
            // Both the fold and text-driven width changes animate; GeometryReader above reports
            // the interpolated size every frame, so the window follows the content smoothly.
            .animation(Self.anim, value: isCompact)
            .animation(Self.anim, value: columnWidth)
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
                autoCompactTask?.cancel()
                autoCompactTask = nil
                withAnimation(Self.anim) { autoCompact = false }
                liveInsertCompactTask?.cancel()
                liveInsertCompactTask = nil
                withAnimation(Self.anim) { liveInsertCompact = false }
            }
            .onChange(of: engine.liveInsertActive) { _, active in
                liveInsertCompactTask?.cancel()
                guard active else {
                    withAnimation(Self.anim) { liveInsertCompact = false }
                    return
                }
                liveInsertCompactTask = Task {
                    try? await Task.sleep(for: Self.autoCompactAfter)
                    guard !Task.isCancelled else { return }
                    withAnimation(Self.anim) { liveInsertCompact = true }
                }
            }
            .onChange(of: engine.isMicReady) { _, ready in
                AppLogger.log("[Indicator] isMicReady → \(ready) | btNeg=\(engine.btNegotiating) compact=\(engine.liveInsertEnabled && engine.liveInsertActive)")
            }
            .onChange(of: engine.btNegotiating) { _, neg in
                AppLogger.log("[Indicator] btNegotiating → \(neg)")
            }
    }

    // MARK: - Pieces

    private func title(_ s: String) -> some View {
        Text(s).font(Theme.bodyBold(13.5)).foregroundStyle(Theme.HUD.text)
    }
    private func meta(_ s: String) -> some View {
        Text(s).font(Theme.body(11.5)).foregroundStyle(Theme.HUD.textMeta)
    }
    /// Longer, wrapping message (errors, notices).
    private func message(_ s: String) -> some View {
        Text(s).font(Theme.bodyBold(12.5)).foregroundStyle(Theme.HUD.text).lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Shown under any message that waits for acknowledgement — without it a pill that
    /// no longer disappears on its own just reads as stuck.
    @ViewBuilder
    private var dismissHint: some View {
        if engine.pillHintsEnabled { meta("Klikni na zatvorenie") }
    }

    /// Elapsed recording time — SwiftUI's built-in timer-style Text ticks on its own,
    /// no polling/Timer needed.
    @ViewBuilder
    private var elapsedTimeLabel: some View {
        if let start = engine.recordingStartDate {
            Text(start, style: .timer)
                .font(Theme.body(11.5).monospacedDigit())
                .foregroundStyle(Theme.HUD.textMeta)
        }
    }

    /// 34 pt state badge: colour = state, glyph = what is happening.
    private var badge: some View {
        ZStack {
            Circle().fill(badgeColor)
            if showsError {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
            } else if showsNotice {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            } else if isProcessing || !engine.isMicReady {
                ProgressView().controlSize(.small)
            } else {
                MicEqualizerView(isActive: engine.isRecording, tint: voiceTint, showsRing: false)
            }
        }
        .frame(width: 34, height: 34)
        .animation(.easeInOut(duration: 0.2), value: badgeColor)
    }

    /// One layout for both folded and full states so the badge keeps its identity (no
    /// cross-fade) and only the text column slides away.
    private var coreContent: some View {
        HStack(spacing: 12) {
            // frame(maxHeight: .infinity, alignment: .center) pins this block to the
            // vertical middle of the row regardless of the sibling's height (e.g. the
            // multi-line liveText box) — HStack's default centering isn't enough once
            // this stack isn't the tallest child anymore.
            VStack(spacing: 4) {
                badge
                if isCompact || !engine.liveText.isEmpty { elapsedTimeLabel }
            }
            .frame(maxHeight: .infinity, alignment: .center)

            if !isCompact {
                VStack(alignment: .leading, spacing: 2) { textColumn }
                    .frame(width: columnWidth, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .padding(.horizontal, isCompact ? 12 : 16)
        .padding(.vertical, isCompact ? 10 : 11)
        .animation(.easeInOut(duration: 0.15), value: engine.liveText)
    }

    @ViewBuilder
    private var textColumn: some View {
        if engine.isRewriting {
            title("Spracovávam s kontextom…")
            meta("Smart diktovanie")
        } else if engine.isTranscribing {
            title("Prepisujem nahrávku…")
            meta("Zvyčajne pár sekúnd")
        } else if let err = engine.connectionError {
            message(err)
            dismissHint
        } else if showsNotice, let notice = engine.notice {
            message(notice)
            if engine.noticeIsSticky { dismissHint }
        } else if !engine.isMicReady {
            title(engine.btNegotiating ? "Inicializujem Bluetooth…" : "Pripájam mikrofón…")
        } else if engine.liveText.isEmpty {
            if engine.isWaitingForServer {
                title("Čakám na server…")
                elapsedTimeLabel
            } else if engine.transcriptionMode != .realtime {
                // Batch/local modes only get a transcript after recording stops —
                // no interim words to show, unlike realtime's live deltas. Naming
                // that explicitly avoids reading as a stuck/laggy live view.
                title("Nahrávam…")
                HStack(spacing: 4) {
                    elapsedTimeLabel
                    if engine.pillHintsEnabled { meta("· prepis až po zastavení") }
                }
            } else {
                title("Počúvam…")
                elapsedTimeLabel
            }
        } else {
            // ponytail: real ScrollView, full text (no truncation). The earlier
            // break was `.fixedSize` overriding the parent's height constraint —
            // an explicit `.frame(height:)` instead grows 1→4 lines with the text
            // and only scrolls (smoothly, bottom-anchored) past the cap.
            ScrollView {
                Text(engine.liveText)
                    .font(Theme.body(13)).foregroundStyle(Theme.HUD.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.liveTextHeight(engine.liveText))
        }
    }
}
