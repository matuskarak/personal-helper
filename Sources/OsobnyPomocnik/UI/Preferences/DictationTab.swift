import SwiftUI
import AVFoundation
import AppKit
import ServiceManagement
import Charts

extension PreferencesView {
    // MARK: - Diktovanie

    var dictationTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Diktovanie").font(.title2.bold())

            // How the shortcut scheme works — the mode/processing split lives in the
            // shortcuts now, so the settings only pick MODELS per mode, not the mode itself.
            Text("Režim prepisu voliš skratkou, ktorou diktovanie SPUSTÍŠ (\(scLabel(.dictateRealtime)) = realtime, \(scLabel(.dictateBatch)) = po nahraní). Skratka, ktorou diktovanie UKONČÍŠ, rozhoduje o spracovaní: tá istá ako pri štarte = vloží sa čistý prepis; \(scLabel(.smartStop)) = text pred vložením upraví AI s kontextom obrazovky (Smart). Iné diktovacie skratky sa počas nahrávania ignorujú. Ak sa pri diktovaní pomýliš, \(scLabel(.cancelDictation)) ho zruší — nahrávka sa zahodí, nič sa neprepíše ani nevloží.")
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
                    // Remote catalog drives the offer; a selected-but-retired model stays in
                    // the list so the Picker binding never dangles.
                    let infos = remoteConfig.catalog.batchModels.filter { $0.available || $0.id == dictation.batchModel }
                    ForEach(infos) { info in
                        Text("\(info.displayName) — \(Pricing.perMinuteLabel(realtime: false, batchModel: info.id))")
                            .tag(info.id)
                    }
                    if !infos.contains(where: { $0.id == dictation.batchModel }) {
                        Text(dictation.batchModel).tag(dictation.batchModel)
                    }
                }
                // Kľúče žijú vo Všeobecné — tu len upozorni, keď pre zvolený model chýba.
                if DictationEngine.isGemini(dictation.batchModel) ? !dictation.hasGeminiKey : !dictation.hasOpenAIKey {
                    rowDivider
                    Text("⚠️ Chýba \(DictationEngine.isGemini(dictation.batchModel) ? "Gemini" : "OpenAI") API kľúč — nastavíš ho v záložke Všeobecné.")
                        .font(.caption).foregroundStyle(.orange)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                }
                rowDivider
                toggleRow(title: "Porovnávať s druhým modelom (tieňový prepis)",
                          subtitle: dictation.canShadowCompare
                            ? "Každú nahrávku prepíše aj \(dictation.shadowModelName) a výsledok uloží k diktovaniu. Vkladá sa vždy len text zvoleného modelu — druhý slúži na porovnanie v záložke Kvalita. Kým je zapnuté, platíš oba prepisy."
                            : "Vyžaduje nastavený OpenAI aj Gemini kľúč — porovnanie beží medzi dvoma poskytovateľmi.",
                          isOn: $dictation.shadowCompareEnabled)
                    .disabled(!dictation.canShadowCompare)
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
                toggleRow(title: "Vysvetlivky v pilulke",
                          subtitle: "Doplňujúce popisky (napr. prepis až po zastavení, Klikni na zatvorenie). Vypni, keď už skratky poznáš — pilulka bude menšia.",
                          isOn: Binding(
                    get: { dictation.pillHintsEnabled },
                    set: { dictation.pillHintsEnabled = $0 }
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

            // Usage — a real calendar month from the daily buckets, not the old lifetime
            // counter that only pretended to be monthly until someone hit Reset.
            let monthStart = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
            let dictMins = Double(usageStore.summary(from: monthStart, to: Date()).dictationSeconds) / 60
            let dictCost = dictMins * dictation.costPerMinute
            Text(String(format: "Využité tento mesiac: %.1f min (~%@)", dictMins, currency.format(usd: dictCost)))
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    /// First shortcut mapped to the action, for inline mentions in explanations.
    func scLabel(_ action: ShortcutStore.Action) -> String {
        ShortcutStore.shared.shortcuts(for: action).first?.displayString ?? "?"
    }

    var vadSubtitle: String {
        switch dictation.transcriptionDelay {
        case "low":    return "Rýchla reakcia"
        case "medium": return "Vyvážená reakcia"
        default:       return "Pomalá reakcia"
        }
    }
}
