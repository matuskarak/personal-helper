import SwiftUI
import AVFoundation
import AppKit
import ServiceManagement
import Charts

struct PreferencesView: View {

    enum Tab: CaseIterable, Hashable {
        case general, dictation, reading, microphone, usage, history, quality, shortcuts, about

        // .history and .quality are rendered nested under .dictation (see `sidebar`), so
        // they're excluded from this flat top-level list.
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
    // Collapsed by default — fewer rows at first glance. Clicking "Diktovanie" opens it AND
    // toggles this, so there's exactly one hit target, not a separate arrow to miss.
    @State var dictationExpanded = false
    @State var showKeywordSuggestions = false
    @State var dictationIntroExpanded = false
    // Opened automatically in onAppear when Smart spracovanie is already configured.
    @State var smartSectionExpanded = false
    @State var realtimeSectionExpanded = true
    @State var batchSectionExpanded = true
    @State var keywordsSectionExpanded = true
    @State var pillSectionExpanded = false
    @State var duckSectionExpanded = false
    @State var keysSectionExpanded = true
    @State var editingKey: String?
    @State var voiceSectionExpanded = true
    @State var readingSectionExpanded = true
    @State var shortcutsIntroExpanded = false
    @State var micOrderExpanded = true
    @State var micTestExpanded = false
    @State var qualityModesExpanded = false
    @State var qualityModelsExpanded = false
    @State var qualityShadowExpanded = false
    @State var qualityFillersExpanded = false
    @State var qualityAppsExpanded = false
    @State var qualityRecentExpanded = true
    @State var diagnosticsExpanded = false
    @State var tts          = TTSEngine.shared
    @State var google       = GoogleCloudTTSEngine.shared
    @State var dictation    = DictationEngine.shared
    @State var duckAudio    = AudioDucking.shared
    @State var profileStore = AppProfileStore.shared
    @State var rewriteEngine = SmartRewriteEngine.shared
    @State var visionPromptExpanded = false
    @State var remoteConfig  = RemoteConfig.shared
    @State var telemetry     = Telemetry.shared
    @State var micTest       = MicTestEngine.shared
    @State var usageStore    = UsageStore.shared
    @State var historyStore  = DictationHistoryStore.shared
    @State var showOnboarding = false
    @State var developerMode = DeveloperMode.isEnabled
    @State var loggingEnabled = AppLogger.isEnabled
    @State var currency = AppCurrency.selected
    @State var logSizeBytes = 0
    @State var exportedLogName: String?
    @State var licenseKeyInput = ""
    @State var licenseKeySaved = false
    @State var pillFollowsField = PillPosition.followFocusedField
    @State var showResetShortcutsConfirm = false
    @State var shortcutsResetToken = 0
    @State var showClearHistoryConfirm = false
    @State var showClearShadowsConfirm = false
    @State var qualityStats = QualityStats(entries: [])
    @State var usagePeriod: UsagePeriod = .today
    @State var chartMetric: ChartMetric = .timeSaved
    @State var chartKind: ChartKind = .bar
    @State var customFrom = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State var customTo = Date()

    @State var smartModelInput = ""
    @State var inputDevices: [AudioInputDevice] = []
    @State var apiKeyTestRunning = false
    @State var apiKeyTestResult: Theme.KeyCheck?
    @State var apiKeyInput    = ""
    @State var apiKeySaved    = false
    @State var openAIKeyInput = ""
    @State var openAIKeySaved = false
    @State var geminiKeyInput = ""
    @State var geminiKeySaved = false
    @State var geminiKeyTestResult: Theme.KeyCheck?
    @State var geminiKeyTestRunning = false
    @State var googleKeyTestResult: Theme.KeyCheck?
    @State var googleKeyTestRunning = false
    @State var availableGoogleVoices: [GoogleVoice] = []
    @State var loadingVoices = false
    @State var voiceError: String?
    @State var testText  = "Toto je krátky test hlasu a rýchlosti čítania."

    // MARK: - Palette

