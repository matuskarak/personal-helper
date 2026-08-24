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

    @State private var selectedTab: Tab = .dictation
    // Collapsed by default — expanded on demand, or automatically if the current tab is
    // one of its children (so History/Kvalita never end up hidden behind a chevron).
    @State private var dictationExpanded = false
    @State private var tts          = TTSEngine.shared
    @State private var google       = GoogleCloudTTSEngine.shared
    @State private var dictation    = DictationEngine.shared
    @State private var profileStore = AppProfileStore.shared
    @State private var rewriteEngine = SmartRewriteEngine.shared
    @State private var visionPromptExpanded = false
    @State private var remoteConfig  = RemoteConfig.shared
    @State private var micTest       = MicTestEngine.shared
    @State private var usageStore    = UsageStore.shared
    @State private var historyStore  = DictationHistoryStore.shared
    @State private var showOnboarding = false
    @State private var developerMode = DeveloperMode.isEnabled
    @State private var loggingEnabled = AppLogger.isEnabled
    @State private var currency = AppCurrency.selected
    @State private var logSizeBytes = 0
    @State private var exportedLogName: String?
    @State private var accessCodeInput = ""
    @State private var accessCodeSaved = false
    @State private var pillFollowsField = PillPosition.followFocusedField
    @State private var showResetShortcutsConfirm = false
    @State private var shortcutsResetToken = 0
    @State private var qualityStats = QualityStats(entries: [])
    @State private var usagePeriod: UsagePeriod = .today
    @State private var chartMetric: ChartMetric = .timeSaved
    @State private var chartKind: ChartKind = .bar
    @State private var customFrom = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var customTo = Date()

    @State private var smartModelInput = ""
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var apiKeyTestRunning = false
    @State private var apiKeyTestResult: String?
    @State private var apiKeyInput    = ""
    @State private var apiKeySaved    = false
    @State private var openAIKeyInput = ""
    @State private var openAIKeySaved = false
    @State private var availableGoogleVoices: [GoogleVoice] = []
    @State private var loadingVoices = false
    @State private var voiceError: String?
    @State private var rateInput = ""
    @State private var testText  = "Toto je krátky test hlasu a rýchlosti čítania."

    // MARK: - Palette

    private let accent  = Color(red: 0.357, green: 0.498, blue: 0.651)   // #5B7FA6
    private let pageBG  = Color(red: 0.937, green: 0.918, blue: 0.898)   // warm cream
    private let warnBG  = Color(red: 1.00,  green: 0.955, blue: 0.820)
    private let warnFG  = Color(red: 0.76,  green: 0.45,  blue: 0.02)
    private let greenDot = Color(red: 0.298, green: 0.686, blue: 0.490)

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
        .onChange(of: accessCodeInput) { _, _ in accessCodeSaved = false }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
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
    private func sidebarRow(_ tab: Tab, indent: Bool = false, showsDisclosure: Bool = false) -> some View {
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
    private struct MultilineField: View {
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
    private func card<Content: View>(@ViewBuilder _ body: () -> Content) -> some View {
        VStack(spacing: 0) { body() }
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }

    private func warningBanner(_ message: String, action: (String, () -> Void)? = nil) -> some View {
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

    private func toggleRow(title: String, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
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

    private func pickerRow<T: Hashable, L: View>(
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

    private var rowDivider: some View {
        Divider().padding(.leading, 16)
    }

    // MARK: - Všeobecné

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Všeobecné").font(.title2.bold())

            card {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mena pre ceny").font(.body)
                        Text("Ceny sú orientačné, podľa cenníka OpenAI (\(Pricing.ratesCheckedOn)). Prepočet z dolárov je fixný, nie podľa aktuálneho kurzu.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { currency },
                        set: { currency = $0; AppCurrency.selected = $0 }
                    )) {
                        ForEach(AppCurrency.allCases, id: \.self) { c in
                            Text(c.label).tag(c)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    .labelsHidden()
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
    }

    // MARK: - Diktovanie

    private var dictationTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Diktovanie").font(.title2.bold())

            // How the shortcut scheme works — the mode/processing split lives in the
            // shortcuts now, so the settings only pick MODELS per mode, not the mode itself.
            Text("Režim prepisu voliš skratkou, ktorou diktovanie SPUSTÍŠ (\(scLabel(.dictateRealtime)) = realtime, \(scLabel(.dictateBatch)) = po nahraní). Skratka, ktorou diktovanie UKONČÍŠ, rozhoduje o spracovaní: tá istá ako pri štarte = vloží sa čistý prepis; \(scLabel(.smartStop)) = text pred vložením upraví AI s kontextom obrazovky (Smart). Iné diktovacie skratky sa počas nahrávania ignorujú.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)

            card {
                toggleRow(title: "Live vkladanie",
                          subtitle: "Píše text do poľa priebežne počas realtime diktovania. Kým je zapnuté, Smart ukončenie (\(scLabel(.smartStop))) sa pri realtime nedá použiť — text je už vložený.",
                          isOn: $dictation.liveInsertEnabled)
                if dictation.liveInsertEnabled {
                    rowDivider
                    toggleRow(title: "Enter zastaví diktovanie",
                              subtitle: "Stlačenie Enter automaticky ukončí nahrávanie",
                              isOn: $dictation.enterAutoStop)
                }
            }

            // Realtime mode — model + keywords + VAD (VAD is a realtime-socket setting)
            Text("Realtime diktovanie — skratka \(scLabel(.dictateRealtime))").font(.headline)
            card {
                Text("Slová nabiehajú priebežne už počas rozprávania — najrýchlejšia cesta pre krátke diktovania. \(Pricing.perMinuteLabel(realtime: true)).")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.top, 10)
                rowDivider
                // Both realtime models cost the same, so no price in the labels here.
                pickerRow(title: "Model", selection: $dictation.realtimeModel) {
                    ForEach(DictationEngine.RealtimeModel.allCases, id: \.self) { model in
                        Text(model.label).tag(model)
                    }
                }
                if dictation.realtimeModel == .live {
                    rowDivider
                    Text("gpt-live-transcribe je vyhradený prepisovací model — na rozdiel od pôvodného gpt-realtime-whisper vie využiť kľúčové slová a kontext appky. Cena je rovnaká.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                }
                rowDivider
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Citlivosť VAD").font(.body)
                        Text(vadSubtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: $dictation.transcriptionDelay) {
                        Text("Rýchla").tag("low")
                        Text("Stredná").tag("medium")
                        Text("Pomalá").tag("high")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                    .labelsHidden()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            // Keywords apply to BOTH modes — the batch path forwards them as `prompt` too —
            // so this gets its own card instead of living under the realtime model.
            Text("Kľúčové slová").font(.headline)
            card {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Predvolené kľúčové slová").font(.body)
                    Text("Platia pri každom diktovaní v oboch režimoch, nezávisle od appky — jedno slovo alebo fráza na riadok. Napríklad tvoje meno, názvy klientov, nástrojov a odborné termíny, ktoré bežne diktuješ. Sú to nápovede pre model, nie príkazy — pomáhajú hlavne pri anglických výrazoch v slovenskej vete. Pri diktovaní do konkrétnej appky sa k nim pridajú aj kľúčové slová z jej App profilu.")
                        .font(.caption).foregroundStyle(.secondary)
                    MultilineField(text: $dictation.defaultKeywords, accent: accent)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }

            // Batch mode — model only
            Text("Diktovanie po nahraní — skratka \(scLabel(.dictateBatch))").font(.headline)
            card {
                Text("Celé sa najprv nahrá a prepíše až po zastavení — presnejšie a lacnejšie, vhodné na dlhšie diktovania. Počas nahrávania sa nezobrazujú priebežné slová.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.top, 10)
                rowDivider
                pickerRow(title: "Model", selection: $dictation.batchModel) {
                    ForEach(DictationEngine.batchModels, id: \.self) { model in
                        Text("\(model)\(Self.modelNote(model)) — \(Pricing.perMinuteLabel(realtime: false, batchModel: model))")
                            .tag(model)
                    }
                }
            }

            // Pozícia pilulky
            card {
                toggleRow(title: "Zobrazovať pilulku nad aktívnym poľom",
                          subtitle: "Namiesto stredu obrazovky sa pilulka zobrazí priamo nad textovým poľom, do ktorého diktuješ",
                          isOn: Binding(
                    get: { pillFollowsField },
                    set: { pillFollowsField = $0; PillPosition.followFocusedField = $0 }
                ))
                rowDivider
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pozícia pilulky").font(.body)
                        Text("Pilulku môžeš kedykoľvek presunúť ťahaním myšou. Predvolene sa centruje na obrazovke, na ktorej práve pracuješ.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Resetovať pozíciu") { PillPosition.reset() }
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }

            // OpenAI API key
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("OpenAI API kľúč").font(.body)
                    HStack {
                        SecureField("sk-…", text: $openAIKeyInput).textFieldStyle(.roundedBorder)
                        Button(openAIKeySaved ? "Uložené ✓" : "Uložiť") {
                            dictation.openAIKey = openAIKeyInput
                            openAIKeySaved = true
                        }
                        .disabled(openAIKeyInput.isEmpty)
                        .buttonStyle(.borderedProminent).tint(accent)
                    }
                    if let result = apiKeyTestResult {
                        Text(result).font(.caption)
                            .foregroundStyle(result.hasPrefix("✅") ? .green :
                                            (result.hasPrefix("⚠️") ? .orange : .red))
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
                        Spacer()
                        Link("Získať kľúč →",
                             destination: URL(string: "https://platform.openai.com/api-keys")!)
                            .font(.caption)
                    }
                }
                .padding(16)
            }

            if remoteConfig.smartDictationAllowed {
                // Smart rewrite model
                Text("Smart spracovanie — ukonči diktovanie skratkou \(scLabel(.smartStop))").font(.headline)
                card {
                    Text("Smart nie je samostatný režim — je to spôsob UKONČENIA. Diktovanie spustíš hociktorou z dvoch skratiek vyššie; keď ho ukončíš skratkou \(scLabel(.smartStop)), AI pred vložením prepis upraví podľa kontextu obrazovky (opraví názvy, formu, appke primeraný tón). Stlačená mimo diktovania nerobí nič.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.top, 10)
                    if !CGPreflightScreenCaptureAccess() {
                        warningBanner(
                            "Bez povolenia 'Nahrávanie obrazovky' Smart spracovanie neuvidí obsah obrazovky — funguje len ako oprava gramatiky.",
                            action: ("Otvoriť nastavenia", { PermissionsChecker.shared.openScreenRecordingSettings() })
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    }
                    rowDivider
                    pickerRow(title: "Model Smart prepisu", selection: $smartModelInput) {
                        Text("gpt-4o-mini (rýchly, odporúčaný)").tag("gpt-4o-mini")
                        Text("gpt-4o (presnejší)").tag("gpt-4o")
                        Text("gpt-4.1-mini").tag("gpt-4.1-mini")
                        Text("gpt-4.1").tag("gpt-4.1")
                    }
                    .onChange(of: smartModelInput) { _, v in rewriteEngine.model = v }
                }

                // Vision-context prompt
                card {
                    toggleRow(title: "Kontext zo screenshotu",
                              subtitle: "Vysvetlí modelu, ako má screenshot použiť pri oprave prepisu",
                              isOn: $rewriteEngine.visionPromptEnabled)
                    if rewriteEngine.visionPromptEnabled {
                        rowDivider
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Prompt").font(.body)
                            Text("Uprav si predvolený text podľa potreby. Úplným vymazaním sa vráti predvolený prompt.")
                                .font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $rewriteEngine.visionPromptOverride)
                                .font(.body)
                                .frame(height: visionPromptExpanded ? 200 : 54)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                            Button(visionPromptExpanded ? "Zobraziť menej" : "Zobraziť viac") {
                                visionPromptExpanded.toggle()
                            }
                            .buttonStyle(.plain).pointingHandCursor().font(.caption).foregroundStyle(accent)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                    rowDivider
                    toggleRow(title: "Ukladať screenshoty do histórie",
                              subtitle: "Na ladenie: uloží presne to, čo model videl pri Smart prepise, ku každému diktovaniu v karte Kvalita. Môžu obsahovať citlivý obsah obrazovky — vypni, keď doladíš.",
                              isOn: $rewriteEngine.saveScreenshotsToHistory)
                }

                // App profiles
                card {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Profily podľa aplikácie").font(.body)
                            Spacer()
                            Button("+ Pridať") { profileStore.addBlank() }
                                .buttonStyle(.bordered).font(.caption)
                            Button("Aktuálna appka") { addProfileFromFrontmostApp() }
                                .buttonStyle(.bordered).font(.caption)
                            Button("Vybrať appku…") { addProfileFromFilePicker() }
                                .buttonStyle(.bordered).font(.caption)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)

                        if !profileStore.profiles.isEmpty {
                            rowDivider
                            ForEach($profileStore.profiles) { $profile in
                                DisclosureGroup(
                                    profile.displayName.isEmpty ? "Bez názvu" : profile.displayName
                                ) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        TextField("Názov", text: $profile.displayName)
                                        TextField("Bundle ID (napr. com.tinyspeck.slackmacgap)",
                                                  text: $profile.bundleID)
                                        TextField("Kľúčové slovo v titulku (voliteľné)",
                                                  text: $profile.titleKeyword)
                                        HStack {
                                            Text("Typ cieľa").font(.callout)
                                            Picker("", selection: $profile.category) {
                                                ForEach(AppCategory.allCases, id: \.self) { cat in
                                                    Text(cat.label).tag(cat)
                                                }
                                            }
                                            .labelsHidden()
                                        }
                                        Text("Určuje rubriku hodnotenia na karte Kvalita a (pri gpt-live-transcribe) kontextovú vetu poslanú modelu — napr. pre AI chat: \"Používateľ diktuje prompt pre AI nástroj.\" Needituje sa ručne.")
                                            .font(.caption2).foregroundStyle(.secondary)
                                        MultilineField(text: $profile.instructions, collapsedLines: 4, accent: accent)
                                        Text("Kľúčové slová").font(.callout)
                                        Text("Platia iba pri diktovaní do TEJTO appky, naviac k predvoleným v Nastaveniach → Diktovanie. Nápoveda pre gpt-live-transcribe, jedno slovo/fráza na riadok.")
                                            .font(.caption2).foregroundStyle(.secondary)
                                        MultilineField(text: $profile.keywords, accent: accent)
                                        HStack {
                                            Spacer()
                                            Button("Odstrániť", role: .destructive) {
                                                profileStore.remove(profile)
                                            }.font(.caption)
                                        }
                                    }
                                    .padding(.vertical, 8)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 10)
                                rowDivider
                            }
                        }
                    }
                }
            }

            // Usage
            let dictMins = Double(dictation.totalSecondsRecorded) / 60
            let dictCost = dictMins * dictation.costPerMinute
            HStack {
                Text(String(format: "Využité tento mesiac: %.1f min (~%@)", dictMins, currency.format(usd: dictCost)))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Resetovať") { dictation.resetUsageCounter() }
                    .font(.caption).foregroundStyle(.red).buttonStyle(.plain).pointingHandCursor()
            }
            .padding(.horizontal, 4)
        }
    }

    /// First shortcut mapped to the action, for inline mentions in explanations.
    private func scLabel(_ action: ShortcutStore.Action) -> String {
        ShortcutStore.shared.shortcuts(for: action).first?.displayString ?? "?"
    }

    private var vadSubtitle: String {
        switch dictation.transcriptionDelay {
        case "low":    return "Rýchla reakcia"
        case "medium": return "Vyvážená reakcia"
        default:       return "Pomalá reakcia"
        }
    }

    // MARK: - Čítanie

    private var readingTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Čítanie").font(.title2.bold())

            card {
                pickerRow(title: "Engine", selection: $tts.mode) {
                    ForEach(TTSMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                if tts.mode == .googleCloud {
                    rowDivider
                    VStack(alignment: .leading, spacing: 10) {
                        Text("API kľúč").font(.body)
                        HStack {
                            SecureField("AIza...", text: $apiKeyInput).textFieldStyle(.roundedBorder)
                            Button(apiKeySaved ? "Uložené ✓" : "Uložiť") {
                                google.apiKey = apiKeyInput
                                apiKeySaved = true
                                Task { await loadGoogleVoices() }
                            }
                            .disabled(apiKeyInput.isEmpty)
                            .buttonStyle(.borderedProminent).tint(accent)
                        }
                        if let err = voiceError {
                            Text(err).foregroundStyle(.red).font(.caption)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)

                    rowDivider
                    if !availableGoogleVoices.isEmpty {
                        pickerRow(title: "Hlas", selection: $google.selectedVoiceName) {
                            ForEach(availableGoogleVoices) { voice in
                                Text(voice.displayName).tag(voice.name)
                            }
                        }
                    } else {
                        HStack {
                            Text("Hlas").font(.body)
                            Spacer()
                            if loadingVoices {
                                ProgressView().controlSize(.small)
                                Text("Načítavam…").foregroundStyle(.secondary).font(.caption)
                            } else {
                                Button("Načítať hlasy") { Task { await loadGoogleVoices() } }
                                    .buttonStyle(.bordered).disabled(!google.hasAPIKey)
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                    }

                    rowDivider
                    HStack {
                        Button("Otestovať hlas") {
                            TTSEngine.shared.stop()
                            TTSEngine.shared.speak(testText, trackUsage: false)
                        }
                        .buttonStyle(.borderedProminent).tint(accent)
                        if tts.isSpeaking {
                            Button("Stop") { TTSEngine.shared.stop() }
                                .buttonStyle(.bordered).foregroundStyle(.red)
                        }
                        Spacer()
                        Link("Získať API kľúč →",
                             destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                            .font(.caption)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }

                if tts.mode == .system {
                    rowDivider
                    pickerRow(title: "macOS hlas", selection: Binding(
                        get: { tts.selectedVoiceIdentifier ?? "" },
                        set: { tts.selectedVoiceIdentifier = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("Automaticky").tag("")
                        ForEach(tts.availableSkVoices, id: \.identifier) { voice in
                            Text("\(voice.name) (\(voice.quality == .enhanced ? "Enhanced" : "Standard"))")
                                .tag(voice.identifier)
                        }
                    }
                    rowDivider
                    HStack {
                        TextField("Testovací text…", text: $testText).textFieldStyle(.roundedBorder)
                        Button("Prehrať") {
                            TTSEngine.shared.stop()
                            TTSEngine.shared.speak(testText, trackUsage: false)
                        }
                        .buttonStyle(.borderedProminent).tint(accent).disabled(testText.isEmpty)
                        if tts.isSpeaking {
                            Button("Stop") { TTSEngine.shared.stop() }
                                .buttonStyle(.bordered).foregroundStyle(.red)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
            }

            // Jazyk + rýchlosť + pilulka
            card {
                pickerRow(title: "Jazyk čítania", selection: $tts.languageMode) {
                    Text("Automaticky").tag("auto")
                    Text("Slovenčina").tag("sk-SK")
                    Text("English").tag("en-US")
                }
                rowDivider
                VStack(alignment: .leading, spacing: 8) {
                    Text("Rýchlosť čítania").font(.body)
                    HStack(spacing: 8) {
                        Text("Pomaly").font(.caption).foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { Double(tts.rate) },
                                set: { tts.rate = Float($0); rateInput = rateString(Float($0)) }
                            ),
                            in: 0.1...1.0
                        ).tint(accent)
                        Text("Rýchlo").font(.caption).foregroundStyle(.secondary)
                        Text(rateInput).font(.caption).monospacedDigit().frame(width: 32)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                rowDivider
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automaticky skryť pilulku").font(.body)
                        Text("Pilulka čítania sa skryje po nečinnosti")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { UserDefaults.standard.object(forKey: "controlPanel.autoHideSecs") as? Int ?? 60 },
                        set: { UserDefaults.standard.set($0, forKey: "controlPanel.autoHideSecs") }
                    )) {
                        Text("Nikdy").tag(0)
                        Text("30 sekúnd").tag(30)
                        Text("1 minúta").tag(60)
                        Text("2 minúty").tag(120)
                    }
                    .labelsHidden().frame(maxWidth: 160)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }

            // Google usage
            if tts.mode == .googleCloud {
                let chars = Double(google.totalCharactersUsed)
                let voice = google.selectedVoiceName
                let rate: Double = voice.contains("Chirp3-HD") || voice.contains("Chirp-HD") ? 0.00016
                                 : (voice.contains("WaveNet") || voice.contains("Neural2"))  ? 0.000016
                                 : 0.000004
                HStack {
                    Text(String(format: "Znaky tento mesiac: %d (~%@)",
                                google.totalCharactersUsed, currency.format(usd: chars * rate)))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Resetovať") { google.resetCharacterCount() }
                        .font(.caption).foregroundStyle(.red).buttonStyle(.plain).pointingHandCursor()
                }
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Mikrofón

    private var microphoneTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mikrofón").font(.title2.bold())
            Text("Zoraď mikrofóny podľa dôležitosti — pri štarte diktovania appka použije prvý pripojený z tohto poradia. Ak nie je pripojený žiadny, použije systémový mikrofón.")
                .font(.caption).foregroundStyle(.secondary)

            // Keyed by stableKey, not raw uid — the priority list is stored as stableKeys
            // (see AudioInputDevice.stableKey) so the same USB mic still matches after
            // being moved to a different port. uniquingKeysWith just keeps the first when
            // two simultaneously-connected devices happen to collapse to one key.
            let deviceByKey   = Dictionary(inputDevices.map { ($0.stableKey, $0) }, uniquingKeysWith: { first, _ in first })
            let resolvedKey   = inputDevices.first(where: { $0.uid == dictation.resolvedInputDeviceUID() })?.stableKey
            let unprioritized = inputDevices.filter { !dictation.micPriority.contains($0.stableKey) }

            if !dictation.micPriority.isEmpty {
                card {
                    List {
                        ForEach(dictation.micPriority, id: \.self) { key in
                            let device = deviceByKey[key]
                            let connected = device != nil
                            HStack(spacing: 14) {
                                Image(systemName: "line.3.horizontal")
                                    .font(.caption).foregroundStyle(.tertiary)
                                Image(systemName: connected ? deviceIcon(device!.name) : "mic.slash")
                                    .font(.system(size: 13)).foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text(device?.name ?? savedDeviceName(key))
                                    .font(key == resolvedKey ? .body.bold() : .body)
                                if key == resolvedKey {
                                    Text("aktívny").font(.caption2).foregroundStyle(accent)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(accent.opacity(0.12)))
                                }
                                Spacer()
                                HStack(spacing: 5) {
                                    Circle().fill(connected ? greenDot : Color.secondary.opacity(0.45))
                                        .frame(width: 6, height: 6)
                                    Text(connected ? "Pripojené" : "Nedostupné")
                                        .font(.caption).foregroundStyle(connected ? greenDot : Color.secondary)
                                }
                                Button {
                                    dictation.micPriority.removeAll { $0 == key }
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain).pointingHandCursor()
                            }
                            .padding(.vertical, 4)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                        .onMove { indices, newOffset in
                            dictation.micPriority.move(fromOffsets: indices, toOffset: newOffset)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .frame(height: CGFloat(dictation.micPriority.count) * 40 + 16)
                    .padding(.horizontal, 4)
                }
            }

            if !unprioritized.isEmpty {
                card {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(dictation.micPriority.isEmpty ? "Dostupné zariadenia" : "Pridať do poradia")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
                        ForEach(unprioritized) { device in
                            Divider().padding(.leading, 50)
                            Button {
                                dictation.micPriority.append(device.stableKey)
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "plus.circle")
                                        .font(.system(size: 13)).foregroundStyle(accent)
                                        .frame(width: 18)
                                    Image(systemName: deviceIcon(device.name))
                                        .font(.system(size: 13)).foregroundStyle(.secondary)
                                    Text(device.name)
                                    Spacer()
                                }
                                .padding(.horizontal, 16).padding(.vertical, 13)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).pointingHandCursor()
                        }
                    }
                }
            }

            HStack {
                Button("Obnoviť zoznam") { inputDevices = AudioDeviceManager.inputDevices() }
                    .buttonStyle(.bordered).font(.caption)
                if !dictation.micPriority.isEmpty {
                    Button("Vymazať poradie") { dictation.micPriority = [] }
                        .buttonStyle(.bordered).font(.caption).foregroundStyle(.red)
                }
            }

            micTestCard
        }
    }

    // MARK: - Mic test

    @ViewBuilder
    private var micTestCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Test mikrofónu").font(.body.bold())
                Text("Prečítaj nahlas zobrazenú vetu — appka skontroluje hlasitosť, šum na pozadí a či prepis sedí s tým, čo si povedal.")
                    .font(.caption).foregroundStyle(.secondary)

                // Reference sentence stays visible for the whole test — it needs to be
                // readable WHILE recording, not just before/after.
                Text("„\(micTest.referenceText)“")
                    .font(.callout.italic())
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(accent.opacity(0.06)))

                switch micTest.phase {
                case .idle, .done, .failed:
                    if case .failed(let msg) = micTest.phase {
                        Text(msg).font(.caption).foregroundStyle(.red)
                    }
                    if let r = micTest.result {
                        micTestResultView(r)
                    }
                    Button(micTest.result == nil ? "Spustiť test" : "Skúsiť znova") {
                        micTest.startTest()
                    }
                    .buttonStyle(.borderedProminent).tint(accent)

                case .preparing(let secondsLeft):
                    HStack(spacing: 12) {
                        MicEqualizerView(isActive: false, tint: .secondary)
                        Text("Priprav sa… \(secondsLeft)s").foregroundStyle(.secondary)
                        Spacer()
                        Button("Zrušiť") { micTest.cancel() }.buttonStyle(.bordered)
                    }

                case .recording(let secondsLeft):
                    HStack(spacing: 12) {
                        MicEqualizerView(isActive: true, tint: .blue, level: micTest.liveLevel)
                        Text("Nahrávam… \(secondsLeft)s").foregroundStyle(.secondary)
                        Spacer()
                        Button("Zrušiť") { micTest.cancel() }.buttonStyle(.bordered)
                    }

                case .analyzing:
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Analyzujem nahrávku…").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func micTestResultView(_ r: MicTestEngine.Result) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(verdictColor(r.verdict)).frame(width: 8, height: 8)
                Text(verdictLabel(r.verdict)).font(.body.bold()).foregroundStyle(verdictColor(r.verdict))
            }
            HStack(spacing: 20) {
                metricStat("Hlasitosť (peak)", String(format: "%.0f dBFS", r.peakDBFS))
                if let snr = r.snrDB {
                    metricStat("Šum (SNR)", String(format: "%.0f dB", snr))
                }
                if r.clippingPercent > 0.05 {
                    metricStat("Skreslenie", String(format: "%.1f%%", r.clippingPercent))
                }
                if let match = r.matchPercent {
                    metricStat("Zhoda prepisu", String(format: "%.0f%%", match))
                }
            }
            ForEach(r.suggestions, id: \.self) { s in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundStyle(.secondary)
                    Text(s).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let t = r.transcript {
                Text("Prepis: „\(t)“").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private func metricStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.callout.monospacedDigit().bold())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func verdictColor(_ v: MicTestEngine.Verdict) -> Color {
        switch v {
        case .excellent, .good: greenDot
        case .marginal: .orange
        case .poor: .red
        }
    }

    private func verdictLabel(_ v: MicTestEngine.Verdict) -> String {
        switch v {
        case .excellent: "Výborné"
        case .good: "Dobré"
        case .marginal: "Priemerné"
        case .poor: "Slabé"
        }
    }

    private func deviceIcon(_ name: String) -> String {
        let l = name.lowercased()
        if l.contains("airpod")                          { return "airpodspro" }
        if l.contains("macbook") || l.contains("built")  { return "laptopcomputer" }
        return "mic.circle"
    }

    /// Best-effort display name for a disconnected device, parsed straight out of its
    /// stableKey — still `AppleUSBAudioEngine:<Manufacturer>:<Product>` for USB, so the
    /// product name is at the same index whether or not the device is currently plugged in.
    private func savedDeviceName(_ key: String) -> String {
        let parts = key.split(separator: ":").map(String.init)
        return parts.count >= 3 ? parts[2] : key
    }

    // MARK: - História

    private static let historyDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d. M. HH:mm"
        return f
    }()

    private var historyTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("História diktovania").font(.title2.bold())
            Text("Posledné nadiktované texty — len lokálne. Keďže sem môže padnúť čokoľvek, čo nadiktuješ, históriu môžeš kedykoľvek celú vymazať.")
                .font(.caption).foregroundStyle(.secondary)

            if historyStore.entries.isEmpty {
                card {
                    Text("Zatiaľ žiadna história.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(24)
                }
            } else {
                card {
                    // Lazy: history is uncapped (hundreds of entries and growing) and this
                    // used to build every row eagerly on tab open — the История tab's lag.
                    LazyVStack(spacing: 0) {
                        ForEach(Array(historyStore.entries.reversed().enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { rowDivider }
                            historyRow(entry)
                        }
                    }
                }
                Button("Vymazať históriu") { historyStore.clearAll() }
                    .buttonStyle(.bordered).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func historyRow(_ entry: DictationHistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.historyDateFormatter.string(from: entry.date))
                    .font(.caption2).foregroundStyle(.tertiary)
                // Same text that the insert button pastes — see MenuBarController's history menu.
                Text(entry.rewrittenText ?? entry.text)
                    .font(.callout)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                let text = entry.rewrittenText ?? entry.text
                AppLogger.log("[PreferencesView] história — vložené na požiadanie (\(text.count) znakov)")
                TextInserter.shared.insert(text)
            } label: {
                Image(systemName: "arrow.right.doc.on.clipboard")
            }
            .buttonStyle(.bordered)
            .help("Vložiť do aktívneho poľa")
            Button {
                historyStore.delete(entry.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain).pointingHandCursor()
            .foregroundStyle(.secondary)
            .help("Vymazať túto položku")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Kvalita diktovania

    /// Everything the Kvalita tab draws, derived in ONE pass over the history.
    ///
    /// ponytail: recomputed on appear and whenever the history grows — not on every render.
    /// Each card used to walk the full history itself (analyzed list, filler totals, per-app
    /// grouping, four mode filters), so a tab with 570+ entries did six full passes every
    /// time any unrelated observable changed. Upgrade path if history reaches six figures:
    /// keep running totals in the store instead of rebuilding here.
    private struct QualityStats {
        var analyzed: [(entry: DictationHistoryEntry, metrics: DictationMetrics)] = []
        var avgWPM = 0
        var avgFillers = 0.0
        var topFillers: [(word: String, count: Int)] = []
        var perApp: [(name: String, count: Int, paced: Int, avgFillers: Double, category: AppCategory)] = []
        var modeCombos: [(label: String, count: Int)] = []
        var modeTotal = 0

        /// Only entries logged since quality tracking shipped carry metrics — older history
        /// has no numbers to show, so everything here is computed off that filtered list.
        init(entries: [DictationHistoryEntry]) {
            analyzed = entries.compactMap { e in e.metrics.map { (entry: e, metrics: $0) } }

            var wpmSum = 0, paced = 0
            var fillerRateSum = 0.0
            var fillerTotals: [String: Int] = [:]
            var groups: [String: (count: Int, fillerRateSum: Double, paced: Int, category: AppCategory)] = [:]
            for item in analyzed {
                if item.metrics.wordsPerMinute > 0 {
                    wpmSum += item.metrics.wordsPerMinute
                    fillerRateSum += item.metrics.fillersPerMinute
                    paced += 1
                }
                for (word, count) in item.metrics.fillers { fillerTotals[word, default: 0] += count }

                let key = item.entry.appName.isEmpty ? "Neznáma appka" : item.entry.appName
                var g = groups[key] ?? (0, 0, 0, item.entry.category)
                g.count += 1
                if item.metrics.wordsPerMinute > 0 {
                    g.fillerRateSum += item.metrics.fillersPerMinute
                    g.paced += 1
                }
                groups[key] = g
            }
            if paced > 0 {
                avgWPM = Int((Double(wpmSum) / Double(paced)).rounded())
                avgFillers = fillerRateSum / Double(paced)
            }
            topFillers = fillerTotals
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .prefix(5).map { (word: $0.key, count: $0.value) }
            perApp = groups
                .sorted { $0.value.count > $1.value.count }
                .map { (name: $0.key, count: $0.value.count, paced: $0.value.paced,
                        avgFillers: $0.value.paced > 0 ? $0.value.fillerRateSum / Double($0.value.paced) : 0,
                        category: $0.value.category) }

            // Mode/Smart split — only entries recorded since per-shortcut modes shipped.
            let tracked = entries.filter { $0.mode != nil }
            modeTotal = tracked.count
            modeCombos = [
                ("Realtime — čisté",   tracked.filter { $0.mode == "realtime" && $0.smart != true }.count),
                ("Realtime + Smart",   tracked.filter { $0.mode == "realtime" && $0.smart == true }.count),
                ("Po nahraní — čisté", tracked.filter { $0.mode == "batch"    && $0.smart != true }.count),
                ("Po nahraní + Smart", tracked.filter { $0.mode == "batch"    && $0.smart == true }.count),
            ].map { (label: $0.0, count: $0.1) }
        }
    }

    private func ratingColor(_ rating: DictationQualityEngine.Rating) -> Color {
        switch rating {
        case .good: greenDot
        case .fair: warnFG
        case .poor: .red
        }
    }

    private var qualityTab: some View {
        let stats = qualityStats
        let analyzed = stats.analyzed
        return VStack(alignment: .leading, spacing: 16) {
            Text("Kvalita diktovania").font(.title2.bold())
            Text("Vyhodnotené lokálne z tvojej histórie diktovania — nič sa neposiela nikam von a nič to nestojí. Ukazuje, ako naozaj diktuješ, aby si sa v tom mohol zlepšovať.")
                .font(.caption).foregroundStyle(.secondary)

            if analyzed.isEmpty {
                card {
                    VStack(spacing: 6) {
                        Text("Zatiaľ nemáme dosť dát.").font(.callout)
                        Text("Metriky sa počítajú až pri nových diktovaniach — staršie záznamy v histórii ich neobsahujú.")
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(24)
                }
            } else {
                qualitySummaryCard(stats)
                modeUsageCard(stats)
                topFillersCard(stats)
                perAppCard(stats)
                recentDictationsCard(analyzed)
            }
        }
        .onAppear { qualityStats = QualityStats(entries: historyStore.entries) }
        .onChange(of: historyStore.entries.count) { _, _ in
            qualityStats = QualityStats(entries: historyStore.entries)
        }
    }

    private func qualitySummaryCard(_ stats: QualityStats) -> some View {
        card {
            HStack(spacing: 0) {
                statTile(value: "\(stats.analyzed.count)", label: "diktovaní", color: .primary)
                Divider().frame(height: 44)
                statTile(value: String(format: "%.1f", stats.avgFillers), label: "výplňových slov / min",
                         color: ratingColor(DictationQualityEngine.fillerRating(perMinute: stats.avgFillers)))
                Divider().frame(height: 44)
                statTile(value: stats.avgWPM > 0 ? "\(stats.avgWPM)" : "–", label: "slov / min",
                         color: ratingColor(DictationQualityEngine.paceRating(wpm: stats.avgWPM)))
            }
            .padding(.vertical, 16)
        }
    }

    /// How dictation is actually used: realtime vs batch, raw vs Smart finish.
    /// Only entries recorded since per-shortcut modes shipped can tell — older ones can't.
    private func modeUsageCard(_ stats: QualityStats) -> some View {
        card {
            VStack(alignment: .leading, spacing: 0) {
                Text("Využitie režimov").font(.body)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                rowDivider
                if stats.modeTotal == 0 {
                    Text("Zatiaľ žiadne dáta — režim sa zaznamenáva pri nových diktovaniach.")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                } else {
                    ForEach(Array(stats.modeCombos.enumerated()), id: \.offset) { index, combo in
                        if index > 0 { rowDivider }
                        HStack {
                            Text(combo.label).font(.callout)
                            Spacer()
                            Text("\(combo.count)× (\(Int((Double(combo.count) / Double(stats.modeTotal) * 100).rounded())) %)")
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                    rowDivider
                    Text("Spolu \(stats.modeTotal) diktovaní so zaznamenaným režimom. Staršie záznamy režim nemajú a nepočítajú sa.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
        }
    }

    private func statTile(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 24, weight: .semibold)).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func topFillersCard(_ stats: QualityStats) -> some View {
        card {
            VStack(alignment: .leading, spacing: 0) {
                Text("Najčastejšie výplňové slová")
                    .font(.body).padding(.horizontal, 16).padding(.vertical, 12)
                rowDivider
                if stats.topFillers.isEmpty {
                    Text("Žiadne — čisté diktovanie.")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                } else {
                    ForEach(Array(stats.topFillers.enumerated()), id: \.element.word) { index, pair in
                        if index > 0 { rowDivider }
                        HStack {
                            Text("„\(pair.word)”").font(.callout)
                            Spacer()
                            Text("\(pair.count)×").font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                }
            }
        }
    }

    /// Grouped by the app dictated into — the whole point is seeing that you speak
    /// differently to ChatGPT than to Slack.
    private func perAppCard(_ stats: QualityStats) -> some View {
        card {
            VStack(alignment: .leading, spacing: 0) {
                Text("Podľa aplikácie")
                    .font(.body).padding(.horizontal, 16).padding(.vertical, 12)
                rowDivider
                ForEach(Array(stats.perApp.enumerated()), id: \.element.name) { index, row in
                    if index > 0 { rowDivider }
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name).font(.callout)
                            Text(row.category.label)
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text("\(row.count)× diktovanie")
                            .font(.caption).foregroundStyle(.secondary)
                        if row.paced > 0 {
                            Text(String(format: "%.1f fill./min", row.avgFillers))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(ratingColor(DictationQualityEngine.fillerRating(perMinute: row.avgFillers)))
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
        }
    }

    private func recentDictationsCard(
        _ analyzed: [(entry: DictationHistoryEntry, metrics: DictationMetrics)]
    ) -> some View {
        let recent = Array(analyzed.reversed().prefix(15))
        return card {
            VStack(alignment: .leading, spacing: 0) {
                Text("Posledné diktovania")
                    .font(.body).padding(.horizontal, 16).padding(.vertical, 12)
                rowDivider
                ForEach(Array(recent.enumerated()), id: \.element.entry.id) { index, item in
                    if index > 0 { rowDivider }
                    qualityDetailRow(item.entry, item.metrics)
                }
            }
        }
    }

    private func qualityDetailRow(_ entry: DictationHistoryEntry, _ m: DictationMetrics) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                metricLine("Slov", "\(m.wordCount)")
                if m.wordsPerMinute > 0 {
                    metricLine("Tempo", "\(m.wordsPerMinute) slov/min",
                               color: ratingColor(DictationQualityEngine.paceRating(wpm: m.wordsPerMinute)))
                }
                metricLine("Výplňové slová", m.fillerCount == 0 ? "žiadne"
                    : "\(m.fillerCount) (\(m.fillers.sorted { $0.value > $1.value }.map(\.key).joined(separator: ", ")))",
                           color: m.fillerCount == 0 ? nil
                            : ratingColor(DictationQualityEngine.fillerRating(perMinute: m.fillersPerMinute)))
                if m.avgSentenceWords > 0 {
                    metricLine("Priemerná veta", "\(m.avgSentenceWords) slov")
                }
                if m.repeatedSentenceStarts > 0 {
                    metricLine("Opakované začiatky viet", "\(m.repeatedSentenceStarts)", color: warnFG)
                }
                if let ratio = m.rewriteDistanceRatio {
                    metricLine("Smart prepis zmenil", "\(Int((ratio * 100).rounded())) % textu",
                               color: ratio > 0.5 ? warnFG : nil)
                }

                Divider()
                Text("Nadiktované").font(.caption2).foregroundStyle(.tertiary)
                Text(entry.text).font(.callout).textSelection(.enabled)
                if let rewritten = entry.rewrittenText, !rewritten.isEmpty {
                    Text("Po Smart prepise").font(.caption2).foregroundStyle(.tertiary)
                    Text(rewritten).font(.callout).textSelection(.enabled)
                }
                if entry.hasScreenshot {
                    Text("Screenshot pri diktovaní").font(.caption2).foregroundStyle(.tertiary)
                    let url = DictationHistoryStore.shared.screenshotURL(for: entry.id)
                    if let image = NSImage(contentsOf: url) {
                        Image(nsImage: image)
                            .resizable().scaledToFit()
                            .frame(maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .onTapGesture { NSWorkspace.shared.open(url) }
                            .pointingHandCursor()
                            .help("Otvoriť v plnej veľkosti")
                    }
                }
            }
            .padding(.vertical, 8)
        } label: {
            HStack(spacing: 8) {
                Text(Self.historyDateFormatter.string(from: entry.date))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if !entry.appName.isEmpty {
                    Text(entry.appName).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                if m.fillerCount > 0 {
                    Text("\(m.fillerCount) fill.")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(ratingColor(DictationQualityEngine.fillerRating(perMinute: m.fillersPerMinute)))
                }
                if m.wordsPerMinute > 0 {
                    Text("\(m.wordsPerMinute) wpm")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func metricLine(_ label: String, _ value: String, color: Color? = nil) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption).foregroundStyle(color ?? .primary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Prehľad (usage)

    /// The one date range the whole Prehľad tab reads from — the top Dnes/Týždeň/Mesiac/
    /// Rok/Vlastné picker picks which case applies, so the stat cards and the chart below
    /// them can never end up showing different periods (they used to: an earlier version
    /// had a separate range picker just for the chart).
    private func currentUsageRange() -> (from: Date, to: Date) {
        let cal = Calendar.current
        let now = Date()
        switch usagePeriod {
        case .today:
            let start = cal.startOfDay(for: now)
            return (start, cal.date(byAdding: .day, value: 1, to: start) ?? now)
        case .week:
            // Monday-first by definition of the ISO8601 calendar's weekOfYear.
            var iso = Calendar(identifier: .iso8601); iso.timeZone = .current
            let comps = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            let start = iso.date(from: comps) ?? now
            return (start, iso.date(byAdding: .day, value: 7, to: start) ?? now)
        case .month:
            let comps = cal.dateComponents([.year, .month], from: now)
            let start = cal.date(from: comps) ?? now
            return (start, cal.date(byAdding: .month, value: 1, to: start) ?? now)
        case .year:
            let comps = cal.dateComponents([.year], from: now)
            let start = cal.date(from: comps) ?? now
            return (start, cal.date(byAdding: .year, value: 1, to: start) ?? now)
        case .custom:
            return (customFrom, customTo)
        }
    }

    private var usageTab: some View {
        let range = currentUsageRange()
        let summary = usageStore.summary(from: range.from, to: range.to)

        return VStack(alignment: .leading, spacing: 16) {
            Text("Prehľad využitia").font(.title2.bold())

            HStack(spacing: 10) {
                Picker("", selection: $usagePeriod) {
                    ForEach(UsagePeriod.allCases, id: \.self) { p in
                        Text(p.label).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 460)

                if usagePeriod == .custom {
                    DatePicker("Od", selection: $customFrom,
                               in: earliestStoredDate...customTo, displayedComponents: .date)
                    DatePicker("Do", selection: $customTo,
                               in: customFrom...Date(), displayedComponents: .date)
                }
                Spacer()
            }
            .font(.caption)

            card {
                HStack(spacing: 18) {
                    Image(systemName: "clock.badge.checkmark")
                        .font(.system(size: 26))
                        .foregroundStyle(accent)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ušetrený čas").font(.caption).foregroundStyle(.secondary)
                        Text(timeSavedString(summary)).font(.title2.bold())
                    }
                    Spacer()
                }
                .padding(18)
            }

            HStack(alignment: .top, spacing: 16) {
                card {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Diktovanie", systemImage: "mic.fill")
                            .font(.headline).foregroundStyle(accent)
                        usageStatRow("Čas diktovania", minutesString(summary.dictationSeconds))
                        usageStatRow("Nadiktované slová", "\(summary.dictationWords)")
                        usageStatRow("Cena", dictationCostString(summary.dictationSeconds))
                    }
                    .padding(16)
                }
                card {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Čítanie", systemImage: "speaker.wave.2.fill")
                            .font(.headline).foregroundStyle(accent)
                        usageStatRow("Prečítané slová", "\(summary.readingWords)")
                        usageStatRow("Znakov", "\(summary.readingChars)")
                        if tts.mode == .googleCloud {
                            usageStatRow("Cena", readingCostString(summary.readingChars))
                        }
                    }
                    .padding(16)
                }
            }

            Text("Ušetrený čas je odhad: diktovanie sa porovnáva s písaním na klávesnici (~40 slov/min), čítanie s manuálnym čítaním (~120 slov/min) oproti počúvaniu (~180 slov/min).")
                .font(.caption2).foregroundStyle(.tertiary)

            usageChart(range: range)
        }
    }

    /// Earliest selectable date for the custom range — matches UsageStore's own retention,
    /// so the picker can't offer a date the store has already pruned.
    private var earliestStoredDate: Date {
        Calendar.current.date(byAdding: .day, value: -UsageStore.maxAgeDays, to: Date()) ?? Date.distantPast
    }

    private func usageChart(range: (from: Date, to: Date)) -> some View {
        let buckets = usageStore.dictationDailyByModel(from: range.from, to: range.to)
        return card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Vývoj diktovania").font(.headline)
                    Spacer()
                    Picker("", selection: $chartKind) {
                        ForEach(ChartKind.allCases, id: \.self) { k in Text(k.label).tag(k) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 120)
                    Picker("", selection: $chartMetric) {
                        ForEach(ChartMetric.allCases, id: \.self) { m in Text(m.label).tag(m) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 230)
                }

                if buckets.isEmpty {
                    Text("Zatiaľ žiadne dáta za toto obdobie.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
                } else {
                    Chart(buckets) { b in
                        switch chartKind {
                        case .bar:
                            BarMark(
                                x: .value("Deň", b.day, unit: .day),
                                y: .value(chartMetric.label, chartValue(b))
                            )
                            .foregroundStyle(by: .value("Model", modelLabel(b.model)))
                        case .line:
                            LineMark(
                                x: .value("Deň", b.day, unit: .day),
                                y: .value(chartMetric.label, chartValue(b))
                            )
                            .foregroundStyle(by: .value("Model", modelLabel(b.model)))
                            .symbol(by: .value("Model", modelLabel(b.model)))
                        }
                    }
                    .chartForegroundStyleScale(range: [accent, accent.opacity(0.55), accent.opacity(0.3)])
                    .chartLegend(position: .bottom, spacing: 8)
                    .frame(height: 180)
                }
            }
            .padding(16)
        }
    }

    private func chartValue(_ b: UsageStore.DailyModelBucket) -> Double {
        switch chartMetric {
        case .words:     Double(b.words)
        case .timeSaved: max(0, Double(b.words) / 40.0 - Double(b.seconds) / 60.0)
        }
    }

    private func modelLabel(_ raw: String) -> String {
        switch raw {
        case "gpt-live-transcribe":     "Live"
        case "gpt-realtime-whisper":    "Realtime"
        case "gpt-transcribe":          "Transcribe"
        case "gpt-4o-mini-transcribe":  "4o-mini"
        case "gpt-4o-transcribe":       "4o"
        case "whisper-1":               "Whisper-1"
        default:                        raw.isEmpty ? "—" : raw
        }
    }

    private func usageStatRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout.monospacedDigit())
        }
    }

    private func minutesString(_ seconds: Int) -> String {
        let m = seconds / 60, s = seconds % 60
        return String(format: "%d:%02d min", m, s)
    }

    private func dictationCostString(_ seconds: Int) -> String {
        "~" + currency.format(usd: Double(seconds) / 60 * dictation.costPerMinute)
    }

    private func readingCostString(_ chars: Int) -> String {
        let rate = Pricing.googleTTSUSDPerChar(voice: google.selectedVoiceName)
        return "~" + currency.format(usd: Double(chars) * rate)
    }

    /// ponytail: closed-form estimate, no real playback-duration tracking —
    /// dictation compares actual seconds to a 40wpm typing baseline; reading
    /// compares a 120wpm manual-reading baseline to a 180wpm TTS-listening baseline.
    private func timeSavedString(_ s: UsageStore.Summary) -> String {
        UsageStore.savedTimeText(s)
    }

    // MARK: - Skratky

    private var shortcutsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Klávesové skratky").font(.title2.bold())

            card {
                ShortcutMappingRow(label: "Diktovanie — realtime", action: .dictateRealtime)
                rowDivider
                ShortcutMappingRow(label: "Diktovanie — po nahraní", action: .dictateBatch)
                if remoteConfig.smartDictationAllowed {
                    rowDivider
                    ShortcutMappingRow(label: "Smart ukončenie diktovania", action: .smartStop)
                }
                rowDivider
                ShortcutMappingRow(label: "Čítať text", action: .readText)
                rowDivider
                ShortcutMappingRow(label: "OCR oblasť", action: .ocr)
                rowDivider
                ShortcutMappingRow(label: "Vložiť z pamäte", action: .insertFromMemory)
            }
            .id(shortcutsResetToken) // forces each row to reload from the store after a reset

            Text("Diktovacia skratka režim aj spúšťa aj zastavuje (zastaví ho len tá istá skratka, ktorou začal). „Smart ukončenie“ nie je samostatné diktovanie — ukončí bežiace diktovanie a prepis pred vložením upraví AI.\n\nKlikni na skratku a stlač novú kombináciu (vyžaduje aspoň jeden modifier). Tlačidlom „+“ pridáš ďalšiu skratku pre tú istú akciu — napríklad inú kombináciu na externej klávesnici než na notebooku (max \(ShortcutStore.maxPerAction)).")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)

            Button("Obnoviť predvolené skratky") { showResetShortcutsConfirm = true }
                .buttonStyle(.bordered)
                .confirmationDialog(
                    "Obnoviť všetky skratky na predvolené hodnoty?",
                    isPresented: $showResetShortcutsConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Obnoviť", role: .destructive) {
                        ShortcutStore.shared.resetAllToDefaults()
                        shortcutsResetToken += 1
                    }
                    Button("Zrušiť", role: .cancel) {}
                } message: {
                    Text("Odstráni všetky pridané skratky a vráti pôvodné kombinácie.")
                }
        }
    }

    // MARK: - O aplikácii

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("O aplikácii").font(.title2.bold())

            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(accent).frame(width: 56, height: 56)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Osobný pomocník").font(.title3.bold())
                    Text("Verzia \(appVersion) (build \(appBuild))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }

            card {
                externalLinkRow("GitHub",
                    url: URL(string: "https://github.com")!)
            }

            // Only with Developer mode on — normal use doesn't need it, and it's the switch
            // to tell someone to flip when their problem needs looking into.
            if developerMode {
            card {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Diagnostika").font(.body.bold())
                        Text("Keď niečo nefunguje: nechaj zapnutý záznam, zopakuj problém a klikni na „Pripraviť na poslanie“. Vznikne súbor, ktorý sa dá priložiť k správe.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 2)

                    toggleRow(title: "Zapisovať diagnostický záznam",
                              subtitle: loggingEnabled
                                ? "Zapnuté — veľkosť súboru: \(logSizeText)"
                                : "Vypnuté — nové udalosti sa nezaznamenávajú",
                              isOn: Binding(
                        get: { loggingEnabled },
                        set: { loggingEnabled = $0; AppLogger.isEnabled = $0; refreshLogSize() }
                    ))
                    rowDivider

                    HStack(spacing: 8) {
                        Text("Súbor záznamu").font(.body)
                        Spacer()
                        Button("Pripraviť na poslanie") { exportLogToDesktop() }
                            .buttonStyle(.borderedProminent).tint(accent)
                            .help("Uloží kópiu na plochu a označí ju vo Finderi")
                        Button("Zobraziť") { LogViewerWindowController.shared.show() }
                            .buttonStyle(.bordered)
                        Button("Vymazať") { AppLogger.clear(); refreshLogSize(); exportedLogName = nil }
                            .buttonStyle(.bordered).foregroundStyle(.red)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)

                    if let name = exportedLogName {
                        rowDivider
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(greenDot)
                            Text("Uložené na plochu: \(name)").font(.caption)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                }
            }
            }

            card {
                toggleRow(title: "Spustiť pri prihlásení", isOn: Binding(
                    get: { LaunchAtLogin.isEnabled },
                    set: { LaunchAtLogin.isEnabled = $0 }
                ))
                rowDivider
                HStack {
                    Text("Povolenia").font(.body)
                    Spacer()
                    Button("Skontrolovať…") { showOnboarding = true }
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }

            card {
                toggleRow(title: "Developer mode",
                          subtitle: "Vývojárske nástroje: reštart aplikácie z menu bar ikonky (podržaním ⌥) a funkcie vo vývoji. Na poslanie záznamu ho zapínať netreba.",
                          isOn: Binding(
                    get: { developerMode },
                    set: { developerMode = $0; DeveloperMode.isEnabled = $0 }
                ))
            }

            card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Prístupový kód").font(.body.bold())
                    Text("Ak ti niekto poslal prístupový kód, vlož ho sem — odomkne funkcie, ktoré ti povolil.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("napr. jano-x7k2", text: $accessCodeInput)
                            .textFieldStyle(.roundedBorder)
                        Button(accessCodeSaved ? "Uložené ✓" : "Uložiť") {
                            remoteConfig.accessCode = accessCodeInput
                            accessCodeSaved = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: - Diagnostics helpers

    private var logSizeText: String {
        logSizeBytes < 1024 ? "\(logSizeBytes) B"
            : ByteCountFormatter.string(fromByteCount: Int64(logSizeBytes), countStyle: .file)
    }

    private func refreshLogSize() { logSizeBytes = AppLogger.fileSizeBytes }

    private static func modelNote(_ model: String) -> String {
        switch model {
        case "gpt-transcribe":         return " (odporúčaný, najpresnejší)"
        case "gpt-4o-mini-transcribe": return " (staršia generácia)"
        default:                       return ""
        }
    }

    /// Desktop + reveal in Finder rather than a save panel: for the target audience a
    /// predictable, one-click destination beats navigating a file dialog.
    private func exportLogToDesktop() {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first,
              let url = AppLogger.exportCopy(to: desktop) else {
            exportedLogName = nil
            return
        }
        exportedLogName = url.lastPathComponent
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @ViewBuilder
    private func externalLinkRow(_ label: String, url: URL) -> some View {
        Link(destination: url) {
            HStack {
                Text(label).font(.body).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12))
                    .foregroundStyle(accent)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointingHandCursor()
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    // MARK: - Helpers

    private func rateString(_ r: Float) -> String { String(format: "×%.1f", r * 2) }

    private func addProfileFromFrontmostApp() {
        let app = NSWorkspace.shared.frontmostApplication
        profileStore.profiles.append(AppProfile(
            displayName: app?.localizedName ?? "Nová appka",
            bundleID: app?.bundleIdentifier ?? "",
            titleKeyword: "",
            instructions: ""
        ))
    }

    private func addProfileFromFilePicker() {
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

    private func loadGoogleVoices() async {
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
    private static let key = "app.developerMode"
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
