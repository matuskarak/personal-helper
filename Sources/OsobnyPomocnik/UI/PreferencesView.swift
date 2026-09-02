import SwiftUI
import AVFoundation
import AppKit
import ServiceManagement
import Charts

struct PreferencesView: View {

    enum Tab: CaseIterable, Hashable {
        case general, dictation, reading, microphone, usage, history, quality, shortcuts, about

        // Sidebar row order for the flat (top-level) items — .history and .quality are
        // rendered separately, nested under .dictation, so they're excluded here.
        static let topLevel: [Tab] = [.general, .dictation, .reading, .microphone, .usage, .shortcuts, .about]
        var label: String {
            switch self {
            case .general:    "Všeobecné"
            case .dictation:  "Diktovanie"
            case .reading:    "Čítanie"
            case .microphone: "Mikrofón"
            case .usage:      "Prehľad"
            case .history:    "História"
            case .quality:    "Kvalita"
            case .shortcuts:  "Skratky"
            case .about:      "O aplikácii"
            }
        }
        var icon: String {
            switch self {
            case .general:    "gearshape"
            case .dictation:  "mic"
            case .reading:    "chart.bar"
            case .microphone: "record.circle"
            case .usage:      "clock.arrow.circlepath"
            case .history:    "doc.text.magnifyingglass"
            case .quality:    "chart.line.uptrend.xyaxis"
            case .shortcuts:  "keyboard"
            case .about:      "info.circle"
            }
        }
    }

    /// Single period selector for the whole Prehľad tab — drives both the stat cards and the
    /// chart below them, so switching it never leaves the two showing different ranges.
    enum UsagePeriod: CaseIterable, Hashable {
        case today, week, month, year, custom
        var label: String {
            switch self {
            case .today:  "Dnes"
            case .week:   "Týždeň"
            case .month:  "Mesiac"
            case .year:   "Rok"
            case .custom: "Vlastné"
            }
        }
    }

    enum ChartMetric: CaseIterable, Hashable {
        case timeSaved, words
        var label: String {
            switch self {
            case .timeSaved: "Ušetrený čas"
            case .words:     "Nadiktované slová"
            }
        }
    }

    enum ChartKind: CaseIterable, Hashable {
        case bar, line
        var label: String {
            switch self {
            case .bar:  "Stĺpce"
            case .line: "Čiara"
            }
        }
    }

    @State var selectedTab: Tab = .dictation
    // Collapsed by default — expanded on demand, or automatically if the current tab is
    // one of its children (so History/Kvalita never end up hidden behind a chevron).
    @State var dictationExpanded = false
    @State var tts          = TTSEngine.shared
    @State var google       = GoogleCloudTTSEngine.shared
    @State var dictation    = DictationEngine.shared
    @State var profileStore = AppProfileStore.shared
    @State var rewriteEngine = SmartRewriteEngine.shared
    @State var visionPromptExpanded = false
    @State var remoteConfig  = RemoteConfig.shared
    @State var micTest       = MicTestEngine.shared
    @State var usageStore    = UsageStore.shared
    @State var historyStore  = DictationHistoryStore.shared
    @State var showOnboarding = false
    @State var developerMode = DeveloperMode.isEnabled
    @State var loggingEnabled = AppLogger.isEnabled
    @State var currency = AppCurrency.selected
    @State var logSizeBytes = 0
    @State var exportedLogName: String?
    @State var accessCodeInput = ""
    @State var accessCodeSaved = false
    @State var pillFollowsField = PillPosition.followFocusedField
    @State var showResetShortcutsConfirm = false
    @State var shortcutsResetToken = 0
    @State var qualityStats = QualityStats(entries: [])
    @State var usagePeriod: UsagePeriod = .today
    @State var chartMetric: ChartMetric = .timeSaved
    @State var chartKind: ChartKind = .bar
    @State var customFrom = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State var customTo = Date()

    @State var smartModelInput = ""
    @State var inputDevices: [AudioInputDevice] = []
    @State var apiKeyTestRunning = false
    @State var apiKeyTestResult: String?
    @State var apiKeyInput    = ""
    @State var apiKeySaved    = false
    @State var openAIKeyInput = ""
    @State var openAIKeySaved = false
    @State var geminiKeyInput = ""
    @State var geminiKeySaved = false
    @State var geminiKeyTestResult: String?
    @State var geminiKeyTestRunning = false
    @State var availableGoogleVoices: [GoogleVoice] = []
    @State var loadingVoices = false
    @State var voiceError: String?
    @State var rateInput = ""
    @State var testText  = "Toto je krátky test hlasu a rýchlosti čítania."

    // MARK: - Palette

    let accent  = Color(red: 0.357, green: 0.498, blue: 0.651)   // #5B7FA6
    let pageBG  = Color(red: 0.937, green: 0.918, blue: 0.898)   // warm cream
    let warnBG  = Color(red: 1.00,  green: 0.955, blue: 0.820)
    let warnFG  = Color(red: 0.76,  green: 0.45,  blue: 0.02)
    let greenDot = Color(red: 0.298, green: 0.686, blue: 0.490)

