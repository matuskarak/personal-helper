import SwiftUI
import AVFoundation
import AppKit
import ServiceManagement
import Charts

extension PreferencesView {
    // MARK: - Skratky

    var shortcutsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Klávesové skratky").font(.title2.bold())

            card {
                ShortcutMappingRow(label: "Diktovanie — realtime", action: .dictateRealtime)
                rowDivider
                ShortcutMappingRow(label: "Diktovanie — po nahraní", action: .dictateBatch)
                if remoteConfig.smartDictationAllowed {
                    rowDivider
                    ShortcutMappingRow(label: "Smart ukončenie diktovania", action: .smartStop)
                }
                rowDivider
                ShortcutMappingRow(label: "Zrušiť diktovanie", action: .cancelDictation)
                rowDivider
                ShortcutMappingRow(label: "Čítať text", action: .readText)
                rowDivider
                ShortcutMappingRow(label: "OCR oblasť", action: .ocr)
                rowDivider
                ShortcutMappingRow(label: "Vložiť z pamäte", action: .insertFromMemory)
            }
            .id(shortcutsResetToken) // forces each row to reload from the store after a reset

            Text("Diktovacia skratka režim aj spúšťa aj zastavuje (zastaví ho len tá istá skratka, ktorou začal). „Smart ukončenie“ nie je samostatné diktovanie — ukončí bežiace diktovanie a prepis pred vložením upraví AI.\n\nKlikni na skratku a stlač novú kombináciu (vyžaduje aspoň jeden modifier). Tlačidlom „+“ pridáš ďalšiu skratku pre tú istú akciu — napríklad inú kombináciu na externej klávesnici než na notebooku (max \(ShortcutStore.maxPerAction)).")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)

            Button("Obnoviť predvolené skratky") { showResetShortcutsConfirm = true }
                .buttonStyle(.bordered)
                .confirmationDialog(
                    "Obnoviť všetky skratky na predvolené hodnoty?",
                    isPresented: $showResetShortcutsConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Obnoviť", role: .destructive) {
                        ShortcutStore.shared.resetAllToDefaults()
                        shortcutsResetToken += 1
                    }
                    Button("Zrušiť", role: .cancel) {}
                } message: {
                    Text("Odstráni všetky pridané skratky a vráti pôvodné kombinácie.")
                }
        }
    }
}
