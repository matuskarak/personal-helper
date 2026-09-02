import SwiftUI
import AVFoundation
import AppKit
import ServiceManagement
import Charts

extension PreferencesView {
    // MARK: - Všeobecné

    var generalTab: some View {
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

            card {
                toggleRow(title: "Zdieľať anonymné štatistiky používania",
                          subtitle: "Posiela sa tempo reči, počet slov, výplňové slová, dĺžka a výsledok diktovania, použitý model a typ appky (správy / e-mail / dokument). Nikdy nie samotný text, kľúčové slová, názvy appiek ani kľúče. Pomáha mi zlepšovať prepis.",
                          isOn: Binding(
                    get: { telemetry.isEnabled },
                    set: { telemetry.isEnabled = $0; if !$0 { telemetry.clearQueue() } }
                ))
            }

            // All three provider keys live here, always visible — a conditionally appearing
            // card is exactly what a visually impaired user cannot hunt for.
            Text("API kľúče").font(.headline)

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

            card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Gemini API kľúč").font(.body)
                    Text("Gemini beží na Google účte, nie na OpenAI kľúči vyššie. Realtime diktovanie a Smart spracovanie používajú naďalej OpenAI.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        SecureField("AIza…", text: $geminiKeyInput).textFieldStyle(.roundedBorder)
                        Button(geminiKeySaved ? "Uložené ✓" : "Uložiť") {
                            dictation.geminiKey = geminiKeyInput
                            geminiKeySaved = true
                        }
                        .disabled(geminiKeyInput.isEmpty)
                        .buttonStyle(.borderedProminent).tint(accent)
                    }
                    if let result = geminiKeyTestResult {
                        Text(result).font(.caption)
                            .foregroundStyle(result.hasPrefix("✅") ? .green : .red)
                    }
                    HStack {
                        Button("Testovať kľúč") {
                            Task {
                                geminiKeyTestRunning = true
                                geminiKeyTestResult = await dictation.testGeminiKey()
                                geminiKeyTestRunning = false
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(geminiKeyTestRunning || !dictation.hasGeminiKey)
                        if geminiKeyTestRunning { ProgressView().controlSize(.small) }
                        Spacer()
                        Link("Získať kľúč →",
                             destination: URL(string: "https://aistudio.google.com/apikey")!)
                            .font(.caption)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }

            card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Google Cloud API kľúč").font(.body)
                    Text("Potrebný len pre čítanie kvalitnejším Google hlasom (záložka Čítanie).")
                        .font(.caption).foregroundStyle(.secondary)
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
}
