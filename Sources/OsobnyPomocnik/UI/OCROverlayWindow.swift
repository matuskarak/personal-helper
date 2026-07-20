import AppKit
import SwiftUI

@MainActor
final class OCROverlayWindowController: NSWindowController {
    static let shared = OCROverlayWindowController()

    var onRectSelected: ((CGRect) -> Void)?
    private var overlayView: OCROverlayView?

    private init() {
        // Cover all screens; we'll update frame on show()
        let frame = NSScreen.screens.reduce(CGRect.zero) { $0.union($1.frame) }
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        let view = OCROverlayView { [weak self] cgRect in
            self?.hide()
            self?.onRectSelected?(cgRect)
        }
        overlayView = view
        window?.contentView = NSHostingView(rootView: view)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // ESC to cancel
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // ESC
                self?.hide()
                return nil
            }
            return event
        }
    }

    func hide() {
        window?.orderOut(nil)
        overlayView = nil
    }
}

// MARK: - SwiftUI overlay

struct OCROverlayView: View {
    let onRectSelected: (CGRect) -> Void

    @State private var startPoint: CGPoint? = nil
    @State private var currentPoint: CGPoint? = nil

    private var selectionRect: CGRect? {
        guard let s = startPoint, let c = currentPoint else { return nil }
        return CGRect(
            x: min(s.x, c.x), y: min(s.y, c.y),
            width: abs(c.x - s.x), height: abs(c.y - s.y)
        )
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Dark scrim
                Color.black.opacity(0.35).ignoresSafeArea()

                if let rect = selectionRect {
                    // Clear window in scrim over selection
                    Rectangle()
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .blendMode(.destinationOut)

                    // Blue border
                    Rectangle()
                        .stroke(Color.blue, lineWidth: 2)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }

                // Instruction label
                Text("Vyber oblasť pre OCR  •  ESC = zrušiť")
                    .font(.callout.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                    .position(x: geo.size.width / 2, y: 40)
            }
            .compositingGroup()
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .local)
                    .onChanged { value in
                        if startPoint == nil { startPoint = value.startLocation }
                        currentPoint = value.location
                    }
                    .onEnded { _ in
                        guard let rect = selectionRect, rect.width > 8, rect.height > 8 else {
                            reset(); return
                        }
                        // Convert SwiftUI coords (origin top-left) → CG coords (origin bottom-left)
                        let screenH = NSScreen.main?.frame.height ?? geo.size.height
                        let cgRect = CGRect(
                            x: rect.minX,
                            y: screenH - rect.maxY,
                            width: rect.width,
                            height: rect.height
                        )
                        reset()
                        onRectSelected(cgRect)
                    }
            )
        }
    }

    private func reset() { startPoint = nil; currentPoint = nil }
}
