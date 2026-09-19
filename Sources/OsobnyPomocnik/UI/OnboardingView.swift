import SwiftUI
import AVFoundation
import CoreGraphics

struct OnboardingView: View {
    /// Closes the standalone first-launch window. No-op when presented as a
    /// Preferences sheet, where `@Environment(\.dismiss)` already handles it.
    var onClose: () -> Void = {}
    /// Fires only for the "Dokončiť" button (end of the wizard), never for the mid-wizard
    /// "Zavrieť" shortcut and never for the Preferences sheet (default no-op there — the user
    /// is already in Settings). Used by the standalone first-launch window to open Settings
    /// on Všeobecné right after onboarding finishes.
    var onFinish: () -> Void = {}
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
    /// Set once the user has pressed the Screen Recording "Povoliť" button — used only to
    /// decide whether to show the "reštart Ozveny" note below the row (before that press it
    /// would be premature, since the row starts ungranted for everyone).
    @State private var screenAccessRequested = false

    var allGranted: Bool { axGranted && micGranted }
    var licenseOK: Bool { remoteConfig.hasValidLicense || DeveloperMode.isEnabled }
    var readyToClose: Bool { allGranted && licenseOK }

    /// One thing at a time: the old single scroll page put license, permissions, three API
    /// keys and telemetry on one screen — too much to take in at once, and the one step that
    /// blocks everything (license) was easy to miss.
    enum Step: Int, CaseIterable { case intro, license, permissions, apiKey, extras }
    @State private var step: Step = .intro

    private var canAdvance: Bool {
        switch step {
        case .license:     licenseOK
        case .permissions: allGranted
        default:           true
        }
    }

