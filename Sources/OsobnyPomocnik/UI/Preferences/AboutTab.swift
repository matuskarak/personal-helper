import SwiftUI
import AVFoundation
import AppKit
import ServiceManagement
import Charts

extension PreferencesView {
    // MARK: - O aplikácii

    var aboutTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("O aplikácii").font(Theme.title(22))

            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Ozvena").font(Theme.title(17))
                        Text("alfa")
                            .font(Theme.bodyBold(10))
                            .foregroundStyle(Theme.brandAmberSafe)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.brandAmber.opacity(0.16), in: Capsule())
                    }
                    Text("Verzia \(appVersion) (build \(appBuild))")
                        .font(Theme.body(12)).foregroundStyle(Theme.textSecondary)
                }
            }

            card {
                toggleRow(title: "Spustiť pri prihlásení", isOn: Binding(
                    get: { LaunchAtLogin.isEnabled },
                    set: { LaunchAtLogin.isEnabled = $0 }
                ))
                rowDivider
                HStack {
                    Text("Povolenia").font(Theme.body(13))
                    Spacer()
                    Button("Skontrolovať…") { showOnboarding = true }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
                rowDivider
                externalLinkRow("GitHub", url: URL(string: "https://github.com/matuskarak/personal-helper")!)
            }

            // Always available: a tester's "it broke" report is worthless without the log.
            sectionCard("Diagnostika",
                        status: loggingEnabled ? "zapnuté · \(logSizeText)" : "vypnuté",
                        isExpanded: $diagnosticsExpanded) {
                toggleRow(title: "Záznam",
                          subtitle: "Priebeh appky a audio udalosti — bez prepisov a kľúčov.",
                          isOn: Binding(
                    get: { loggingEnabled },
                    set: { loggingEnabled = $0; AppLogger.isEnabled = $0; refreshLogSize() }
                ))
                if loggingEnabled {
                    rowDivider
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Súbor záznamu").font(Theme.body(13))
                            Text("Keď niečo nefunguje: zopakuj problém a klikni Pripraviť na poslanie.")
                                .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Button("Pripraviť na poslanie") { exportLogToDesktop() }
                            .buttonStyle(.borderedProminent).controlSize(.small).tint(accent)
                            .help("Uloží kópiu na plochu a označí ju vo Finderi")
                        Button("Zobraziť") { LogViewerWindowController.shared.show() }
                            .buttonStyle(.bordered).controlSize(.small)
                        Button("Vymazať") { AppLogger.clear(); refreshLogSize(); exportedLogName = nil }
                            .buttonStyle(.bordered).controlSize(.small).foregroundStyle(Theme.error)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    rowDivider
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Záznam audio problémov").font(Theme.body(13))
                            Text("Odpojenia mikrofónov a zaseknutý audio subsystém.")
                                .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Button("Zobraziť") { NSWorkspace.shared.activateFileViewerSelecting([AudioHealth.fileURL]) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(!FileManager.default.fileExists(atPath: AudioHealth.fileURL.path))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    if let name = exportedLogName {
                        rowDivider
                        captionRow("Uložené na plochu: \(name)", color: greenDot)
                    }
                }
            }

            // Testovacie funkcie, ktoré môžu zdvojiť náklady na API (napr. A/B test nižšie
            // prepisuje každé diktovanie aj druhýkrát navyše) — nesmú sa dať zapnúť náhodou
            // bežnému testerovi. Karta sa zobrazí len keď licencia má developerModeEnabled
            // (Ozvena-licencie/admin), nie za `#if DEBUG` — nech to funguje aj v release
            // builde, ktorý si sťahujú testeri, bez potreby rebuildu z Xcode.
            if remoteConfig.developerModeGranted {
                card {
                    captionRow("Developer mode aktívny (z licencie) — testovacie funkcie, ktoré nemá bežný tester.", color: Theme.brandAmberSafe)
                    rowDivider
                    toggleRow(title: "A/B test strihania ticha",
                              subtitle: dictation.silenceTrimABTestEnabled
                                ? "Každé diktovanie so strihom ticha sa prepíše aj netrimované — dvojnásobná cena."
                                : "Overí, či strih ticha niekde neorezal reč.",
                              isOn: $dictation.silenceTrimABTestEnabled)
                    rowDivider
                    toggleRow(title: "Tieňový prepis (2. model)",
                              subtitle: dictation.canShadowCompare
                                ? "Prepíše aj cez \(dictation.shadowModelName), porovnanie v Kvalite. Platíš oba prepisy."
                                : "Vyžaduje OpenAI aj Gemini kľúč.",
                              isOn: $dictation.shadowCompareEnabled)
                        .disabled(!dictation.canShadowCompare)
                }
            }

            #if DEBUG
            card {
                toggleRow(title: "Developer mode (lokálne)",
                          subtitle: "Reštart z menu bar ikonky (⌥) a funkcie vo vývoji.",
                          isOn: Binding(
                    get: { developerMode },
                    set: { developerMode = $0; DeveloperMode.isEnabled = $0 }
                ))
            }
            #endif

        }
    }

    // MARK: - Diagnostics helpers

    var logSizeText: String {
        logSizeBytes < 1024 ? "\(logSizeBytes) B"
            : ByteCountFormatter.string(fromByteCount: Int64(logSizeBytes), countStyle: .file)
    }

    func refreshLogSize() { logSizeBytes = AppLogger.fileSizeBytes }

    static func modelNote(_ model: String) -> String {
        switch model {
        case "gpt-transcribe":         return " (odporúčaný, najpresnejší)"
        case "gemini-3.5-transcribe":  return " (Google, preview — vlastný slovník)"
        case "gpt-4o-mini-transcribe": return " (staršia generácia)"
        default:                       return ""
        }
    }

    /// Desktop + reveal in Finder rather than a save panel: for the target audience a
    /// predictable, one-click destination beats navigating a file dialog.
    func exportLogToDesktop() {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first,
              let url = AppLogger.exportCopy(to: desktop) else {
            exportedLogName = nil
            return
        }
        exportedLogName = url.lastPathComponent
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @ViewBuilder
    func externalLinkRow(_ label: String, url: URL) -> some View {
        Link(destination: url) {
            HStack {
                Text(label).font(Theme.body(13)).foregroundStyle(Theme.textPrimary)
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

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}
