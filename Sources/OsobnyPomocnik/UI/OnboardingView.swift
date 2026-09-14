import SwiftUI
import AVFoundation
import CoreGraphics

struct OnboardingView: View {
    /// Closes the standalone first-launch window. No-op when presented as a
    /// Preferences sheet, where `@Environment(\.dismiss)` already handles it.
    var onClose: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var axGranted = AXIsProcessTrusted()
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var screenGranted = CGPreflightScreenCaptureAccess()

    @State private var dictation = DictationEngine.shared
    @State private var google    = GoogleCloudTTSEngine.shared
    @State private var openAIKeyInput = ""
    @State private var openAIKeySaved = false
    @State private var apiKeyTestRunning = false
    @State private var apiKeyTestResult: Theme.KeyCheck?
    @State private var googleKeyInput = ""
    @State private var googleKeySaved = false
    @State private var geminiKeyInput = ""
    @State private var geminiKeySaved = false
    @State private var remoteConfig = RemoteConfig.shared
    @State private var telemetry = Telemetry.shared
    @State private var licenseKeyInput = ""
    @State private var licenseKeySaved = false

    var allGranted: Bool { axGranted && micGranted }
    var readyToClose: Bool { allGranted && (remoteConfig.hasValidLicense || DeveloperMode.isEnabled) }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Vitaj v appke Ozvena").font(Theme.title(22))
                Text("Diktuješ hlasom do ľubovoľnej appky, text sa vloží tam, kde píšeš; k tomu čítanie označeného textu nahlas a OCR z obrazovky. Na rozbehnutie budeš potrebovať štyri veci: licenčný kľúč, povolenia nižšie, vlastný OpenAI API kľúč a pár minút.")
                    .font(Theme.body(12)).foregroundStyle(Theme.textSecondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Licenčný kľúč").font(Theme.title(17))
                    Spacer()
                    statusChip(remoteConfig.hasValidLicense ? "platný" : "chýba",
                               color: remoteConfig.hasValidLicense ? Theme.success : Theme.error)
                }
                Text("Appka bez platného licenčného kľúča nefunguje — kľúč ti pridelí vlastník appky, vlož ho sem.")
                    .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                HStack {
                    SecureField("licenčný kľúč", text: $licenseKeyInput).textFieldStyle(.roundedBorder)
                    Button(remoteConfig.isValidating ? "Overujem…" : "Uložiť a overiť") {
                        remoteConfig.licenseKey = licenseKeyInput
                        licenseKeySaved = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(licenseKeyInput.isEmpty || remoteConfig.isValidating)
                    if remoteConfig.isValidating { ProgressView().controlSize(.small) }
                }
            }

            Divider()

            Text("Nastavenie povolení")
                .font(Theme.title(17))

            Text("Ozvena potrebuje nasledujúce povolenia:")
                .foregroundStyle(Theme.textSecondary)

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

            if remoteConfig.ocrAllowed || remoteConfig.smartDictationAllowed {
                PermissionRow(
                    icon: "camera.viewfinder",
                    title: "Nahrávanie obrazovky",
                    description: "Potrebné pre OCR a Smart diktovanie (kontext obrazovky).",
                    granted: screenGranted
                ) {
                    PermissionsChecker.shared.openScreenRecordingSettings()
                }
            }

            Divider()