    private var blockedHint: String? {
        switch step {
        case .license where !licenseOK:        "Pokračovať sa dá po overení licenčného kľúča."
        case .permissions where !allGranted:   "Pokračovať sa dá po povolení Accessibility a mikrofónu."
        case .apiKey where !dictation.hasOpenAIKey: "Bez kľúča diktovanie nepôjde — doplníš ho aj neskôr v Nastaveniach."
        default: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if step != .intro {
                HStack(alignment: .center) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().interpolation(.high)
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                    Spacer()
                    progress
                }
            }

            Group {
                switch step {
                case .intro:       introStep
                case .license:     licenseStep
                case .permissions: permissionsStep
                case .apiKey:      apiKeyStep
                case .extras:      extrasStep
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            footer
        }
        .padding(24)
        .frame(width: 480)
        // Height follows the step's content — the window resizes per step instead of one fixed
        // tall box that's half empty on the short steps.
        .fixedSize(horizontal: false, vertical: true)
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
        // Granting Accessibility in System Settings doesn't bring us back to the front, so
        // didBecomeActive alone left the row red until the user clicked around — poll instead.
        .task(id: step) {
            while step == .permissions, !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: openAIKeyInput) { _, _ in openAIKeySaved = false }
        .onChange(of: googleKeyInput) { _, _ in googleKeySaved = false }
        .onChange(of: geminiKeyInput) { _, _ in geminiKeySaved = false }
        .onChange(of: licenseKeyInput) { _, _ in licenseKeySaved = false }
    }

    // MARK: - Chrome

    private var progress: some View {
        let steps = Step.allCases.filter { $0 != .intro }
        return HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(steps, id: \.self) { s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? Theme.brandBlueSafe : Color.primary.opacity(0.12))
                        .frame(width: 28, height: 4)
                }
            }
            Text("Krok \(step.rawValue) z \(steps.count)")
                .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Krok \(step.rawValue) z \(steps.count)")
    }

    private var footer: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Divider()
            HStack {
                if step != .intro {
                    Button("Späť") { go(-1) }.buttonStyle(.bordered)
                }
                Spacer()
                // From Preferences (everything already set up) there's no reason to click
                // through to the end just to get out.
                if readyToClose && step != .extras {
                    Button("Zavrieť") { dismiss(); onClose() }.buttonStyle(.bordered)
                }
                if step == .extras {
                    Button("Dokončiť") { dismiss(); onClose(); onFinish() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!readyToClose)
                } else {
                    Button(step == .intro ? "Začať" : "Ďalej") { go(1) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canAdvance)
                }
            }
            .padding(.top, 8)
            if let hint = blockedHint {
                Text(hint).font(Theme.body(11))
                    .foregroundStyle(canAdvance ? Theme.textSecondary : Theme.error)
            }
        }
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { step = next }
    }

    private func stepTitle(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.title(20))
            Text(subtitle).font(Theme.body(12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Steps

    private var introStep: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 16) {
                Text("Vitaj v appke Ozvena").font(Theme.title(24))
                Text("Diktuješ hlasom do ľubovoľnej appky — text sa vloží tam, kde práve píšeš. Označený text ti Ozvena vie aj prečítať nahlas.")
                    .font(Theme.body(13)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Nastavenie zaberie pár minút:").font(Theme.bodyBold(12))
                    numberedStep(1, "licenčný kľúč, ktorý ti pridelil vlastník appky")
                    numberedStep(2, "povolenia pre skratky a mikrofón")
                    numberedStep(3, "vlastný OpenAI API kľúč na prepis reči")
                }
            }
        }
    }

    private var licenseStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle("Licenčný kľúč",
                      "Ozvena bez platného licenčného kľúča nefunguje. Kľúč ti pridelí vlastník appky — vlož ho sem.")
            HStack {
                SecureField("licenčný kľúč", text: $licenseKeyInput).textFieldStyle(.roundedBorder)
                    .onSubmit { if !licenseKeyInput.isEmpty { remoteConfig.submitLicenseKey(licenseKeyInput) } }
                Button(remoteConfig.isValidating ? "Overujem…" : "Overiť") {
                    remoteConfig.submitLicenseKey(licenseKeyInput)
                    licenseKeySaved = true
                }
                .buttonStyle(.bordered)
                .disabled(licenseKeyInput.isEmpty || remoteConfig.isValidating)
            }
            LicenseValidationMessage(remoteConfig: remoteConfig)
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle("Povolenia", "macOS sa ťa na ne spýta raz. Po povolení sa riadok sám zazelená.")
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
                    description: "Pre Smart diktovanie (kontext obrazovky).",
                    granted: screenGranted,
                    // Not required for "Ďalej": it needs an app restart to take effect on
                    // macOS, so blocking onboarding on it here wouldn't help anyway.
                    note: (screenAccessRequested && !screenGranted)
                        ? "Po povolení macOS vyžaduje reštart Ozveny — urobíme ho na konci."
                        : nil
                ) {
                    screenAccessRequested = true
                    // Triggers the system permission prompt and registers the app in the
                    // Screen Recording list — merely opening System Settings (the old
                    // behavior) never did either, so testers landed on an empty list with
                    // nothing to toggle. Falls back to opening the settings pane when access
                    // is already denied (a second CGRequestScreenCaptureAccess() call won't
                    // re-show the system prompt at that point).
                    let granted = CGRequestScreenCaptureAccess()
                    screenGranted = granted
                    if !granted {
                        PermissionsChecker.shared.openScreenRecordingSettings()
                    }
                }
            }
        }
    }

    private var apiKeyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle("API kľúč pre diktovanie",
                      "Prepis reči ide cez OpenAI na tvoj vlastný kľúč — platíš len za to, čo naozaj nadiktuješ.")
            VStack(alignment: .leading, spacing: 6) {
                numberedStep(1, "Vytvor si účet na", link: "platform.openai.com/signup", url: "https://platform.openai.com/signup")
                numberedStep(2, "V Billing pridaj platobnú kartu a kredit (stačí $5)", link: "platform.openai.com/settings/organization/billing", url: "https://platform.openai.com/settings/organization/billing")
                numberedStep(3, "V API keys vytvor nový kľúč („Create new secret key“)", link: "platform.openai.com/api-keys", url: "https://platform.openai.com/api-keys")
                numberedStep(4, "Skopíruj kľúč (začína „sk-…“) a vlož ho sem:")
            }
            HStack {
                SecureField("sk-…", text: $openAIKeyInput).textFieldStyle(.roundedBorder)
                Button("Prilepiť") {
                    if let s = NSPasteboard.general.string(forType: .string) { openAIKeyInput = s }
                }
                .buttonStyle(.bordered)
                Button(openAIKeySaved ? "Uložené" : "Uložiť a overiť") {
                    dictation.openAIKey = openAIKeyInput
                    openAIKeySaved = true
                    Task {
                        apiKeyTestRunning = true
                        apiKeyTestResult = await dictation.testAPIKey()
                        apiKeyTestRunning = false
                    }
                }
                .disabled(openAIKeyInput.isEmpty || apiKeyTestRunning)
                .buttonStyle(.bordered)
            }
            if apiKeyTestRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Overujem kľúč…").font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                }
            } else if let result = apiKeyTestResult {
                Text(result.message).font(Theme.body(11)).foregroundStyle(result.color)
            }

            DisclosureGroup("Gemini kľúč (voliteľné — pre Gemini modely)") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Prepisovať vie aj Google Gemini (presnejší na odborné termíny). Treba ho len ak si v Nastaveniach vyberieš Gemini model.")
                        .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                    numberedStep(1, "Vytvor si kľúč na", link: "aistudio.google.com/apikey", url: "https://aistudio.google.com/apikey")
                    HStack {
                        SecureField("AIza…", text: $geminiKeyInput).textFieldStyle(.roundedBorder)
                        Button(geminiKeySaved ? "Uložené" : "Uložiť") {
                            dictation.geminiKey = geminiKeyInput
                            geminiKeySaved = true
                        }
                        .disabled(geminiKeyInput.isEmpty)
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private var extrasStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle("Takmer hotovo", "Dve voliteľné veci — obe sa dajú zmeniť kedykoľvek v Nastaveniach.")

            DisclosureGroup("Čítanie kvalitnejším hlasom") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ozvena číta aj vstavaným systémovým hlasom bez nastavovania — toto je len prirodzenejší hlas cez Google Cloud.")
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
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.top, 8)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: Binding(
                    get: { telemetry.isEnabled },
                    set: { telemetry.isEnabled = $0; if !$0 { telemetry.clearQueue() } }
                )) {
                    Text("Zdieľať anonymné štatistiky používania").font(Theme.bodyBold(13))
                }
                Text("Tempo reči, počet slov, výplňové slová, dĺžka diktovania a typ appky — bez samotného textu, mien, kľúčových slov či kľúčov. Pomáha to zlepšovať prepis.")
                    .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func numberedStep(_ n: Int, _ text: String, link: String? = nil, url: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n).").font(Theme.bodyBold(11)).foregroundStyle(Theme.textSecondary).frame(width: 16, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(Theme.body(11))
                if let link, let url, let u = URL(string: url) {
                    Link(destination: u) {
                        HStack(spacing: 3) {
                            Text(link).underline()
                            Image(systemName: "arrow.up.right").font(Theme.body(9))
                        }
                    }
                    .font(Theme.body(10))
                    .foregroundStyle(Theme.link)
                    .pointingHandCursor()
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

/// What the last license check said, in words — the "platný" chip alone gave no sign that
/// clicking Overiť did anything, and a network failure looked exactly like nothing happening.
struct LicenseValidationMessage: View {
    let remoteConfig: RemoteConfig

    var body: some View {
        if remoteConfig.isValidating {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Overujem kľúč…").foregroundStyle(Theme.textSecondary)
            }
            .font(Theme.body(12))
        } else if let (icon, text, color) = message {
            Label(text, systemImage: icon)
                .font(Theme.body(12)).foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var message: (String, String, Color)? {
        switch remoteConfig.lastOutcome {
        case .valid:   ("checkmark.circle.fill", "Kľúč je platný — Ozvena je odomknutá.", Theme.success)
        case .invalid: ("xmark.circle.fill", "Tento kľúč nie je platný. Skontroluj, či si ho skopíroval celý, prípadne napíš vlastníkovi appky.", Theme.error)
        case .offline: ("wifi.exclamationmark", "Kľúč sa nepodarilo overiť — skontroluj pripojenie na internet a skús znova.", Theme.warning)
        case nil where remoteConfig.hasValidLicense:
            ("checkmark.circle.fill", "Kľúč je platný.", Theme.success)
        case nil: nil
        }
    }
}

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let granted: Bool
    /// Extra line shown under the description — used for the "restart needed" hint after the
    /// Screen Recording button is pressed but access still isn't granted.
    var note: String? = nil
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(Theme.title(22))
                .frame(width: 32)
                .foregroundStyle(granted ? Theme.success : Theme.warning)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(description).font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                if let note {
                    Text(note).font(Theme.body(11)).foregroundStyle(Theme.warning)
                }
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
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Vitaj v appke Ozvena"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = FirstMouseHostingView(rootView: OnboardingView(
            onClose: { [weak self] in
                UserDefaults.standard.set(true, forKey: "onboarding.firstLaunchShown")
                self?.window?.close()
            },
            // Only for "Dokončiť" — lets a new user land somewhere after setup instead of
            // just a bare menu bar icon. Opens on Všeobecné by default (PreferencesView's
            // initial `selectedTab`).
            onFinish: {
                MenuBarController.shared?.openPreferences()
            }
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
