import SwiftUI
import AVFoundation
import AppKit
import ServiceManagement
import Charts

extension PreferencesView {
    // MARK: - Čítanie

    var readingTab: some View {
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
}
