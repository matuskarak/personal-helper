import AppKit
import SwiftUI

/// test/local-whisper-sk ONLY — see CLAUDE.md. Developer-mode tool to compare the cloud
/// transcription path against a local on-device WhisperKit model on the same recording.
@MainActor
final class LocalModelTestWindowController: NSWindowController {
    static let shared = LocalModelTestWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Test lokálneho modelu (SK)"
        window.center()
        window.contentView = FirstMouseHostingView(rootView: LocalModelTestView())
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

private struct LocalModelTestView: View {
    @State private var engine = LocalModelTestEngine.shared
    @State private var whisper = LocalWhisperEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            recordControls
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(engine.results) { run in
                        resultCard(run)
                    }
                    if engine.results.isEmpty {
                        Text("Zatiaľ žiadny test. Klikni „Nahrávať“ a povedz pár viet po slovensky.")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.top, 24)
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .padding(16)
        .task { await whisper.ensureLoaded() }
        .onChange(of: whisper.source) { _, _ in Task { await whisper.ensureLoaded() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Cloud (gpt-transcribe) vs. lokálny WhisperKit — porovnanie na tej istej nahrávke.")
                .font(.callout)
            VStack(alignment: .leading, spacing: 6) {
                Text("Lokálny model:").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { whisper.source },
                    set: { whisper.source = $0 }
                )) {
                    ForEach(LocalWhisperEngine.Source.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                .disabled(engine.phase == .transcribing)
            }
            HStack(spacing: 6) {
                Text("Stav:").foregroundStyle(.secondary)
                switch whisper.status {
                case .notLoaded:          Text("nenačítaný")
                case .downloading:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("pripravujem… (prvé načítanie SK modelu môže trvať aj cez 15 minút — macOS ho na pozadí kompiluje pre Neural Engine)")
                    }
                case .loaded:             Text("pripravený ✓").foregroundStyle(.green)
                case .failed(let reason): Text("chyba: \(reason)").foregroundStyle(.red)
                }
            }
            .font(.caption)
        }
    }

    private var recordControls: some View {
        HStack {
            switch engine.phase {
            case .idle:
                Button("Nahrávať") { engine.startRecording() }
                    .buttonStyle(.borderedProminent)
            case .recording(let secondsLeft):
                Button("Stop (\(secondsLeft)s max)") { engine.stopRecording() }
                    .buttonStyle(.borderedProminent).tint(.red)
                levelMeter
            case .transcribing:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("prepisujem oboma cestami…") }
            }
            Spacer()
            if !engine.results.isEmpty {
                Button("Vymazať výsledky") { engine.clearResults() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var levelMeter: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 3)
                .fill(.green)
                .frame(width: max(4, geo.size.width * CGFloat(engine.liveLevel)))
        }
        .frame(width: 100, height: 8)
        .background(RoundedRectangle(cornerRadius: 3).fill(.quaternary))
    }

    private func resultCard(_ run: LocalModelTestEngine.RunResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(run.date.formatted(date: .omitted, time: .standard))
                .font(.caption2).foregroundStyle(.tertiary)

            transcriptRow(title: "☁️ Cloud", text: run.cloudText, seconds: run.cloudSeconds, match: run.cloudMatchPercent)
            if let error = run.localError {
                transcriptRow(title: "💻 Lokálny", text: "chyba: \(error)", seconds: run.localSeconds, match: nil)
            } else {
                transcriptRow(title: "💻 Lokálny", text: run.localText, seconds: run.localSeconds, match: run.localMatchPercent)
            }

            HStack {
                Text("Čo si naozaj povedal (na výpočet presnosti):").font(.caption2).foregroundStyle(.secondary)
            }
            TextField("referenčný text…", text: Binding(
                get: { run.reference },
                set: { engine.setReference($0, for: run.id) }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.caption)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quinary))
    }

    private func transcriptRow(title: String, text: String, seconds: Double, match: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption.bold())
                Spacer()
                Text(String(format: "%.1fs", seconds)).font(.caption2).foregroundStyle(.secondary)
                if let match {
                    Text(String(format: "%.0f%% zhoda", match))
                        .font(.caption2.bold())
                        .foregroundStyle(match >= 90 ? .green : (match >= 70 ? .orange : .red))
                }
            }
            Text(text.isEmpty ? "—" : text)
                .font(.callout)
                .textSelection(.enabled)
        }
    }
}
