import SwiftUI
import AVFoundation
import AppKit
import ServiceManagement
import Charts

extension PreferencesView {
    // MARK: - Kvalita diktovania

    /// Everything the Kvalita tab draws, derived in ONE pass over the history.
    ///
    /// ponytail: recomputed on appear and whenever the history grows — not on every render.
    /// Each card used to walk the full history itself (analyzed list, filler totals, per-app
    /// grouping, four mode filters), so a tab with 570+ entries did six full passes every
    /// time any unrelated observable changed. Upgrade path if history reaches six figures:
    /// keep running totals in the store instead of rebuilding here.
    struct QualityStats {
        var analyzed: [(entry: DictationHistoryEntry, metrics: DictationMetrics)] = []
        var avgWPM = 0
        var avgFillers = 0.0
        var topFillers: [(word: String, count: Int)] = []
        var perApp: [(name: String, count: Int, paced: Int, avgFillers: Double, category: AppCategory)] = []
        var modeCombos: [(label: String, count: Int)] = []
        var modeTotal = 0
        var modelUsage: [(name: String, count: Int, avgSeconds: Int)] = []
        var modelTotal = 0
        var shadowPairs: [(entry: DictationHistoryEntry, agreement: Double,
                           primary: [String], shadow: [String])] = []
        var shadowAgreement = 0.0
        var shadowIdentical = 0

        /// Only entries logged since quality tracking shipped carry metrics — older history
        /// has no numbers to show, so everything here is computed off that filtered list.
        init(entries: [DictationHistoryEntry]) {
            analyzed = entries.compactMap { e in e.metrics.map { (entry: e, metrics: $0) } }

            var wpmSum = 0, paced = 0
            var fillerRateSum = 0.0
            var fillerTotals: [String: Int] = [:]
            var groups: [String: (count: Int, fillerRateSum: Double, paced: Int, category: AppCategory)] = [:]
            for item in analyzed {
                if item.metrics.wordsPerMinute > 0 {
                    wpmSum += item.metrics.wordsPerMinute
                    fillerRateSum += item.metrics.fillersPerMinute
                    paced += 1
                }
                for (word, count) in item.metrics.fillers { fillerTotals[word, default: 0] += count }

                let key = item.entry.appName.isEmpty ? "Neznáma appka" : item.entry.appName
                var g = groups[key] ?? (0, 0, 0, item.entry.category)
                g.count += 1
                if item.metrics.wordsPerMinute > 0 {
                    g.fillerRateSum += item.metrics.fillersPerMinute
                    g.paced += 1
                }
                groups[key] = g
            }
            if paced > 0 {
                avgWPM = Int((Double(wpmSum) / Double(paced)).rounded())
                avgFillers = fillerRateSum / Double(paced)
            }
            topFillers = fillerTotals
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .prefix(5).map { (word: $0.key, count: $0.value) }
            perApp = groups
                .sorted { $0.value.count > $1.value.count }
                .map { (name: $0.key, count: $0.value.count, paced: $0.value.paced,
                        avgFillers: $0.value.paced > 0 ? $0.value.fillerRateSum / Double($0.value.paced) : 0,
                        category: $0.value.category) }

            // Mode/Smart split — only entries recorded since per-shortcut modes shipped.
            let tracked = entries.filter { $0.mode != nil }
            modeTotal = tracked.count
            modeCombos = [
                ("Realtime — čisté",   tracked.filter { $0.mode == "realtime" && $0.smart != true }.count),
                ("Realtime + Smart",   tracked.filter { $0.mode == "realtime" && $0.smart == true }.count),
                ("Po nahraní — čisté", tracked.filter { $0.mode == "batch"    && $0.smart != true }.count),
                ("Po nahraní + Smart", tracked.filter { $0.mode == "batch"    && $0.smart == true }.count),
            ].map { (label: $0.0, count: $0.1) }

            // Which transcription model actually produced each transcript — the split that
            // makes an A/B between providers readable without digging through app.log.
            var models: [String: (count: Int, seconds: Int)] = [:]
            for entry in entries {
                guard let model = entry.model else { continue }
                models[model, default: (0, 0)].count += 1
                models[model, default: (0, 0)].seconds += entry.seconds
            }
            modelTotal = models.values.reduce(0) { $0 + $1.count }
            modelUsage = models
                .sorted { $0.value.count > $1.value.count }
                .map { (name: $0.key, count: $0.value.count,
                        avgSeconds: $0.value.count > 0 ? $0.value.seconds / $0.value.count : 0) }

            // Shadow A/B — same audio, two providers. Newest first: the interesting ones are
            // the recent dictations the user still remembers saying.
            shadowPairs = entries.reversed().compactMap { entry in
                guard let shadow = entry.shadowText else { return nil }
                let diff = TranscriptDiff.differences(entry.text, shadow)
                return (entry, TranscriptDiff.agreement(entry.text, shadow), diff.onlyA, diff.onlyB)
            }
            shadowIdentical = shadowPairs.filter { $0.primary.isEmpty && $0.shadow.isEmpty }.count
            if !shadowPairs.isEmpty {
                shadowAgreement = shadowPairs.reduce(0) { $0 + $1.agreement } / Double(shadowPairs.count)
            }
        }
    }

