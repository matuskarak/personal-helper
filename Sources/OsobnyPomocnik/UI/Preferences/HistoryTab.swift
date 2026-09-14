import SwiftUI
import AVFoundation
import AppKit
import ServiceManagement
import Charts

extension PreferencesView {
    // MARK: - História

    static let historyDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d. M. HH:mm"
        return f
    }()

    var historyTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("História diktovania").font(Theme.title(22))
            Text("Len lokálne. Vymažeš po jednom alebo celú.")
                .font(Theme.body(11)).foregroundStyle(Theme.textSecondary).padding(.horizontal, 4)
            if historyStore.entries.isEmpty {
                card {
                    Text("Zatiaľ žiadna história.")
                        .font(Theme.body(12)).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(24)
                }
            } else {
                card {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(historyStore.entries.reversed().enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { rowDivider }
                            historyRow(entry)
                        }
                    }
                    rowDivider
                    HStack {
                        Spacer()
                        Button("Vymazať históriu") { showClearHistoryConfirm = true }
                            .buttonStyle(.bordered).controlSize(.small).foregroundStyle(Theme.error)
                            .confirmationDialog("Vymazať celú históriu diktovania?",
                                                isPresented: $showClearHistoryConfirm, titleVisibility: .visible) {
                                Button("Vymazať", role: .destructive) { historyStore.clearAll() }
                                Button("Zrušiť", role: .cancel) {}
                            } message: {
                                Text("Nedá sa vrátiť späť.")
                            }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
        }
    }

    func historyRow(_ entry: DictationHistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.historyDateFormatter.string(from: entry.date)
                     + (entry.appName.isEmpty ? "" : " · \(entry.appName)"))
                    .font(Theme.body(11).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                Text(entry.rewrittenText ?? entry.text)
                    .font(Theme.body(12))
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Vložiť") {
                let text = entry.rewrittenText ?? entry.text
                AppLogger.log("[PreferencesView] história — vložené na požiadanie (\(text.count) znakov)")
                TextInserter.shared.insert(text)
            }
            .buttonStyle(.bordered).controlSize(.small)
            .help("Vložiť do aktívneho poľa")
            Button {
                historyStore.delete(entry.id)
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain).pointingHandCursor()
            .foregroundStyle(Theme.textSecondary)
            .help("Vymazať túto položku")
            .accessibilityLabel("Vymazať položku")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
