import SwiftUI
import AVFoundation
import AppKit
import ServiceManagement
import Charts

extension PreferencesView {
    // MARK: - Všeobecné

    var generalTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Všeobecné").font(Theme.title(22))

            card {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mena pre ceny").font(Theme.body(13))
                        Text("Orientačne, podľa cenníka OpenAI (\(Pricing.ratesCheckedOn)).")
                            .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { currency },
                        set: { currency = $0; AppCurrency.selected = $0 }
                    )) {
                        ForEach(AppCurrency.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).frame(width: 180).labelsHidden()
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                rowDivider
                toggleRow(title: "Zdieľať anonymné štatistiky",
                          subtitle: "Tempo, dĺžka, model a typ appky — nikdy text ani kľúče.",
                          isOn: Binding(
                    get: { telemetry.isEnabled },
                    set: { telemetry.isEnabled = $0; if !$0 { telemetry.clearQueue() } }
                ))
            }

            // One row per key; the field + test unfold only for the key being edited.
            let keyCount = [dictation.hasOpenAIKey, dictation.hasGeminiKey, google.hasAPIKey].filter { $0 }.count
            sectionCard("API kľúče", status: "\(keyCount) z 3 nastavené", isExpanded: $keysSectionExpanded) {
                apiKeyRow(
                    id: "openai", title: "OpenAI", subtitle: "Diktovanie, Smart a návrhy kľúčových slov.",
                    placeholder: "sk-…", keyInput: $openAIKeyInput, saved: $openAIKeySaved,
                    hasKey: dictation.hasOpenAIKey,
                    onSave: { dictation.openAIKey = openAIKeyInput },
                    testResult: $apiKeyTestResult, testRunning: $apiKeyTestRunning,
                    onTest: { await dictation.testAPIKey() },
                    getKeyURL: URL(string: "https://platform.openai.com/api-keys")!
                )
                rowDivider
                apiKeyRow(
                    id: "gemini", title: "Gemini", subtitle: "Len pre model gemini-3.5-transcribe.",
                    placeholder: "AIza…", keyInput: $geminiKeyInput, saved: $geminiKeySaved,
                    hasKey: dictation.hasGeminiKey,
                    onSave: { dictation.geminiKey = geminiKeyInput },
                    testResult: $geminiKeyTestResult, testRunning: $geminiKeyTestRunning,
                    onTest: { await dictation.testGeminiKey() },
                    getKeyURL: URL(string: "https://aistudio.google.com/apikey")!
                )
                rowDivider
                apiKeyRow(
                    id: "google", title: "Google Cloud", subtitle: "Len pre čítanie Google hlasom.",
                    placeholder: "AIza…", keyInput: $apiKeyInput, saved: $apiKeySaved,
                    hasKey: google.hasAPIKey,
                    onSave: { google.apiKey = apiKeyInput; Task { await loadGoogleVoices() } },
                    testResult: $googleKeyTestResult, testRunning: $googleKeyTestRunning,
                    onTest: {
                        do { _ = try await google.fetchVoices(); return .ok("Kľúč funguje") }
                        catch { return .failure(error.localizedDescription) }
                    },
                    getKeyURL: URL(string: "https://console.cloud.google.com/apis/credentials")!
                )
            }

            card {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Prístupový kód").font(Theme.body(13))
                        Text("Odomkne funkcie, ktoré ti niekto povolil.")
                            .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    TextField("napr. jano-x7k2", text: $accessCodeInput)
                        .textFieldStyle(.roundedBorder).frame(width: 160)
                    Button(accessCodeSaved ? "Uložené" : "Uložiť") {
                        remoteConfig.accessCode = accessCodeInput
                        accessCodeSaved = true
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
    }

    func apiKeyRow(
        id: String,
        title: String,
        subtitle: String,
        placeholder: String,
        keyInput: Binding<String>,
        saved: Binding<Bool>,
        hasKey: Bool,
        onSave: @escaping () -> Void,
        testResult: Binding<Theme.KeyCheck?>,
        testRunning: Binding<Bool>,
        onTest: @escaping () async -> Theme.KeyCheck,
        getKeyURL: URL
    ) -> some View {
        let editing = editingKey == id
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.body(13))
                    Text(subtitle).font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                    if let result = testResult.wrappedValue {
                        Text(result.message).font(Theme.body(11)).foregroundStyle(result.color)
                    }
                }
                Spacer()
                statusChip(hasKey ? "nastavený" : "chýba", color: hasKey ? Theme.success : Theme.brandAmberSafe)
                Button(editing ? "Hotovo" : (hasKey ? "Upraviť" : "Nastaviť")) {
                    withAnimation(Self.sectionAnim) { editingKey = editing ? nil : id }
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            if editing {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SecureField(placeholder, text: keyInput).textFieldStyle(.roundedBorder)
                        Button(saved.wrappedValue ? "Uložené" : "Uložiť") { onSave(); saved.wrappedValue = true }
                            .disabled(keyInput.wrappedValue.isEmpty)
                            .buttonStyle(.borderedProminent).tint(accent)
                    }
                    HStack {
                        Button("Testovať kľúč") {
                            Task {
                                testRunning.wrappedValue = true
                                testResult.wrappedValue = await onTest()
                                testRunning.wrappedValue = false
                            }
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(testRunning.wrappedValue || !hasKey)
                        if testRunning.wrappedValue { ProgressView().controlSize(.small) }
                        Spacer()
                        Link("Získať kľúč ↗", destination: getKeyURL).font(Theme.body(11))
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .nestedRow()
            }
        }
    }
}