    // Aliases kept so the tab files read unchanged; the values live in Theme.swift.
    let accent   = Theme.brandBlueSafe
    let pageBG   = Theme.surfaceBase
    let warnBG   = Theme.brandAmber.opacity(0.14)
    let warnFG   = Theme.brandAmberSafe
    let greenDot = Theme.success

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
        .frame(minWidth: 680, idealWidth: 720, minHeight: 480, idealHeight: 520)
        .font(Theme.body(13))
        .foregroundStyle(Theme.textPrimary)
        .tint(Theme.brandBlueSafe)
        .toolbar(.hidden, for: .windowToolbar)
        .sheet(isPresented: $showOnboarding) { OnboardingView() }
        .onAppear {
            apiKeyInput      = google.apiKey
            apiKeySaved      = google.hasAPIKey
            openAIKeyInput   = dictation.openAIKey
            openAIKeySaved   = dictation.hasOpenAIKey
            geminiKeyInput   = dictation.geminiKey
            geminiKeySaved   = dictation.hasGeminiKey
            smartModelInput  = rewriteEngine.model
            inputDevices     = AudioDeviceManager.inputDevices()
            licenseKeyInput  = remoteConfig.licenseKey
            licenseKeySaved  = true
            loggingEnabled   = AppLogger.isEnabled
            refreshLogSize()
            // Normalise legacy "minimal" → "low" (removed from new segmented control)
            if dictation.transcriptionDelay == "minimal" { dictation.transcriptionDelay = "low" }
            if google.hasAPIKey { Task { await loadGoogleVoices() } }
            if rewriteEngine.visionPromptEnabled || !profileStore.profiles.isEmpty || dictation.liveInsertEnabled {
                smartSectionExpanded = true
            }
        }
        .onChange(of: apiKeyInput)    { _, _ in apiKeySaved    = false }
        .onChange(of: openAIKeyInput) { _, _ in openAIKeySaved = false }
        .onChange(of: geminiKeyInput) { _, _ in geminiKeySaved = false }
        .onChange(of: licenseKeyInput) { _, _ in licenseKeySaved = false }
    }

