import SwiftUI
import AVFoundation
import AppKit
import ServiceManagement
import Charts

extension PreferencesView {
    // MARK: - Skratky

    var shortcutsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Klávesové skratky").font(Theme.title(22))

            VStack(alignment: .leading, spacing: 4) {
                Text("Klikni na skratku a stlač novú kombináciu. „+“ pridá ďalšiu (max \(ShortcutStore.maxPerAction)).")
                    .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                if shortcutsIntroExpanded {
                    Text("Diktovanie zastaví len tá istá skratka, ktorou začalo. Smart ukončenie ho ukončí a prepis pred vložením upraví AI.")
                        .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                }
                Button(shortcutsIntroExpanded ? "Menej" : "Viac") { shortcutsIntroExpanded.toggle() }
                    .font(Theme.body(11)).buttonStyle(.plain).pointingHandCursor().foregroundStyle(accent)
            }
            .padding(.horizontal, 4)

            card {
                ShortcutMappingRow(label: "Diktovanie", action: .dictateBatch)
                if remoteConfig.realtimeAllowed {
                    rowDivider
                    ShortcutMappingRow(label: "Diktovanie — realtime", action: .dictateRealtime)
                }
                if remoteConfig.smartDictationAllowed {
                    rowDivider
                    ShortcutMappingRow(label: "Smart ukončenie", action: .smartStop)
                }
                rowDivider
                ShortcutMappingRow(label: "Zrušiť diktovanie", action: .cancelDictation)
                rowDivider
                ShortcutMappingRow(label: "Čítať text", action: .readText)
                if remoteConfig.ocrAllowed {
                    rowDivider
                    ShortcutMappingRow(label: "OCR oblasť", action: .ocr)
                }
                rowDivider
                ShortcutMappingRow(label: "Vložiť z pamäte", action: .insertFromMemory)
                rowDivider
                HStack {
                    Spacer()
                    Button("Obnoviť predvolené") { showResetShortcutsConfirm = true }
                        .buttonStyle(.bordered).controlSize(.small)
                        .confirmationDialog("Obnoviť všetky skratky na predvolené?",
                                            isPresented: $showResetShortcutsConfirm, titleVisibility: .visible) {
                            Button("Obnoviť", role: .destructive) {
                                ShortcutStore.shared.resetAllToDefaults()
                                shortcutsResetToken += 1
                            }
                            Button("Zrušiť", role: .cancel) {}
                        } message: {
                            Text("Odstráni pridané skratky a vráti pôvodné kombinácie.")
                        }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .id(shortcutsResetToken) // forces each row to reload from the store after a reset
        }
    }
}
