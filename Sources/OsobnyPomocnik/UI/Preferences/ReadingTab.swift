import SwiftUI
import AVFoundation
import AppKit
import ServiceManagement
import Charts

extension PreferencesView {
    // MARK: - Čítanie

    var readingTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Čítanie").font(Theme.title(22))

            sectionCard("Hlas", status: tts.mode.displayName, isExpanded: $voiceSectionExpanded) {
                pickerRow(title: "Engine",
                          subtitle: tts.mode == .googleCloud ? "Kvalitnejší hlas, platí sa za znaky." : "Systémový hlas, zadarmo.",
                          selection: $tts.mode) {
                    ForEach(TTSMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                if tts.mode == .googleCloud {
                    if !google.hasAPIKey {
                        rowDivider
                        captionRow("Chýba Google Cloud API kľúč — nastavíš ho vo Všeobecné.", color: Theme.warning)
                    }
                    rowDivider
                    if !availableGoogleVoices.isEmpty {
                        pickerRow(title: "Hlas", selection: $google.selectedVoiceName) {
                            ForEach(availableGoogleVoices) { Text($0.displayName).tag($0.name) }
                        }
                    } else {
                        HStack {
                            Text("Hlas").font(Theme.body(13))
                            Spacer()
                            if loadingVoices {
                                ProgressView().controlSize(.small)
                                Text("Načítavam…").foregroundStyle(Theme.textSecondary).font(Theme.body(11))
                            } else {
                                Button("Načítať hlasy") { Task { await loadGoogleVoices() } }
                                    .buttonStyle(.bordered).disabled(!google.hasAPIKey)
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 11)
                    }
                } else {
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
                }
                rowDivider
                // One test row for both engines.
                HStack {
                    TextField("Testovací text…", text: $testText).textFieldStyle(.roundedBorder)
                    Button("Prehrať") {
                        TTSEngine.shared.stop()
                        TTSEngine.shared.speak(testText, trackUsage: false)
                    }
                    .buttonStyle(.borderedProminent).tint(accent)
                    .disabled(testText.isEmpty || (tts.mode == .googleCloud && !google.hasAPIKey))
                    if tts.isSpeaking {
                        Button("Stop") { TTSEngine.shared.stop() }
                            .buttonStyle(.bordered).foregroundStyle(Theme.error)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .nestedRow()
            }

            sectionCard("Jazyk a rýchlosť", isExpanded: $readingSectionExpanded) {
                pickerRow(title: "Jazyk čítania", selection: $tts.languageMode) {
                    Text("Automaticky").tag("auto")
                    Text("Slovenčina").tag("sk-SK")
                    Text("English").tag("en-US")
                }
                rowDivider
                VStack(alignment: .leading, spacing: 8) {
                    Text("Rýchlosť").font(Theme.body(13))
                    Text("Tlačidlo v pilulke prepína v tomto poradí. 1× sa nedá vypnúť.")
                        .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(TTSEngine.allSpeeds, id: \.self) { s in
                            Toggle(TTSEngine.format(s), isOn: Binding(
                                get: { tts.enabledSpeeds.contains(s) },
                                set: { on in tts.enabledSpeeds = on ? tts.enabledSpeeds + [s] : tts.enabledSpeeds.filter { $0 != s } }
                            ))
                            .toggleStyle(.checkbox).disabled(s == 1)
                        }
                    }
                    speedPreview
                    if tts.mode == .system, tts.orderedSpeeds.contains(where: { $0 > 2 }) {
                        Text("macOS hlas zvládne najviac 2×, vyššie prehrá ako 2×.")
                            .font(Theme.body(11)).foregroundStyle(warnFG)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                rowDivider
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automaticky skryť pilulku").font(Theme.body(13))
                        Text("Po nečinnosti.").font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
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

            if tts.mode == .googleCloud {
                let chars = Double(google.totalCharactersUsed)
                let rate = Pricing.googleTTSUSDPerChar(voice: google.selectedVoiceName)
                HStack(spacing: 6) {
                    Text(String(format: "Google: %d znakov od resetu · ~%@",
                                google.totalCharactersUsed, currency.format(usd: chars * rate)))
                        .font(Theme.body(11).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                    Button("Resetovať") { google.resetCharacterCount() }
                        .font(Theme.body(11)).foregroundStyle(accent).buttonStyle(.plain).pointingHandCursor()
                    Spacer()
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private var speedPreview: some View {
        HStack(spacing: 6) {
            Text("V pilulke:").font(Theme.body(11)).foregroundStyle(Theme.HUD.textMeta)
            ForEach(Array(tts.orderedSpeeds.enumerated()), id: \.element) { i, s in
                if i > 0 { Text("→").font(Theme.body(11)).foregroundStyle(Theme.HUD.textMeta) }
                Text(TTSEngine.format(s)).font(Theme.bodyBold(12))
                    .foregroundStyle(s == tts.speed ? Theme.HUD.blue : Theme.HUD.icon)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.HUD.background))
    }
}