            Text("API kľúč pre diktovanie")
                .font(Theme.title(17))
            Text("Diktovanie posiela zvuk na prepis cez OpenAI — appka nemá vlastný kľúč zahrnutý, treba si vytvoriť vlastný (pár minút, platíš len za to, čo skutočne nadiktuješ).")
                .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)

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
                Button(openAIKeySaved ? "Uložené" : "Uložiť") {
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
                Text(result.message).font(Theme.body(11)).foregroundStyle(result.color)
            }

            DisclosureGroup("Gemini kľúč (voliteľné — pre Gemini modely)") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Prepisovať vie aj Google Gemini (presnejší na odborné termíny). Ak si v Nastaveniach vyberieš Gemini model, treba kľúč z Google AI Studio — inak toto pole ignoruj.")
                        .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                    numberedStep(1, "Vytvor si kľúč na", link: "aistudio.google.com/apikey", url: "https://aistudio.google.com/apikey")
                    HStack {
                        SecureField("AIza…", text: $geminiKeyInput).textFieldStyle(.roundedBorder)
                        Button(geminiKeySaved ? "Uložené" : "Uložiť") {
                            dictation.geminiKey = geminiKeyInput
                            geminiKeySaved = true
                        }
                        .disabled(geminiKeyInput.isEmpty)
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.top, 8)
            }

            Divider()

            DisclosureGroup("Čítanie kvalitnejším hlasom (voliteľné)") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Appka vie čítať aj vstavaným systémovým hlasom bez akéhokoľvek nastavenia — toto je len voliteľné vylepšenie na prirodzenejšie znejúci hlas cez Google Cloud.")
                        .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                    numberedStep(1, "V Google Cloud Console zapni „Cloud Text-to-Speech API“", link: "console.cloud.google.com/apis/library/texttospeech.googleapis.com", url: "https://console.cloud.google.com/apis/library/texttospeech.googleapis.com")
                    numberedStep(2, "Vytvor API kľúč v Credentials a vlož ho sem:", link: "console.cloud.google.com/apis/credentials", url: "https://console.cloud.google.com/apis/credentials")
                    HStack {
                        SecureField("AIza…", text: $googleKeyInput).textFieldStyle(.roundedBorder)
                        Button(googleKeySaved ? "Uložené" : "Uložiť") {
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

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { telemetry.isEnabled },
                    set: { telemetry.isEnabled = $0; if !$0 { telemetry.clearQueue() } }
                )) {
                    Text("Zdieľať anonymné štatistiky používania").font(Theme.bodyBold(13))
                }
                Text("Tempo reči, počet slov, výplňové slová, dĺžka diktovania a typ appky — bez samotného textu, mien, kľúčových slov či kľúčov. Ide to do mojej tabuľky a pomáha zlepšovať prepis. Kedykoľvek vypneš v Nastaveniach → Všeobecné.")
                    .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
            }

            Divider()

            HStack {
                Button("Skontrolovať znova") { refresh() }
                    .buttonStyle(.bordered)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Button("Zavrieť") { dismiss(); onClose() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!readyToClose)
                    if !remoteConfig.hasValidLicense {
                        Text("Potrebuješ platný licenčný kľúč vyššie.")
                            .font(Theme.body(10)).foregroundStyle(Theme.error)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .font(Theme.body(13))
        .foregroundStyle(Theme.textPrimary)
        .tint(Theme.brandBlueSafe)
        .onAppear {
            refresh()
            openAIKeyInput = dictation.openAIKey
            openAIKeySaved = dictation.hasOpenAIKey
            geminiKeyInput = dictation.geminiKey
            geminiKeySaved = dictation.hasGeminiKey
            googleKeyInput = google.apiKey
            googleKeySaved = google.hasAPIKey
            licenseKeyInput = remoteConfig.licenseKey
            licenseKeySaved = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onChange(of: openAIKeyInput) { _, _ in openAIKeySaved = false }
        .onChange(of: googleKeyInput) { _, _ in googleKeySaved = false }
        .onChange(of: geminiKeyInput) { _, _ in geminiKeySaved = false }
        .onChange(of: licenseKeyInput) { _, _ in licenseKeySaved = false }
        }
    }

    @ViewBuilder
    private func numberedStep(_ n: Int, _ text: String, link: String? = nil, url: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n).").font(Theme.bodyBold(11)).foregroundStyle(Theme.textSecondary).frame(width: 16, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(Theme.body(11))
                if let link, let url, let u = URL(string: url) {
                    Link(link, destination: u).font(Theme.body(10))
                }
            }
        }
    }

    /// Small state pill — same look as `PreferencesView.statusChip`, duplicated here since
    /// this view isn't a `PreferencesView` extension.
    private func statusChip(_ text: String, color: Color) -> some View {
        Text(text).font(Theme.body(11)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private func refresh() {
        axGranted = AXIsProcessTrusted()
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        screenGranted = CGPreflightScreenCaptureAccess()
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
                .font(Theme.title(22))
                .frame(width: 32)
                .foregroundStyle(granted ? Theme.success : Theme.brandAmberSafe)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(description).font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            if granted {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
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
        window.title = "Vitaj v appke Ozvena"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = FirstMouseHostingView(rootView: OnboardingView(onClose: { [weak self] in
            UserDefaults.standard.set(true, forKey: "onboarding.firstLaunchShown")
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
