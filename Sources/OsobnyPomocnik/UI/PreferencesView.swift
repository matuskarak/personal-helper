import SwiftUI
import AVFoundation
import AppKit
import ServiceManagement
import Charts

struct PreferencesView: View {

    enum Tab: CaseIterable, Hashable {
        case dictation, reading, microphone, usage, shortcuts, about
        var label: String {
            switch self {
            case .dictation:  "Diktovanie"
            case .reading:    "Čítanie"
            case .microphone: "Mikrofón"
            case .usage:      "Prehľad"
            case .shortcuts:  "Skratky"
            case .about:      "O aplikácii"
            }
        }
        var icon: String {
            switch self {
            case .dictation:  "mic"
            case .reading:    "chart.bar"
            case .microphone: "record.circle"
            case .usage:      "clock.arrow.circlepath"
            case .shortcuts:  "keyboard"
            case .about:      "info.circle"
            }
        }
    }

    enum UsagePeriod: CaseIterable, Hashable {
        case today, week, month
        var label: String {
            switch self {
            case .today: "Dnes"
            case .week:  "Tento týždeň"
            case .month: "Tento mesiac"
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

    @State private var selectedTab: Tab = .dictation
    @State private var tts          = TTSEngine.shared
    @State private var google       = GoogleCloudTTSEngine.shared
    @State private var dictation    = DictationEngine.shared
    @State private var profileStore = AppProfileStore.shared
    @State private var rewriteEngine = SmartRewriteEngine.shared
    @State private var remoteConfig  = RemoteConfig.shared
    @State private var usageStore    = UsageStore.shared
    @State private var showOnboarding = false
    @State private var developerMode = DeveloperMode.isEnabled
    @State private var accessCodeInput = ""
    @State private var accessCodeSaved = false
    @State private var pillFollowsField = PillPosition.followFocusedField
    @State private var usagePeriod: UsagePeriod = .today
    @State private var chartMetric: ChartMetric = .timeSaved
    @State private var chartDays = 7

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
                        case .dictation:  dictationTab
                        case .reading:    readingTab
                        case .microphone: microphoneTab
                        case .usage:      usageTab
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
            ForEach(Tab.allCases, id: \.self) { tab in
                Button { selectedTab = tab } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 13.5))
                            .foregroundStyle(selectedTab == tab ? accent : Color.secondary)
                            .frame(width: 18)
                        Text(tab.label)
                            .font(.system(size: 13.5))
                            .foregroundStyle(selectedTab == tab ? accent : Color.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(selectedTab == tab ? accent.opacity(0.12) : .clear)
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 20)
        .frame(width: 190)
    }

    // MARK: - Shared components

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ body: () -> Content) -> some View {
        VStack(spacing: 0) { body() }
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }

    private func warningBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(warnFG).frame(width: 6, height: 6)
            Text(message)
                .font(.callout)
                .foregroundStyle(warnFG)
            Spacer()
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

    // MARK: - Diktovanie

    private var dictationTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Diktovanie").font(.title2.bold())

