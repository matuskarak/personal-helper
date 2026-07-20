import SwiftUI
import AVFoundation
import Speech

struct OnboardingView: View {
    /// Closes the standalone first-launch window. No-op when presented as a
    /// Preferences sheet, where `@Environment(\.dismiss)` already handles it.
    var onClose: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var axGranted = AXIsProcessTrusted()
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized

    @State private var dictation = DictationEngine.shared
    @State private var google    = GoogleCloudTTSEngine.shared
    @State private var openAIKeyInput = ""
    @State private var openAIKeySaved = false
    @State private var apiKeyTestRunning = false
    @State private var apiKeyTestResult: String?
    @State private var googleKeyInput = ""
    @State private var googleKeySaved = false

    var allGranted: Bool { axGranted && micGranted && speechGranted }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            Text("Nastavenie povolení")
                .font(.title2.bold())

            Text("Osobný pomocník potrebuje nasledujúce povolenia:")
                .foregroundStyle(.secondary)

            PermissionRow(
                icon: "accessibility",
                title: "Accessibility",
                description: "Potrebné pre globálne klávesové skratky a vloženie textu.",
                granted: axGranted
            ) {
                PermissionsChecker.shared.openAccessibilitySettings()
            }

            PermissionRow(
                icon: "mic.fill",
                title: "Mikrofón",
                description: "Potrebný pre diktovanie.",
                granted: micGranted
            ) {
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    DispatchQueue.main.async { micGranted = ok }
                }
            }

            PermissionRow(
                icon: "waveform",
                title: "Rozpoznávanie reči",
                description: "Potrebné pre diktovanie do textových polí.",
                granted: speechGranted
            ) {
                SFSpeechRecognizer.requestAuthorization { status in
                    DispatchQueue.main.async { speechGranted = status == .authorized }
                }
            }

            PermissionRow(
                icon: "camera.viewfinder",
                title: "Nahrávanie obrazovky",
                description: "Potrebné pre OCR – zachytenie oblasti obrazovky.",
                granted: false // runtime-checked by CGWindowList
            ) {
                PermissionsChecker.shared.openScreenRecordingSettings()
            }

            Divider()

            Text("API kľúč pre diktovanie")
                .font(.title3.bold())
            Text("Diktovanie posiela zvuk na prepis cez OpenAI — appka nemá vlastný kľúč zahrnutý, treba si vytvoriť vlastný (pár minút, platíš len za to, čo skutočne nadiktuješ).")
                .font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                numberedStep(1, "Vytvor si účet na", link: "platform.openai.com/signup", url: "https://platform.openai.com/signup")
                numberedStep(2, "V Billing pridaj platobnú kartu a kredit (stačí $5)", link: "platform.openai.com/settings/organization/billing", url: "https://platform.openai.com/settings/organization/billing")
                numberedStep(3, "V API keys vytvor nový kľúč (\"Create new secret key\")", link: "platform.openai.com/api-keys", url: "https://platform.openai.com/api-keys")
                numberedStep(4, "Skopíruj kľúč (začína „sk-…“) a vlož ho sem:")
            }

            HStack {
                SecureField("sk-…", text: $openAIKeyInput).textFieldStyle(.roundedBorder)
                Button("Prilepiť") {
                    if let s = NSPasteboard.general.string(forType: .string) { openAIKeyInput = s }
                }
                .buttonStyle(.bordered)
                Button(openAIKeySaved ? "Uložené ✓" : "Uložiť") {
                    dictation.openAIKey = openAIKeyInput
                    openAIKeySaved = true
                }
                .disabled(openAIKeyInput.isEmpty)
                .buttonStyle(.borderedProminent)
            }
            HStack {
                Button("Testovať kľúč") {
                    Task {
                        apiKeyTestRunning = true
                        apiKeyTestResult = await dictation.testAPIKey()
                        apiKeyTestRunning = false
                    }
                }
                .buttonStyle(.bordered)
                .disabled(apiKeyTestRunning || !dictation.hasOpenAIKey)
                if apiKeyTestRunning { ProgressView().controlSize(.small) }
            }
            if let result = apiKeyTestResult {
                Text(result).font(.caption)
                    .foregroundStyle(result.hasPrefix("✅") ? .green : (result.hasPrefix("⚠️") ? .orange : .red))
            }

            Divider()

            DisclosureGroup("Čítanie kvalitnejším hlasom (voliteľné)") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Appka vie čítať aj vstavaným systémovým hlasom bez akéhokoľvek nastavenia — toto je len voliteľné vylepšenie na prirodzenejšie znejúci hlas cez Google Cloud.")
                        .font(.caption).foregroundStyle(.secondary)
                    numberedStep(1, "V Google Cloud Console zapni „Cloud Text-to-Speech API“", link: "console.cloud.google.com/apis/library/texttospeech.googleapis.com", url: "https://console.cloud.google.com/apis/library/texttospeech.googleapis.com")
                    numberedStep(2, "Vytvor API kľúč v Credentials a vlož ho sem:", link: "console.cloud.google.com/apis/credentials", url: "https://console.cloud.google.com/apis/credentials")
                    HStack {
                        SecureField("AIza…", text: $googleKeyInput).textFieldStyle(.roundedBorder)
                        Button(googleKeySaved ? "Uložené ✓" : "Uložiť") {
                            google.apiKey = googleKeyInput
                            googleKeySaved = true
                        }
                        .disabled(googleKeyInput.isEmpty)
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.top, 8)
            }

            Divider()

            HStack {
                Button("Skontrolovať znova") { refresh() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Zavrieť") { dismiss(); onClose() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!allGranted)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            refresh()
            openAIKeyInput = dictation.openAIKey
            openAIKeySaved = dictation.hasOpenAIKey
            googleKeyInput = google.apiKey
            googleKeySaved = google.hasAPIKey
        }
        .onChange(of: openAIKeyInput) { _, _ in openAIKeySaved = false }
        .onChange(of: googleKeyInput) { _, _ in googleKeySaved = false }
        }
    }

    @ViewBuilder
    private func numberedStep(_ n: Int, _ text: String, link: String? = nil, url: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n).").font(.caption.bold()).foregroundStyle(.secondary).frame(width: 16, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.caption)
                if let link, let url, let u = URL(string: url) {
                    Link(link, destination: u).font(.caption2)
                }
            }
        }
    }

    private func refresh() {
        axGranted = AXIsProcessTrusted()
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
    }
}

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(granted ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(description).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if granted {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Povoliť", action: action).buttonStyle(.bordered).controlSize(.small)
            }
        }
    }
}

// MARK: - First-launch window

/// Shown automatically on first launch (see AppDelegate) — a friend who just downloaded
/// the app gets guided through permissions + API key setup instead of a bare menu bar icon.
@MainActor
final class OnboardingWindowController: NSWindowController {
    static let shared = OnboardingWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Vitaj v Osobnom pomocníkovi"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: OnboardingView(onClose: { [weak self] in
            self?.window?.close()
        }))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
