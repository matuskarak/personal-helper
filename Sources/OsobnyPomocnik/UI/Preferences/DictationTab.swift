import SwiftUI
import AVFoundation
import AppKit
import ServiceManagement
import Charts

extension PreferencesView {
    // MARK: - Diktovanie
    //
    // One collapsible section per mode; a setting appears only inside the mode it belongs to
    // (VAD / live-insert → realtime, shadow compare → batch, screenshot + profiles → Smart).
    // Every caption is one sentence, visible under its control — never a tooltip.

    var dictationTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Diktovanie").font(Theme.title(22))

            VStack(alignment: .leading, spacing: 4) {
                if remoteConfig.realtimeAllowed {
                    Text("Spúšťacia skratka volí režim, ukončovacia spracovanie.")
                        .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                    if dictationIntroExpanded {
                        Text("\(scLabel(.dictateRealtime)) spustí realtime, \(scLabel(.dictateBatch)) diktovanie po nahraní. Tá istá skratka = čistý prepis, \(scLabel(.smartStop)) = Smart úprava podľa obrazovky. \(scLabel(.cancelDictation)) zruší bez vloženia.")
                            .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    Text("Diktovanie spustíš aj zastavíš skratkou \(scLabel(.dictateBatch)).")
                        .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                    if dictationIntroExpanded {
                        Text("Po zastavení sa prepis vloží tam, kde máš kurzor. \(scLabel(.cancelDictation)) zruší bez vloženia.")
                            .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                    }
                }
                Button(dictationIntroExpanded ? "Menej" : "Viac") { dictationIntroExpanded.toggle() }
                    .font(Theme.body(11)).buttonStyle(.plain).pointingHandCursor().foregroundStyle(accent)
            }
            .padding(.horizontal, 4)

            if remoteConfig.realtimeAllowed { realtimeSection }
            batchSection
            if remoteConfig.smartDictationAllowed { smartSection }
            keywordsSection
            pillSection
            duckSection

            let monthStart = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
            let dictMins = Double(usageStore.summary(from: monthStart, to: Date()).dictationSeconds) / 60
            let dictCost = dictMins * dictation.costPerMinute
            Text(String(format: "Tento mesiac: %.1f min · ~%@", dictMins, currency.format(usd: dictCost)))
                .font(Theme.body(11).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 4)
        }
        // One sheet for the whole tab — the global field's button and each profile's button
        // open the same popover (it groups suggestions by profile). .sheet, not .popover:
        // a popover squashed 20-30 suggestions into a sliver a few points tall.
        .sheet(isPresented: $showKeywordSuggestions) {
            KeywordSuggestionPopover(isPresented: $showKeywordSuggestions)
        }
    }

    // MARK: Realtime

    var realtimeSection: some View {
        sectionCard("Realtime diktovanie", shortcut: scLabel(.dictateRealtime),
                    status: realtimeSectionExpanded ? nil : dictation.realtimeModel.rawValue,
                    isExpanded: $realtimeSectionExpanded) {
            pickerRow(title: "Model", subtitle: realtimeModelCaption, selection: $dictation.realtimeModel) {
                ForEach(DictationEngine.RealtimeModel.allCases, id: \.self) { model in
                    Text(model.rawValue).tag(model)
                }
            }
            rowDivider
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Citlivosť VAD").font(Theme.body(13))
                    Text("Ako dlho model čaká, kým usúdi, že si dohovoril.")
                        .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Picker("", selection: $dictation.transcriptionDelay) {
                    Text("Krátko").tag("low")
                    Text("Stredne").tag("medium")
                    Text("Dlho").tag("high")
                }
                .pickerStyle(.segmented).frame(width: 210).labelsHidden()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            rowDivider
            toggleRow(title: "Live vkladanie",
                      subtitle: "Text sa píše priebežne. Smart ukončenie (\(scLabel(.smartStop))) sa vtedy nedá použiť.",
                      isOn: $dictation.liveInsertEnabled)
            if dictation.liveInsertEnabled {
                rowDivider
                toggleRow(title: "Enter zastaví diktovanie", isOn: $dictation.enterAutoStop)
                    .nestedRow()
            }
        }
    }

    var realtimeModelCaption: String {
        let price = Pricing.perMinuteLabel(realtime: true)
        switch dictation.realtimeModel {
        case .live:   return "Využíva kľúčové slová aj kontext appky. \(price)"
        case .legacy: return "Pôvodný model, bez kľúčových slov. \(price)"
        }
    }

    // MARK: Po nahraní

    var batchSection: some View {
        let title = remoteConfig.realtimeAllowed ? "Diktovanie po nahraní" : "Diktovanie"
        return sectionCard(title, shortcut: scLabel(.dictateBatch),
                           status: batchSectionExpanded ? nil : dictation.batchModel,
                           isExpanded: $batchSectionExpanded) {
            // Remote catalog drives the offer; a selected-but-retired model stays in the list
            // so the Picker binding never dangles.
            let infos = remoteConfig.catalog.batchModels.filter {
                $0.available || remoteConfig.allModelsAllowed || $0.id == dictation.batchModel
            }
            pickerRow(title: "Model", subtitle: batchModelCaption(infos), selection: $dictation.batchModel) {
                ForEach(infos) { Text($0.id).tag($0.id) }
                if !infos.contains(where: { $0.id == dictation.batchModel }) {
                    Text(dictation.batchModel).tag(dictation.batchModel)
                }
            }
            if DictationEngine.isGemini(dictation.batchModel) ? !dictation.hasGeminiKey : !dictation.hasOpenAIKey {
                rowDivider
                captionRow("Chýba \(DictationEngine.isGemini(dictation.batchModel) ? "Gemini" : "OpenAI") API kľúč — nastavíš ho vo Všeobecné.",
                           color: Theme.warning)
            }
            // Tieňový prepis je len pre Developer mode (druhý model naviac dvojnásobí cenu) —
            // prepínač je v O aplikácii, nie tu, viď AboutTab.
        }
    }

    /// "Rýchly, odporúčaný. 0,006 € / min." — the note comes from the catalog's displayName
    /// ("gpt-transcribe (rýchly, odporúčaný)"), the id itself is already in the picker.
    func batchModelCaption(_ infos: [ModelInfo]) -> String {
        let price = Pricing.perMinuteLabel(realtime: false, batchModel: dictation.batchModel)
        guard let info = infos.first(where: { $0.id == dictation.batchModel }) else { return price }
        let note = info.displayName.replacingOccurrences(of: info.id, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
        return note.isEmpty ? price : "\(note.prefix(1).uppercased())\(note.dropFirst()). \(price)"
    }

    // MARK: Smart

    var smartSection: some View {
        sectionCard("Smart ukončenie", shortcut: scLabel(.smartStop),
                    status: profilesStatus, isExpanded: $smartSectionExpanded) {
            captionRow("Ukončí bežiace diktovanie a AI pred vložením upraví prepis podľa kontextu — appky, v ktorej píšeš, obsahu okna a tvojich profilov.")
            if !CGPreflightScreenCaptureAccess() {
                warningBanner(
                    "Bez povolenia Nahrávanie obrazovky Smart nevidí obsah okna — opraví prepis len podľa appky a profilu.",
                    action: ("Otvoriť nastavenia", { PermissionsChecker.shared.openScreenRecordingSettings() })
                )
                .padding(.horizontal, 16).padding(.bottom, 10)
            }
            rowDivider
            pickerRow(title: "Model", selection: $smartModelInput) {
                Text("gpt-4o-mini (rýchly, odporúčaný)").tag("gpt-4o-mini")
                Text("gpt-4o (presnejší)").tag("gpt-4o")
                Text("gpt-4.1-mini").tag("gpt-4.1-mini")
                Text("gpt-4.1").tag("gpt-4.1")
            }
            .onChange(of: smartModelInput) { _, v in rewriteEngine.model = v }
            rowDivider
            toggleRow(title: "Kontext zo screenshotu",
                      subtitle: "Model vidí obrazovku a podľa nej opraví prepis.",
                      isOn: $rewriteEngine.visionPromptEnabled)
            if rewriteEngine.visionPromptEnabled {
                rowDivider
                VStack(alignment: .leading, spacing: 6) {
                    Text("Prompt").font(Theme.body(13))
                    TextEditor(text: $rewriteEngine.visionPromptOverride)
                        .font(Theme.body(13))
                        .frame(height: visionPromptExpanded ? 200 : 54)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    HStack {
                        Button(visionPromptExpanded ? "Zobraziť menej" : "Zobraziť viac") { visionPromptExpanded.toggle() }
                            .buttonStyle(.plain).pointingHandCursor().font(Theme.body(11)).foregroundStyle(accent)
                        Spacer()
                        Text("Vymazaním sa vráti predvolený.").font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .nestedRow()
            }
            rowDivider
            toggleRow(title: "Ukladať screenshoty do histórie",
                      subtitle: "Na ladenie. Môže obsahovať citlivý obsah obrazovky.",
                      isOn: $rewriteEngine.saveScreenshotsToHistory)
            rowDivider
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Profily podľa aplikácie").font(Theme.body(13))
                    Text("Vlastné inštrukcie a kľúčové slová pre konkrétnu appku.")
                        .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Menu("Pridať profil") {
                    Button("Aktuálna appka") { addProfileFromFrontmostApp() }
                    Button("Vybrať appku…") { addProfileFromFilePicker() }
                    Button("Prázdny profil") { profileStore.addBlank() }
                }
                .buttonStyle(.bordered).font(Theme.body(11)).fixedSize()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            ForEach($profileStore.profiles) { $profile in
                rowDivider
                profileRow($profile).nestedRow()
            }
        }
    }

    var profilesStatus: String? {
        switch profileStore.profiles.count {
        case 0:     return nil
        case 1:     return "1 profil"
        case 2...4: return "\(profileStore.profiles.count) profily"
        default:    return "\(profileStore.profiles.count) profilov"
        }
    }

    func profileRow(_ profile: Binding<AppProfile>) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Názov", text: profile.displayName)
                TextField("Bundle ID (napr. com.tinyspeck.slackmacgap)", text: profile.bundleID)
                TextField("Kľúčové slovo v titulku (voliteľné)", text: profile.titleKeyword)
                HStack {
                    Text("Typ cieľa").font(Theme.body(12))
                    Picker("", selection: profile.category) {
                        ForEach(AppCategory.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                }
                Text("Rubrika v Kvalite a kontext pre model.")
                    .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                Text("Inštrukcie").font(Theme.body(12))
                MultilineField(text: profile.instructions, collapsedLines: 4, accent: accent)
                Text("Kľúčové slová").font(Theme.body(12))
                Text("Navyše k predvoleným, len pre túto appku. Jedno na riadok.")
                    .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                MultilineField(text: profile.keywords, accent: accent) { keywordSuggestButton() }
                HStack {
                    Spacer()
                    Button("Odstrániť", role: .destructive) { profileStore.remove(profile.wrappedValue) }
                        .font(Theme.body(11))
                }
            }
            .padding(.vertical, 8)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.wrappedValue.displayName.isEmpty ? "Bez názvu" : profile.wrappedValue.displayName)
                if !profile.wrappedValue.bundleID.isEmpty {
                    Text(profile.wrappedValue.bundleID).font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: Kľúčové slová (both modes forward them as `prompt`)

    var keywordsSection: some View {
        sectionCard("Kľúčové slová", status: remoteConfig.realtimeAllowed ? "oba režimy" : nil, isExpanded: $keywordsSectionExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Mená, klienti, termíny — jedno na riadok. Pomáhajú hlavne pri anglických slovách.")
                    .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                MultilineField(text: $dictation.defaultKeywords, accent: accent) { keywordSuggestButton() }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    // MARK: Pilulka

    var pillSection: some View {
        sectionCard("Pilulka", isExpanded: $pillSectionExpanded) {
            toggleRow(title: "Zobraziť nad aktívnym poľom", subtitle: "Inak v strede obrazovky.",
                      isOn: Binding(get: { pillFollowsField },
                                    set: { pillFollowsField = $0; PillPosition.followFocusedField = $0 }))
            rowDivider
            toggleRow(title: "Vysvetlivky v pilulke", subtitle: "Vypni, keď skratky poznáš — pilulka bude menšia.",
                      isOn: Binding(get: { dictation.pillHintsEnabled }, set: { dictation.pillHintsEnabled = $0 }))
            rowDivider
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pozícia").font(Theme.body(13))
                    Text("Presunieš ťahaním myšou.").font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Resetovať") { PillPosition.reset() }.buttonStyle(.bordered)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    // MARK: Ostatné zvuky

    var duckSection: some View {
        let status: String = !duckAudio.enabled ? "vypnuté"
            : duckAudio.mode == .duck ? "stíšiť na \(Int(duckAudio.duckLevel * 100)) %" : "pozastaviť"
        return sectionCard("Ostatné zvuky", status: status, isExpanded: $duckSectionExpanded) {
            toggleRow(title: "Stíšiť počas diktovania",
                      subtitle: "Hudba a videá sa po skončení vrátia do pôvodného stavu.",
                      isOn: $duckAudio.enabled)
                .accessibilityHint("Zapne alebo vypne stíšenie ostatného zvuku počas diktovania")
            if duckAudio.enabled {
                rowDivider
                HStack {
                    Text("Spôsob").font(Theme.body(13))
                    Spacer()
                    Picker("", selection: $duckAudio.mode) {
                        Text("Stíšiť").tag(AudioDucking.Mode.duck)
                        Text("Pozastaviť").tag(AudioDucking.Mode.pause)
                    }
                    .pickerStyle(.segmented).frame(width: 200).labelsHidden()
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .nestedRow()
                rowDivider
                if duckAudio.mode == .duck {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Hlasitosť").font(Theme.body(13))
                            Spacer()
                            Text("\(Int(duckAudio.duckLevel * 100)) %")
                                .font(Theme.body(12).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                        }
                        Slider(value: $duckAudio.duckLevel, in: 0...1)
                            .accessibilityLabel("Hlasitosť počas diktovania")
                            .accessibilityValue("\(Int(duckAudio.duckLevel * 100)) percent")
                        Text("0 % = úplné stlmenie.").font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .nestedRow()
                } else {
                    captionRow("Funguje pre appky, ktoré reagujú na klávesu Prehrať/Pozastaviť (Hudba, Spotify, YouTube).")
                        .nestedRow()
                }
            }
        }
    }

    /// Floats in the corner of a keywords field (global or a profile's). Both open the same
    /// analysis; it groups suggestions by profile.
    func keywordSuggestButton() -> some View {
        Button {
            showKeywordSuggestions = true
        } label: {
            Label("Navrhnúť z histórie", systemImage: "sparkles").font(Theme.body(11))
        }
        .buttonStyle(.borderedProminent).controlSize(.small).tint(accent)
        .disabled(!dictation.hasOpenAIKey)
        .help(dictation.hasOpenAIKey
              ? "Zanalyzuje históriu diktovaní za posledných 30 dní (OpenAI, gpt-4o-mini) a navrhne nové kľúčové slová na schválenie."
              : "Chýba OpenAI API kľúč (Nastavenia → Všeobecné).")
        .accessibilityHint("Zanalyzuje históriu diktovaní a navrhne nové kľúčové slová na schválenie")
    }

    /// First shortcut mapped to the action, for inline mentions in explanations.
    func scLabel(_ action: ShortcutStore.Action) -> String {
        ShortcutStore.shared.shortcuts(for: action).first?.displayString ?? "?"
    }
}