            // Toggles
            card {
                if remoteConfig.smartDictationAllowed {
                    toggleRow(title: "Smart diktovanie",
                              subtitle: "Pred vložením text prepíše AI s kontextom obrazovky",
                              isOn: $dictation.smartAlwaysOn)
                    rowDivider
                }
                toggleRow(title: "Live vkladanie",
                          subtitle: "Píše text do poľa priebežne počas diktovania",
                          isOn: $dictation.liveInsertEnabled)
                if dictation.smartAlwaysOn && dictation.liveInsertEnabled {
                    warningBanner("Tieto dve funkcie nie sú kompatibilné")
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
                if dictation.liveInsertEnabled {
                    rowDivider
                    toggleRow(title: "Enter zastaví diktovanie",
                              subtitle: "Stlačenie Enter automaticky ukončí nahrávanie",
                              isOn: $dictation.enterAutoStop)
                }
            }

            // Režim + VAD
            card {
                pickerRow(title: "Režim", selection: $dictation.transcriptionMode) {
                    Text("Realtime (živý náhľad)").tag(DictationEngine.TranscriptionMode.realtime)
                    Text("Po nahraní (presnejší, lacnejší)").tag(DictationEngine.TranscriptionMode.batch)
                }
                if dictation.transcriptionMode == .batch {
                    rowDivider
                    pickerRow(title: "Model", selection: $dictation.batchModel) {
                        Text("gpt-4o-mini-transcribe (odporúčaný)").tag("gpt-4o-mini-transcribe")
                        Text("gpt-4o-transcribe (najpresnejší)").tag("gpt-4o-transcribe")
                        Text("whisper-1").tag("whisper-1")
                    }
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
                card {
                    pickerRow(title: "Model Smart prepisu", selection: $smartModelInput) {
                        Text("gpt-4o-mini (rýchly, odporúčaný)").tag("gpt-4o-mini")
                        Text("gpt-4o (presnejší)").tag("gpt-4o")
                        Text("gpt-4.1-mini").tag("gpt-4.1-mini")
                        Text("gpt-4.1").tag("gpt-4.1")
                    }
                    .onChange(of: smartModelInput) { _, v in rewriteEngine.model = v }
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
                                        TextField("Instrukcie pre prepis", text: $profile.instructions,
                                                  axis: .vertical)
                                            .lineLimit(2...4)
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
                Text(String(format: "Využité tento mesiac: %.1f min (~$%.3f)", dictMins, dictCost))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Resetovať") { dictation.resetUsageCounter() }
                    .font(.caption).foregroundStyle(.red).buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
        }
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
                    Text(String(format: "Znaky tento mesiac: %d (~$%.3f)",
                                google.totalCharactersUsed, chars * rate))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Resetovať") { google.resetCharacterCount() }
                        .font(.caption).foregroundStyle(.red).buttonStyle(.plain)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Mikrofón

    private var microphoneTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mikrofón").font(.title2.bold())

            let selectedUID   = dictation.selectedInputDeviceUID
            let availableUIDs = Set(inputDevices.map { $0.uid })
            let selectedMissing = selectedUID != nil && !availableUIDs.contains(selectedUID!)

            if selectedMissing, let uid = selectedUID {
                let name = savedDeviceName(uid)
                warningBanner(
                    "\(name) nie je pripojený. Pripoj zariadenie alebo vyber iný mikrofón."
                )
            }

            card {
                micRow(name: "Systémový (predvolený)", icon: "waveform",
                       connected: true, selected: selectedUID == nil) {
                    dictation.selectedInputDeviceUID = nil
                }
                ForEach(inputDevices) { device in
                    Divider().padding(.leading, 50)
                    micRow(name: device.name, icon: deviceIcon(device.name),
                           connected: true, selected: selectedUID == device.uid) {
                        dictation.selectedInputDeviceUID = device.uid
                    }
                }
                if selectedMissing, let uid = selectedUID {
                    Divider().padding(.leading, 50)
                    micRow(name: savedDeviceName(uid), icon: "mic.circle",
                           connected: false, selected: true) { }
                }
            }

            Button("Obnoviť zoznam") { inputDevices = AudioDeviceManager.inputDevices() }
                .buttonStyle(.bordered).font(.caption)
        }
    }

    private func micRow(name: String, icon: String, connected: Bool,
                        selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: selected ? "record.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? accent : Color.secondary)
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 18)
                Text(name)
                    .font(selected ? .body.bold() : .body)
                    .foregroundStyle(.primary)
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(connected ? greenDot : Color.secondary.opacity(0.45))
                        .frame(width: 6, height: 6)
                    Text(connected ? "Pripojené" : "Nedostupné")
                        .font(.caption)
                        .foregroundStyle(connected ? greenDot : Color.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .background(selected ? accent.opacity(0.07) : .clear)
        }
        .buttonStyle(.plain)
    }

    private func deviceIcon(_ name: String) -> String {
        let l = name.lowercased()
        if l.contains("airpod")                          { return "airpodspro" }
        if l.contains("macbook") || l.contains("built")  { return "laptopcomputer" }
        return "mic.circle"
    }

    private func savedDeviceName(_ uid: String) -> String {
        let parts = uid.split(separator: ":").map(String.init)
        return parts.count >= 3 ? parts[2] : uid
    }

    // MARK: - Prehľad (usage)