    // MARK: - Sidebar

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Tab.topLevel, id: \.self) { tab in
                if tab == .dictation {
                    dictationDisclosureRow
                    if dictationExpanded {
                        sidebarRow(.history, indent: true)
                        sidebarRow(.quality, indent: true)
                    }
                } else {
                    sidebarRow(tab)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 20)
        .frame(width: 190)
    }

    /// Diktovanie's row both opens it AND toggles whether História/Kvalita show below it —
    /// one click target, not a separate arrow next to it. A prior version had a standalone
    /// chevron button beside the row; two adjacent, similar-looking hit targets doing
    /// different things was an easy way to click the wrong one, especially with imprecise
    /// pointer control. The chevron here is decoration inside this same button, not its own.
    var dictationDisclosureRow: some View {
        Button {
            selectedTab = .dictation
            withAnimation(.easeInOut(duration: 0.15)) { dictationExpanded.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: Tab.dictation.icon)
                    .font(.system(size: 13.5))
                    .foregroundStyle(selectedTab == .dictation ? accent : Theme.textSecondary)
                    .frame(width: 18)
                Text(Tab.dictation.label)
                    .font(Theme.body(13.5))
                    .foregroundStyle(selectedTab == .dictation ? accent : Theme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .rotationEffect(.degrees(dictationExpanded ? 90 : 0))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selectedTab == .dictation ? accent.opacity(0.12) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointingHandCursor()
        .focusEffectDisabled()
        .accessibilityAddTraits(selectedTab == .dictation ? .isSelected : [])
        .accessibilityHint(dictationExpanded ? "Rozbalené, obsahuje Históriu a Kvalitu" : "Zbalené, obsahuje Históriu a Kvalitu")
    }

    /// `indent` renders História/Kvalita one step in, with a smaller icon/font, while they're
    /// shown under the expanded Diktovanie row.
    func sidebarRow(_ tab: Tab, indent: Bool = false) -> some View {
        Button { selectedTab = tab } label: {
            HStack(spacing: 10) {
                if indent { Spacer().frame(width: 15) }
                Image(systemName: tab.icon)
                    .font(.system(size: indent ? 12 : 13.5))
                    .foregroundStyle(selectedTab == tab ? accent : Theme.textSecondary)
                    .frame(width: indent ? 15 : 18)
                Text(tab.label)
                    .font(Theme.body(indent ? 12.5 : 13.5))
                    .foregroundStyle(selectedTab == tab ? accent : Theme.textPrimary)
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
        // Color alone doesn't reach VoiceOver — without this trait, a screen-reader user
        // tabbing through the sidebar has no way to tell which tab is currently open.
        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
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
    struct MultilineField<Accessory: View>: View {
        @Binding var text: String
        var collapsedLines = 5
        var minLines = 3
        var accent = Theme.brandBlueSafe
        /// Floats in the field's bottom-right corner (e.g. an "AI suggest" button) — pinned to
        /// the TextEditor itself, not the whole VStack, so it stays in the corner of the box
        /// even when "Zobraziť viac" adds the expand link below.
        var accessory: Accessory

        @State private var expanded = false

        init(text: Binding<String>, collapsedLines: Int = 5, minLines: Int = 3,
             accent: Color = Theme.brandBlueSafe,
             @ViewBuilder accessory: () -> Accessory) {
            self._text = text; self.collapsedLines = collapsedLines; self.minLines = minLines
            self.accent = accent; self.accessory = accessory()
        }

        private var lineCount: Int {
            max(text.split(separator: "\n", omittingEmptySubsequences: false).count, minLines)
        }
        private var overflows: Bool { lineCount > collapsedLines }
        private var visibleLines: Int {
            guard overflows else { return lineCount }
            return expanded ? min(lineCount, MultilineFieldMetrics.maxExpandedLines) : collapsedLines
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                TextEditor(text: $text)
                    .font(Theme.body(13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: CGFloat(visibleLines) * MultilineFieldMetrics.lineHeight + MultilineFieldMetrics.inset)
                    // The card behind this is also white, so the border is the ONLY thing
                    // marking where the input starts — a hairline at 0.18 alpha read as
                    // "no box at all". Full pixel, darker than the card's own 0.07 outline.
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surfaceCard))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Theme.border, lineWidth: 1))
                    // Inset from the corner so it never sits on top of the TextEditor's own
                    // scrollbar (which claims the right edge) or the rounded border.
                    .overlay(alignment: .bottomTrailing) {
                        accessory.padding(.trailing, 18).padding(.bottom, 8)
                    }
                if overflows {
                    Button(expanded
                           ? "Zobraziť menej"
                           : "Zobraziť viac (\(lineCount - collapsedLines) \(Self.rowWord(lineCount - collapsedLines)))") {
                        expanded.toggle()
                    }
                    .font(Theme.body(11))
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


    // Static stored properties aren't allowed inside a generic type (MultilineField<Accessory>
    // now that it carries an accessory view) — pulled out here instead of per-specialization.
    private enum MultilineFieldMetrics {
        // .body is the 13pt system font — ~17pt per rendered line, plus the 6pt inset above
        // and below. Approximate on purpose: a wrong guess costs a few points of whitespace,
        // not a broken layout, and measuring real text metrics here isn't worth the code.
        static let lineHeight: CGFloat = 17
        static let inset: CGFloat = 12
        /// Expanded still needs a ceiling — the Settings window is only 520pt tall, so a long
        /// list would otherwise push every control below it out of reach.
        static let maxExpandedLines = 18
    }

    @ViewBuilder
    func card<Content: View>(@ViewBuilder _ body: () -> Content) -> some View {
        VStack(spacing: 0) { body() }
            .background(Theme.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.border, lineWidth: 1))
    }

    func warningBanner(_ message: String, action: (String, () -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            Circle().fill(warnFG).frame(width: 6, height: 6)
            Text(message)
                .font(Theme.body(12))
                .foregroundStyle(warnFG)
            Spacer()
            if let action {
                Button(action.0, action: action.1)
                    .font(Theme.body(11)).buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 8).fill(warnBG))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Theme.brandAmber.opacity(0.35), lineWidth: 1))
    }

    func toggleRow(title: String, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack(alignment: subtitle != nil ? .top : .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.body(13))
                if let sub = subtitle {
                    Text(sub).font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().tint(accent).toggleStyle(.switch)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, subtitle != nil ? 12 : 11)
    }

    /// `subtitle` is the one-sentence caption under the label (visible text, never a
    /// tooltip — see Notion decision 2026-08-24). Model explanations and prices live here.
    func pickerRow<T: Hashable, L: View>(
        title: String,
        subtitle: String? = nil,
        selection: Binding<T>,
        @ViewBuilder content: () -> L
    ) -> some View {
        HStack(alignment: subtitle != nil ? .top : .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.body(13))
                if let subtitle {
                    Text(subtitle).font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            Picker("", selection: selection) { content() }
                .labelsHidden()
                .frame(maxWidth: 260)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, subtitle != nil ? 12 : 11)
    }

    var rowDivider: some View {
        Divider().padding(.leading, 16)
    }

    /// Text-only row (a one-line note that belongs inside the card, under a divider).
    func captionRow(_ text: String, color: Color = Theme.textSecondary) -> some View {
        Text(text).font(Theme.body(11)).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 10)
    }

    /// Keyboard shortcut as a small pill next to a section title.
    func shortcutChip(_ shortcut: String) -> some View {
        Text(shortcut).font(Theme.body(11)).foregroundStyle(Theme.brandBlue)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(Theme.brandBlue.opacity(0.14)))
    }

    /// Small state pill ("nastavený", "aktívny").
    func statusChip(_ text: String, color: Color) -> some View {
        Text(text).font(Theme.body(11)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    /// Slovak plural: plural(3, "zariadenie", "zariadenia", "zariadení") → "3 zariadenia".
    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        switch n {
        case 1:     "1 \(one)"
        case 2...4: "\(n) \(few)"
        default:    "\(n) \(many)"
        }
    }

    static let sectionAnim: Animation? =
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.18)

    /// Collapsible card. The WHOLE header is the click target (44pt, hover tint) — not just a
    /// chevron. `status` is a short state summary on the right ("2 profily", "vypnuté").
    func sectionCard<Content: View>(
        _ title: String,
        shortcut: String? = nil,
        status: String? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        card {
            Button {
                withAnimation(Self.sectionAnim) { isExpanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                        .frame(width: 14)
                    Text(title).font(Theme.bodyBold(13)).foregroundStyle(Theme.textPrimary)
                    if let shortcut { shortcutChip(shortcut) }
                    Spacer()
                    if let status {
                        Text(status).font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(SectionHeaderStyle())
            .pointingHandCursor()
            .focusEffectDisabled()
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(isExpanded.wrappedValue ? "rozbalené" : "zbalené")
            if isExpanded.wrappedValue {
                Divider()
                content()
            }
        }
    }

    // MARK: - Helpers


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
    /// Debug builds only — in a release build this is hard-false, so no toggle can
    /// bypass RemoteConfig entitlements or expose dev-only UI to a paying user.
    static var isEnabled: Bool {
        get {
            #if DEBUG
            UserDefaults.standard.bool(forKey: key)
            #else
            false
            #endif
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

// Plain fields (no floating button) keep the old three-argument call shape — this is the
// only place accessory is fixed to EmptyView, so existing call sites don't need to change.
extension PreferencesView.MultilineField where Accessory == EmptyView {
    init(text: Binding<String>, collapsedLines: Int = 5, minLines: Int = 3,
         accent: Color = Theme.brandBlueSafe) {
        self.init(text: text, collapsedLines: collapsedLines, minLines: minLines, accent: accent) { EmptyView() }
    }
}

// MARK: - Section header button style (hover tint on the full-width header)

struct SectionHeaderStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HeaderLabel(configuration: configuration) }
    private struct HeaderLabel: View {
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .background(hover || configuration.isPressed ? Theme.textPrimary.opacity(0.05) : .clear)
                .onHover { hover = $0 }
        }
    }
}

extension View {
    /// Child setting of the row above it: indented + faintly tinted so the dependency reads.
    func nestedRow() -> some View {
        self.padding(.leading, 16).background(Theme.textPrimary.opacity(0.03))
    }
}