    func ratingColor(_ rating: DictationQualityEngine.Rating) -> Color {
        switch rating {
        case .good: greenDot
        case .fair: warnFG
        case .poor: .red
        }
    }

    var qualityTab: some View {
        let stats = qualityStats
        let analyzed = stats.analyzed
        return VStack(alignment: .leading, spacing: 16) {
            Text("Kvalita diktovania").font(.title2.bold())
            Text("Vyhodnotené lokálne z tvojej histórie diktovania — nič sa neposiela nikam von a nič to nestojí. Ukazuje, ako naozaj diktuješ, aby si sa v tom mohol zlepšovať.")
                .font(.caption).foregroundStyle(.secondary)

            if analyzed.isEmpty {
                card {
                    VStack(spacing: 6) {
                        Text("Zatiaľ nemáme dosť dát.").font(.callout)
                        Text("Metriky sa počítajú až pri nových diktovaniach — staršie záznamy v histórii ich neobsahujú.")
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(24)
                }
            } else {
                qualitySummaryCard(stats)
                modeUsageCard(stats)
                modelUsageCard(stats)
                shadowCompareCard(stats)
                topFillersCard(stats)
                perAppCard(stats)
                recentDictationsCard(analyzed)
            }
        }
        .onAppear { qualityStats = QualityStats(entries: historyStore.entries) }
        .onChange(of: historyStore.entries.count) { _, _ in
            qualityStats = QualityStats(entries: historyStore.entries)
        }
    }

    func qualitySummaryCard(_ stats: QualityStats) -> some View {
        card {
            HStack(spacing: 0) {
                statTile(value: "\(stats.analyzed.count)", label: "diktovaní", color: .primary)
                Divider().frame(height: 44)
                statTile(value: String(format: "%.1f", stats.avgFillers), label: "výplňových slov / min",
                         color: ratingColor(DictationQualityEngine.fillerRating(perMinute: stats.avgFillers)))
                Divider().frame(height: 44)
                statTile(value: stats.avgWPM > 0 ? "\(stats.avgWPM)" : "–", label: "slov / min",
                         color: ratingColor(DictationQualityEngine.paceRating(wpm: stats.avgWPM)))
            }
            .padding(.vertical, 16)
        }
    }

    /// How dictation is actually used: realtime vs batch, raw vs Smart finish.
    /// Only entries recorded since per-shortcut modes shipped can tell — older ones can't.
    @ViewBuilder
    func shadowCompareCard(_ stats: QualityStats) -> some View {
        if !stats.shadowPairs.isEmpty {
            card {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Porovnanie modelov na tej istej nahrávke").font(.body)
                        Text("Zhoda \(Int((stats.shadowAgreement * 100).rounded())) % na \(stats.shadowPairs.count) porovnaniach · \(stats.shadowIdentical)× úplne zhodné")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    rowDivider
                    ForEach(Array(stats.shadowPairs.prefix(25).enumerated()), id: \.offset) { index, pair in
                        if index > 0 { rowDivider }
                        shadowRow(pair)
                    }
                    rowDivider
                    HStack {
                        Text("Porovnania sa ukladajú k diktovaniam. Vymazanie nechá diktovania nedotknuté.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Vymazať porovnania") { historyStore.clearShadows()
                            qualityStats = QualityStats(entries: historyStore.entries) }
                            .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
        }
    }

    func shadowRow(_ pair: (entry: DictationHistoryEntry, agreement: Double,
                                    primary: [String], shadow: [String])) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(pair.entry.date.formatted(date: .omitted, time: .shortened))
                    .font(.callout.monospacedDigit())
                Text(pair.entry.appName.isEmpty ? "—" : pair.entry.appName)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((pair.agreement * 100).rounded())) %")
                    .font(.callout.monospacedDigit())
                    // Below ~90 % the two providers genuinely heard different words; above it
                    // they mostly differ on a filler or two, which isn't worth flagging.
                    .foregroundStyle(pair.agreement >= 0.9 ? .secondary : Color.orange)
            }
            if pair.primary.isEmpty && pair.shadow.isEmpty {
                Text("zhodné").font(.caption).foregroundStyle(.secondary)
            } else {
                diffLine(pair.entry.model ?? "zvolený", pair.primary, .primary)
                diffLine(pair.entry.shadowModel ?? "tieňový", pair.shadow, .secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    func diffLine(_ model: String, _ words: [String], _ style: HierarchicalShapeStyle) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(model).font(.caption.monospaced()).foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(words.isEmpty ? "—" : words.prefix(12).joined(separator: ", "))
                .font(.caption).foregroundStyle(style)
                .textSelection(.enabled)
        }
    }

    func modelUsageCard(_ stats: QualityStats) -> some View {
        card {
            VStack(alignment: .leading, spacing: 0) {
                Text("Použité modely").font(.body)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                rowDivider
                if stats.modelTotal == 0 {
                    Text("Zatiaľ žiadne dáta — model sa zaznamenáva pri nových diktovaniach.")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                } else {
                    ForEach(Array(stats.modelUsage.enumerated()), id: \.offset) { index, model in
                        if index > 0 { rowDivider }
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.name).font(.callout)
                                Text("priemerne \(model.avgSeconds) s na diktovanie")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(model.count)× (\(Int((Double(model.count) / Double(stats.modelTotal) * 100).rounded())) %)")
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                    rowDivider
                    Text("Spolu \(stats.modelTotal) diktovaní so zaznamenaným modelom. Staršie záznamy model nemajú a nepočítajú sa.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
        }
    }

    func modeUsageCard(_ stats: QualityStats) -> some View {
        card {
            VStack(alignment: .leading, spacing: 0) {
                Text("Využitie režimov").font(.body)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                rowDivider
                if stats.modeTotal == 0 {
                    Text("Zatiaľ žiadne dáta — režim sa zaznamenáva pri nových diktovaniach.")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                } else {
                    ForEach(Array(stats.modeCombos.enumerated()), id: \.offset) { index, combo in
                        if index > 0 { rowDivider }
                        HStack {
                            Text(combo.label).font(.callout)
                            Spacer()
                            Text("\(combo.count)× (\(Int((Double(combo.count) / Double(stats.modeTotal) * 100).rounded())) %)")
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                    rowDivider
                    Text("Spolu \(stats.modeTotal) diktovaní so zaznamenaným režimom. Staršie záznamy režim nemajú a nepočítajú sa.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
        }
    }

    func statTile(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 24, weight: .semibold)).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    func topFillersCard(_ stats: QualityStats) -> some View {
        card {
            VStack(alignment: .leading, spacing: 0) {
                Text("Najčastejšie výplňové slová")
                    .font(.body).padding(.horizontal, 16).padding(.vertical, 12)
                rowDivider
                if stats.topFillers.isEmpty {
                    Text("Žiadne — čisté diktovanie.")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                } else {
                    ForEach(Array(stats.topFillers.enumerated()), id: \.element.word) { index, pair in
                        if index > 0 { rowDivider }
                        HStack {
                            Text("„\(pair.word)”").font(.callout)
                            Spacer()
                            Text("\(pair.count)×").font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                }
            }
        }
    }

    /// Grouped by the app dictated into — the whole point is seeing that you speak
    /// differently to ChatGPT than to Slack.
    func perAppCard(_ stats: QualityStats) -> some View {
        card {
            VStack(alignment: .leading, spacing: 0) {
                Text("Podľa aplikácie")
                    .font(.body).padding(.horizontal, 16).padding(.vertical, 12)
                rowDivider
                ForEach(Array(stats.perApp.enumerated()), id: \.element.name) { index, row in
                    if index > 0 { rowDivider }
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name).font(.callout)
                            Text(row.category.label)
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text("\(row.count)× diktovanie")
                            .font(.caption).foregroundStyle(.secondary)
                        if row.paced > 0 {
                            Text(String(format: "%.1f fill./min", row.avgFillers))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(ratingColor(DictationQualityEngine.fillerRating(perMinute: row.avgFillers)))
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
        }
    }

    func recentDictationsCard(
        _ analyzed: [(entry: DictationHistoryEntry, metrics: DictationMetrics)]
    ) -> some View {
        let recent = Array(analyzed.reversed().prefix(15))
        return card {
            VStack(alignment: .leading, spacing: 0) {
                Text("Posledné diktovania")
                    .font(.body).padding(.horizontal, 16).padding(.vertical, 12)
                rowDivider
                ForEach(Array(recent.enumerated()), id: \.element.entry.id) { index, item in
                    if index > 0 { rowDivider }
                    qualityDetailRow(item.entry, item.metrics)
                }
            }
        }
    }

    func qualityDetailRow(_ entry: DictationHistoryEntry, _ m: DictationMetrics) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                metricLine("Slov", "\(m.wordCount)")
                if m.wordsPerMinute > 0 {
                    metricLine("Tempo", "\(m.wordsPerMinute) slov/min",
                               color: ratingColor(DictationQualityEngine.paceRating(wpm: m.wordsPerMinute)))
                }
                metricLine("Výplňové slová", m.fillerCount == 0 ? "žiadne"
                    : "\(m.fillerCount) (\(m.fillers.sorted { $0.value > $1.value }.map(\.key).joined(separator: ", ")))",
                           color: m.fillerCount == 0 ? nil
                            : ratingColor(DictationQualityEngine.fillerRating(perMinute: m.fillersPerMinute)))
                if m.avgSentenceWords > 0 {
                    metricLine("Priemerná veta", "\(m.avgSentenceWords) slov")
                }
                if m.repeatedSentenceStarts > 0 {
                    metricLine("Opakované začiatky viet", "\(m.repeatedSentenceStarts)", color: warnFG)
                }
                if let ratio = m.rewriteDistanceRatio {
                    metricLine("Smart prepis zmenil", "\(Int((ratio * 100).rounded())) % textu",
                               color: ratio > 0.5 ? warnFG : nil)
                }

                Divider()
                Text("Nadiktované").font(.caption2).foregroundStyle(.tertiary)
                Text(entry.text).font(.callout).textSelection(.enabled)
                if let rewritten = entry.rewrittenText, !rewritten.isEmpty {
                    Text("Po Smart prepise").font(.caption2).foregroundStyle(.tertiary)
                    Text(rewritten).font(.callout).textSelection(.enabled)
                }
                if entry.hasScreenshot {
                    Text("Screenshot pri diktovaní").font(.caption2).foregroundStyle(.tertiary)
                    let url = DictationHistoryStore.shared.screenshotURL(for: entry.id)
                    if let image = NSImage(contentsOf: url) {
                        Image(nsImage: image)
                            .resizable().scaledToFit()
                            .frame(maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .onTapGesture { NSWorkspace.shared.open(url) }
                            .pointingHandCursor()
                            .help("Otvoriť v plnej veľkosti")
                    }
                }
            }
            .padding(.vertical, 8)
        } label: {
            HStack(spacing: 8) {
                Text(Self.historyDateFormatter.string(from: entry.date))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if !entry.appName.isEmpty {
                    Text(entry.appName).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                if m.fillerCount > 0 {
                    Text("\(m.fillerCount) fill.")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(ratingColor(DictationQualityEngine.fillerRating(perMinute: m.fillersPerMinute)))
                }
                if m.wordsPerMinute > 0 {
                    Text("\(m.wordsPerMinute) wpm")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    func metricLine(_ label: String, _ value: String, color: Color? = nil) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption).foregroundStyle(color ?? .primary)
                .multilineTextAlignment(.trailing)
        }
    }
}
