import SwiftUI
import AVFoundation
import AppKit
import ServiceManagement
import Charts

extension PreferencesView {
    // MARK: - O aplikácii

    var aboutTab: some View {
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
                    rowDivider

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Záznam audio problémov").font(.body)
                            Text("Odpojenia a pripojenia mikrofónov, pomalé alebo zaseknuté odpovede audio subsystému. Samostatný súbor — nemaže sa spolu so záznamom vyššie, aby sa dal spätne dohľadať vzorec.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Zobraziť") { NSWorkspace.shared.activateFileViewerSelecting([AudioHealth.fileURL]) }
                            .buttonStyle(.bordered)
                            .disabled(!FileManager.default.fileExists(atPath: AudioHealth.fileURL.path))
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

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}