    private var usageTab: some View {
        let summary: UsageStore.Summary = {
            switch usagePeriod {
            case .today: usageStore.today
            case .week:  usageStore.thisWeek
            case .month: usageStore.thisMonth
            }
        }()

        return VStack(alignment: .leading, spacing: 16) {
            Text("Prehľad využitia").font(.title2.bold())

            Picker("", selection: $usagePeriod) {
                ForEach(UsagePeriod.allCases, id: \.self) { p in
                    Text(p.label).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 340)

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

            usageChart
        }
    }

    private var usageChart: some View {
        let buckets = usageStore.dictationDailyByModel(days: chartDays)
        return card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Vývoj diktovania").font(.headline)
                    Spacer()
                    Picker("", selection: $chartMetric) {
                        ForEach(ChartMetric.allCases, id: \.self) { m in Text(m.label).tag(m) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 230)
                    Picker("", selection: $chartDays) {
                        Text("7 dní").tag(7)
                        Text("30 dní").tag(30)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 140)
                }

                if buckets.isEmpty {
                    Text("Zatiaľ žiadne dáta za toto obdobie.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
                } else {
                    Chart(buckets) { b in
                        BarMark(
                            x: .value("Deň", b.day, unit: .day),
                            y: .value(chartMetric.label, chartValue(b))
                        )
                        .foregroundStyle(by: .value("Model", modelLabel(b.model)))
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
        case "gpt-realtime-whisper":    "Realtime"
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
        String(format: "~$%.3f", Double(seconds) / 60 * dictation.costPerMinute)
    }

    private func readingCostString(_ chars: Int) -> String {
        let voice = google.selectedVoiceName
        let rate: Double = voice.contains("Chirp3-HD") || voice.contains("Chirp-HD") ? 0.00016
                          : (voice.contains("WaveNet") || voice.contains("Neural2"))  ? 0.000016
                          : 0.000004
        return String(format: "~$%.3f", Double(chars) * rate)
    }

    /// ponytail: closed-form estimate, no real playback-duration tracking —
    /// dictation compares actual seconds to a 40wpm typing baseline; reading
    /// compares a 120wpm manual-reading baseline to a 180wpm TTS-listening baseline.
    private func timeSavedString(_ s: UsageStore.Summary) -> String {
        let dictationSavedMin = max(0, Double(s.dictationWords) / 40.0 - Double(s.dictationSeconds) / 60.0)
        let readingSavedMin   = Double(s.readingWords) / 360.0
        let totalMin = dictationSavedMin + readingSavedMin
        if totalMin < 1 { return String(format: "%.0f s", totalMin * 60) }
        if totalMin < 60 { return String(format: "%.0f min", totalMin) }
        return String(format: "%.1f h", totalMin / 60)
    }

    // MARK: - Skratky

    private var shortcutsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Klávesové skratky").font(.title2.bold())

            card {
                shortcutRow("Diktovanie", Binding(
                    get: { ShortcutStore.shared.dictate },
                    set: { ShortcutStore.shared.dictate = $0 }
                ))
                if remoteConfig.smartDictationAllowed {
                    rowDivider
                    shortcutRow("Smart diktovanie", Binding(
                        get: { ShortcutStore.shared.smartDictate },
                        set: { ShortcutStore.shared.smartDictate = $0 }
                    ))
                }
                rowDivider
                shortcutRow("Čítať text", Binding(
                    get: { ShortcutStore.shared.readText },
                    set: { ShortcutStore.shared.readText = $0 }
                ))
                rowDivider
                shortcutRow("OCR oblasť", Binding(
                    get: { ShortcutStore.shared.ocr },
                    set: { ShortcutStore.shared.ocr = $0 }
                ))
                rowDivider
                shortcutRow("Vložiť z pamäte", Binding(
                    get: { ShortcutStore.shared.insertFromMemory },
                    set: { ShortcutStore.shared.insertFromMemory = $0 }
                ))
            }

            Text("Klikni na skratku a stlač novú kombináciu (vyžaduje aspoň jeden modifier).")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
    }

    private func shortcutRow(_ label: String, _ binding: Binding<Shortcut>) -> some View {
        HStack {
            Text(label).font(.body)
            Spacer()
            ShortcutRecorderView(shortcut: binding)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
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
                rowDivider
                externalLinkRow("Nahlásiť chybu",
                    url: URL(string: "https://github.com/issues")!)
            }

            card {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Súbor záznamu").font(.body.bold())
                        Text("~/Library/Logs/OsobnyPomocnik/app.log")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if developerMode {
                        Button("Zobraziť log") { LogViewerWindowController.shared.show() }
                            .buttonStyle(.bordered)
                    }
                    Button("Otvoriť vo Finderi") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppLogger.logFileURL])
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 16).padding(.vertical, 13)
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
                          subtitle: "Zobrazí vývojárske nástroje (log viewer, reštart z menu bar ikonky podržaním ⌥)",
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
        .buttonStyle(.plain)
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

// MARK: - Shortcut row (unchanged)

private struct ShortcutRow: View {
    let label: String
    @Binding var shortcut: Shortcut
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            ShortcutRecorderView(shortcut: $shortcut)
        }
    }
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
