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
        VStack(alignment: .leading, spacing: 16) {
            Text("História diktovania").font(.title2.bold())
            Text("Posledné nadiktované texty — len lokálne. Keďže sem môže padnúť čokoľvek, čo nadiktuješ, históriu môžeš kedykoľvek celú vymazať.")
                .font(.caption).foregroundStyle(.secondary)

            if historyStore.entries.isEmpty {
                card {
                    Text("Zatiaľ žiadna história.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(24)
                }
            } else {
                card {
                    // Lazy: history is uncapped (hundreds of entries and growing) and this
                    // used to build every row eagerly on tab open — the История tab's lag.
                    LazyVStack(spacing: 0) {
                        ForEach(Array(historyStore.entries.reversed().enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { rowDivider }
                            historyRow(entry)
                        }
                    }
                }
                Button("Vymazať históriu") { historyStore.clearAll() }
                    .buttonStyle(.bordered).font(.caption).foregroundStyle(.red)
            }
        }
    }

    func historyRow(_ entry: DictationHistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.historyDateFormatter.string(from: entry.date))
                    .font(.caption2).foregroundStyle(.tertiary)
                // Same text that the insert button pastes — see MenuBarController's history menu.
                Text(entry.rewrittenText ?? entry.text)
                    .font(.callout)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                let text = entry.rewrittenText ?? entry.text
                AppLogger.log("[PreferencesView] história — vložené na požiadanie (\(text.count) znakov)")
                TextInserter.shared.insert(text)
            } label: {
                Image(systemName: "arrow.right.doc.on.clipboard")
            }
            .buttonStyle(.bordered)
            .help("Vložiť do aktívneho poľa")
            Button {
                historyStore.delete(entry.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain).pointingHandCursor()
            .foregroundStyle(.secondary)
            .help("Vymazať túto položku")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