    // MARK: - Root

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ZStack(alignment: .topLeading) {
                pageBG.ignoresSafeArea()
                ScrollView {
                    Group {
                        switch selectedTab {
                        case .general:    generalTab
                        case .dictation:  dictationTab
                        case .reading:    readingTab
                        case .microphone: microphoneTab
                        case .usage:      usageTab
                        case .history:    historyTab
                        case .quality:    qualityTab
                        case .shortcuts:  shortcutsTab
                        case .about:      aboutTab
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // ponytail: same ScrollView instance across tabs — without a fresh
                    // identity per tab, scroll offset carries over (e.g. scrolled down in
                    // a long tab, switch to a short one → blank until scroll resets itself).
                    .id(selectedTab)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 720, height: 520)
        .toolbar(.hidden, for: .windowToolbar)
        .preferredColorScheme(.light)
        .sheet(isPresented: $showOnboarding) { OnboardingView() }
        .onAppear {
            apiKeyInput      = google.apiKey
            apiKeySaved      = google.hasAPIKey
            openAIKeyInput   = dictation.openAIKey
            openAIKeySaved   = dictation.hasOpenAIKey
            geminiKeyInput   = dictation.geminiKey
            geminiKeySaved   = dictation.hasGeminiKey
            rateInput        = rateString(tts.rate)
            smartModelInput  = rewriteEngine.model
            inputDevices     = AudioDeviceManager.inputDevices()
            accessCodeInput  = remoteConfig.accessCode
            accessCodeSaved  = true
            loggingEnabled   = AppLogger.isEnabled
            refreshLogSize()
            if selectedTab == .history || selectedTab == .quality { dictationExpanded = true }
            // Normalise legacy "minimal" → "low" (removed from new segmented control)
            if dictation.transcriptionDelay == "minimal" { dictation.transcriptionDelay = "low" }
            if google.hasAPIKey { Task { await loadGoogleVoices() } }
        }
        .onChange(of: apiKeyInput)    { _, _ in apiKeySaved    = false }
        .onChange(of: openAIKeyInput) { _, _ in openAIKeySaved = false }
        .onChange(of: geminiKeyInput) { _, _ in geminiKeySaved = false }
        .onChange(of: accessCodeInput) { _, _ in accessCodeSaved = false }
    }

    // MARK: - Sidebar

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Tab.topLevel, id: \.self) { tab in
                sidebarRow(tab, showsDisclosure: tab == .dictation)
                if tab == .dictation && dictationExpanded {
                    sidebarRow(.history, indent: true)
                    sidebarRow(.quality, indent: true)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 20)
        .frame(width: 190)
    }

    /// `showsDisclosure` adds a chevron after the label that toggles `dictationExpanded`
    /// independently of selecting the row — it's a separate button, a sibling of the
    /// navigation button rather than nested inside it, so clicking "Diktovanie" itself still
    /// just navigates there, same as every other row.
    /// `indent` renders History/Kvalita one step in, so they read as belonging to Diktovanie.
    func sidebarRow(_ tab: Tab, indent: Bool = false, showsDisclosure: Bool = false) -> some View {
        HStack(spacing: 4) {
            if indent { Spacer().frame(width: 14) }

            Button { selectedTab = tab } label: {
                HStack(spacing: 10) {
                    Image(systemName: tab.icon)
                        .font(.system(size: indent ? 12 : 13.5))
                        .foregroundStyle(selectedTab == tab ? accent : Color.secondary)
                        .frame(width: indent ? 15 : 18)
                    Text(tab.label)
                        .font(.system(size: indent ? 12.5 : 13.5))
                        .foregroundStyle(selectedTab == tab ? accent : Color.primary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, indent ? 6 : 7)
                // ponytail: `accent` stands in as the one accent color across the whole UI
                // until the app has real branding — this highlight is meant to move with it,
                // not be its own one-off color.
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(selectedTab == tab ? accent.opacity(0.12) : .clear)
                )
                // Without this, .buttonStyle(.plain).pointingHandCursor() only hit-tests the actual rendered
                // content (the icon + text), not the transparent space the Spacer() fills
                // out to the row's edge — so clicking the highlighted-looking area next to
                // the label silently did nothing. This is what made the sidebar feel like
                // it needed two or three clicks: most clicks were landing on "empty" pixels
                // that were never part of the hit region.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointingHandCursor()
            .focusEffectDisabled()

            if showsDisclosure {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { dictationExpanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(dictationExpanded ? 90 : 0))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointingHandCursor()
            }
        }
    }

    // MARK: - Shared components

    /// Multi-line text input, collapsed to a few rows with a show-more toggle.
    ///
    /// Deliberately NOT `TextField(axis: .vertical)`: on macOS that control submits on Return
    /// instead of inserting a newline, so a "one entry per line" list is literally untypable
    /// in it. TextEditor is the real multi-line control — Return does what it should.
    ///
    /// Collapsing matters because these lists grow: a 30-line keyword list rendered in full
    /// pushes everything below it off the screen. Collapsed rows are still scrollable and
    /// editable inside the editor, so nothing becomes unreachable — only quieter.
    struct MultilineField: View {
        @Binding var text: String
        var collapsedLines = 5
        var minLines = 3
        var accent = Color(red: 0.357, green: 0.498, blue: 0.651)

        @State private var expanded = false

        // .body is the 13pt system font — ~17pt per rendered line, plus the 6pt inset above
        // and below. Approximate on purpose: a wrong guess costs a few points of whitespace,
        // not a broken layout, and measuring real text metrics here isn't worth the code.
        private static let lineHeight: CGFloat = 17
        private static let inset: CGFloat = 12
        /// Expanded still needs a ceiling — the Settings window is only 520pt tall, so a long
        /// list would otherwise push every control below it out of reach.
        private static let maxExpandedLines = 18

        private var lineCount: Int {
            max(text.split(separator: "\n", omittingEmptySubsequences: false).count, minLines)
        }
        private var overflows: Bool { lineCount > collapsedLines }
        private var visibleLines: Int {
            guard overflows else { return lineCount }
            return expanded ? min(lineCount, Self.maxExpandedLines) : collapsedLines
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: CGFloat(visibleLines) * Self.lineHeight + Self.inset)
                    // The card behind this is also white, so the border is the ONLY thing
                    // marking where the input starts — a hairline at 0.18 alpha read as
                    // "no box at all". Full pixel, darker than the card's own 0.07 outline.
                    .background(RoundedRectangle(cornerRadius: 6).fill(.white))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.28), lineWidth: 1))
                if overflows {
                    Button(expanded
                           ? "Zobraziť menej"
                           : "Zobraziť viac (\(lineCount - collapsedLines) \(Self.rowWord(lineCount - collapsedLines)))") {
                        expanded.toggle()
                    }
                    .font(.caption)
                    .buttonStyle(.plain).pointingHandCursor()
                    .foregroundStyle(accent)
                }
            }
        }

        /// Slovak needs three forms here — "1 riadok", "2 riadky", "5 riadkov".
        private static func rowWord(_ n: Int) -> String {
            switch n {
            case 1:    "riadok"
            case 2...4: "riadky"
            default:   "riadkov"
            }
        }
    }

    @ViewBuilder
    func card<Content: View>(@ViewBuilder _ body: () -> Content) -> some View {
        VStack(spacing: 0) { body() }
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }

    func warningBanner(_ message: String, action: (String, () -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            Circle().fill(warnFG).frame(width: 6, height: 6)
            Text(message)
                .font(.callout)
                .foregroundStyle(warnFG)
            Spacer()
            if let action {
                Button(action.0, action: action.1)
                    .font(.caption).buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 8).fill(warnBG))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color(red: 0.85, green: 0.70, blue: 0.35).opacity(0.35), lineWidth: 0.5))
    }

    func toggleRow(title: String, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack(alignment: subtitle != nil ? .top : .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                if let sub = subtitle {
                    Text(sub).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().tint(accent).toggleStyle(.switch)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, subtitle != nil ? 12 : 11)
    }

    func pickerRow<T: Hashable, L: View>(
        title: String,
        selection: Binding<T>,
        @ViewBuilder content: () -> L
    ) -> some View {
        HStack {
            Text(title).font(.body)
            Spacer()
            Picker("", selection: selection) { content() }
                .labelsHidden()
                .frame(maxWidth: 260)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    var rowDivider: some View {
        Divider().padding(.leading, 16)
    }

    // MARK: - Helpers

    func rateString(_ r: Float) -> String { String(format: "×%.1f", r * 2) }

    func addProfileFromFrontmostApp() {
        let app = NSWorkspace.shared.frontmostApplication
        profileStore.profiles.append(AppProfile(
            displayName: app?.localizedName ?? "Nová appka",
            bundleID: app?.bundleIdentifier ?? "",
            titleKeyword: "",
            instructions: ""
        ))
    }

    func addProfileFromFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url) else { return }
        profileStore.profiles.append(AppProfile(
            displayName: bundle.infoDictionary?["CFBundleName"] as? String
                ?? url.deletingPathExtension().lastPathComponent,
            bundleID: bundle.bundleIdentifier ?? "",
            titleKeyword: "",
            instructions: ""
        ))
    }

    func loadGoogleVoices() async {
        loadingVoices = true; voiceError = nil
        do {
            availableGoogleVoices = try await google.fetchVoices()
            if !availableGoogleVoices.contains(where: { $0.name == google.selectedVoiceName }),
               let first = availableGoogleVoices.first(where: { $0.name.contains("HD") }) {
                google.selectedVoiceName = first.name
            }
        } catch { voiceError = error.localizedDescription }
        loadingVoices = false
    }
}

// MARK: - Float helper

private extension Float {
    func clamped(_ lo: Float, _ hi: Float) -> Float { Swift.min(hi, Swift.max(lo, self)) }
}

// MARK: - Launch at login

enum LaunchAtLogin {
    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else        { try SMAppService.mainApp.unregister() }
            } catch { print("[LaunchAtLogin] \(error)") }
        }
    }
}

// MARK: - Developer mode

enum DeveloperMode {
    static let key = "app.developerMode"
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
