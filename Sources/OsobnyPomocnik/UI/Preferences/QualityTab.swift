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
        case .poor: Theme.error
        }
    }

    var qualityTab: some View {
        let stats = qualityStats
        let analyzed = stats.analyzed
        return VStack(alignment: .leading, spacing: 14) {
            Text("Kvalita diktovania").font(Theme.title(22))
            Text("Počíta sa lokálne z histórie, nič sa neposiela.")
                .font(Theme.body(11)).foregroundStyle(Theme.textSecondary).padding(.horizontal, 4)

            if analyzed.isEmpty {
                card {
                    VStack(spacing: 6) {
                        Text("Zatiaľ nemáme dosť dát.").font(Theme.body(12))
                        Text("Metriky sa počítajú až pri nových diktovaniach.")
                            .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(24)
                }
            } else {
                qualitySummaryCard(stats)
                modeUsageCard(stats)
                modelUsageCard(stats)
                if remoteConfig.shadowCompareAllowed { shadowCompareCard(stats) }
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
            sectionCard("Porovnanie modelov",
                        status: "zhoda \(Int((stats.shadowAgreement * 100).rounded())) % · \(Self.plural(stats.shadowPairs.count, "porovnanie", "porovnania", "porovnaní"))",
                        isExpanded: $qualityShadowExpanded) {
                VStack(alignment: .leading, spacing: 0) {
                    captionRow("Tá istá nahrávka, dva modely. \(stats.shadowIdentical)× úplne zhodné.")
                    rowDivider
                    ForEach(Array(stats.shadowPairs.prefix(25).enumerated()), id: \.offset) { index, pair in
                        if index > 0 { rowDivider }
                        shadowRow(pair)
                    }
                    rowDivider
                    HStack {
                        Text("Vymazanie nechá diktovania nedotknuté.")
                            .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button("Vymazať porovnania") { showClearShadowsConfirm = true }
                            .buttonStyle(.bordered).controlSize(.small)
                            .confirmationDialog(
                                "Vymazať všetky porovnania modelov?",
                                isPresented: $showClearShadowsConfirm,
                                titleVisibility: .visible
                            ) {
                                Button("Vymazať", role: .destructive) {
                                    historyStore.clearShadows()
                                    qualityStats = QualityStats(entries: historyStore.entries)
                                }
                                Button("Zrušiť", role: .cancel) {}
                            } message: {
                                Text("Diktovania ostanú nedotknuté, mažú sa len uložené porovnania.")
                            }
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
                    .font(Theme.body(12).monospacedDigit())
                Text(pair.entry.appName.isEmpty ? "—" : pair.entry.appName)
                    .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(Int((pair.agreement * 100).rounded())) %")
                    .font(Theme.body(12).monospacedDigit())
                    // Below ~90 % the two providers genuinely heard different words; above it
                    // they mostly differ on a filler or two, which isn't worth flagging.
                    .foregroundStyle(pair.agreement >= 0.9 ? Theme.textSecondary : Theme.brandAmberSafe)
            }
            if pair.primary.isEmpty && pair.shadow.isEmpty {
                Text("zhodné").font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
            } else {
                diffLine(pair.entry.model ?? "zvolený", pair.primary, .primary)
                diffLine(pair.entry.shadowModel ?? "tieňový", pair.shadow, .secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    func diffLine(_ model: String, _ words: [String], _ style: HierarchicalShapeStyle) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(model).font(Theme.body(11).monospaced()).foregroundStyle(Theme.textSecondary)
                .frame(width: 150, alignment: .leading)
            Text(words.isEmpty ? "—" : words.prefix(12).joined(separator: ", "))
                .font(Theme.body(11)).foregroundStyle(style)
                .textSelection(.enabled)
        }
    }

    func modelUsageCard(_ stats: QualityStats) -> some View {
        sectionCard("Použité modely", status: stats.modelUsage.first.map { "\($0.name) \(Int((Double($0.count) / Double(max(stats.modelTotal, 1)) * 100).rounded())) %" },
                    isExpanded: $qualityModelsExpanded) {
            VStack(alignment: .leading, spacing: 0) {
                if stats.modelTotal == 0 {
                    Text("Zatiaľ žiadne dáta.")
                        .font(Theme.body(12)).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                } else {
                    ForEach(Array(stats.modelUsage.enumerated()), id: \.offset) { index, model in
                        if index > 0 { rowDivider }
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.name).font(Theme.body(12))
                                Text("priemerne \(model.avgSeconds) s na diktovanie")
                                    .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            Text("\(model.count)× (\(Int((Double(model.count) / Double(stats.modelTotal) * 100).rounded())) %)")
                                .font(Theme.body(12).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                    rowDivider
                    Text("Spolu \(stats.modelTotal). Staršie záznamy bez modelu sa nepočítajú.")
                        .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
        }
    }

    func modeUsageCard(_ stats: QualityStats) -> some View {
        sectionCard("Využitie režimov", status: stats.modeCombos.max(by: { $0.count < $1.count }).flatMap { $0.count == 0 ? nil : "\($0.label) \(Int((Double($0.count) / Double(max(stats.modeTotal, 1)) * 100).rounded())) %" },
                    isExpanded: $qualityModesExpanded) {
            VStack(alignment: .leading, spacing: 0) {
                if stats.modeTotal == 0 {
                    Text("Zatiaľ žiadne dáta.")
                        .font(Theme.body(12)).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                } else {
                    ForEach(Array(stats.modeCombos.enumerated()), id: \.offset) { index, combo in
                        if index > 0 { rowDivider }
                        HStack {
                            Text(combo.label).font(Theme.body(12))
                            Spacer()
                            Text("\(combo.count)× (\(Int((Double(combo.count) / Double(stats.modeTotal) * 100).rounded())) %)")
                                .font(Theme.body(12).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                    rowDivider
                    Text("Spolu \(stats.modeTotal). Staršie záznamy bez režimu sa nepočítajú.")
                        .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
        }
    }

    func statTile(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value).font(Theme.title(24)).foregroundStyle(color)
            Text(label).font(Theme.body(10)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    func topFillersCard(_ stats: QualityStats) -> some View {
        sectionCard("Výplňové slová", status: stats.topFillers.first.map { "„\($0.word)“ \($0.count)×" } ?? "žiadne",
                    isExpanded: $qualityFillersExpanded) {
            VStack(alignment: .leading, spacing: 0) {
                if stats.topFillers.isEmpty {
                    Text("Žiadne — čisté diktovanie.")
                        .font(Theme.body(12)).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                } else {
                    ForEach(Array(stats.topFillers.enumerated()), id: \.element.word) { index, pair in
                        if index > 0 { rowDivider }
                        HStack {
                            Text("„\(pair.word)”").font(Theme.body(12))
                            Spacer()
                            Text("\(pair.count)×").font(Theme.body(12).monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
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
        sectionCard("Podľa aplikácie", status: Self.plural(stats.perApp.count, "appka", "appky", "appiek"),
                    isExpanded: $qualityAppsExpanded) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(stats.perApp.enumerated()), id: \.element.name) { index, row in
                    if index > 0 { rowDivider }
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name).font(Theme.body(12))
                            Text(row.category.label)
                                .font(Theme.body(10)).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Text("\(row.count)× diktovanie")
                            .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                        if row.paced > 0 {
                            Text(String(format: "%.1f fill./min", row.avgFillers))
                                .font(Theme.body(11).monospacedDigit())
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
        return sectionCard("Posledné diktovania", isExpanded: $qualityRecentExpanded) {
            VStack(alignment: .leading, spacing: 0) {
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
                Text("Nadiktované").font(Theme.body(10)).foregroundStyle(Theme.textSecondary)
                Text(entry.text).font(Theme.body(12)).textSelection(.enabled)
                if let rewritten = entry.rewrittenText, !rewritten.isEmpty {
                    Text("Po Smart prepise").font(Theme.body(10)).foregroundStyle(Theme.textSecondary)
                    Text(rewritten).font(Theme.body(12)).textSelection(.enabled)
                }
                if entry.hasScreenshot {
                    Text("Screenshot pri diktovaní").font(Theme.body(10)).foregroundStyle(Theme.textSecondary)
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
                    .font(Theme.body(11).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                if !entry.appName.isEmpty {
                    Text(entry.appName).font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if m.fillerCount > 0 {
                    Text("\(m.fillerCount) fill.")
                        .font(Theme.body(11).monospacedDigit())
                        .foregroundStyle(ratingColor(DictationQualityEngine.fillerRating(perMinute: m.fillersPerMinute)))
                }
                if m.wordsPerMinute > 0 {
                    Text("\(m.wordsPerMinute) wpm")
                        .font(Theme.body(11).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    func metricLine(_ label: String, _ value: String, color: Color? = nil) -> some View {
        HStack(alignment: .top) {
            Text(label).font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value).font(Theme.body(11)).foregroundStyle(color ?? .primary)
                .multilineTextAlignment(.trailing)
        }
    }
}
