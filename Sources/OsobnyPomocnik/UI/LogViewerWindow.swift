import AppKit
import SwiftUI

/// Developer-mode tool: shows app.log inside the app, no Finder/Console.app round-trip.
@MainActor
final class LogViewerWindowController: NSWindowController {
    static let shared = LogViewerWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Log — Osobný pomocník"
        window.center()
        window.contentView = NSHostingView(rootView: LogViewerView())
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct LogViewerView: View {
    @State private var content = ""
    @State private var autoRefresh = true

    // ponytail: tail last ~80KB instead of the whole (up to 1MB) file — plenty of
    // recent context, keeps the Text view snappy on every refresh tick.
    private static let maxChars = 80_000
    private static let ticker = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log aplikácie").font(.headline)
                Spacer()
                Toggle("Auto-obnova", isOn: $autoRefresh)
                    .toggleStyle(.switch)
                Button("Obnoviť") { load() }
                    .buttonStyle(.bordered)
                Button("Vymazať") { clear() }
                    .buttonStyle(.bordered)
                Button("Vo Finderi") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppLogger.logFileURL])
                }
                .buttonStyle(.bordered)
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    Text(content.isEmpty ? "(prázdny log)" : content)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .id("bottom")
                }
                .onChange(of: content) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .onAppear { load() }
        .onReceive(Self.ticker) { _ in if autoRefresh { load() } }
    }

    private func load() {
        guard let data = try? Data(contentsOf: AppLogger.logFileURL) else { return }
        let text = String(data: data, encoding: .utf8) ?? ""
        content = text.count > Self.maxChars ? String(text.suffix(Self.maxChars)) : text
    }

    private func clear() {
        try? "".write(to: AppLogger.logFileURL, atomically: true, encoding: .utf8)
        content = ""
    }
}
