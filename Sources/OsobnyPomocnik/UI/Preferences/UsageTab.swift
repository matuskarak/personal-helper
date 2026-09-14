import SwiftUI
import AVFoundation
import AppKit
import ServiceManagement
import Charts

extension PreferencesView {
    // MARK: - Prehľad (usage)

    /// The one date range the whole Prehľad tab reads from — the top Dnes/Týždeň/Mesiac/
    /// Rok/Vlastné picker picks which case applies, so the stat cards and the chart below
    /// them can never end up showing different periods (they used to: an earlier version
    /// had a separate range picker just for the chart).
    func currentUsageRange() -> (from: Date, to: Date) {
        let cal = Calendar.current
        let now = Date()
        switch usagePeriod {
        case .today:
            let start = cal.startOfDay(for: now)
            return (start, cal.date(byAdding: .day, value: 1, to: start) ?? now)
        case .week:
            // Monday-first by definition of the ISO8601 calendar's weekOfYear.
            var iso = Calendar(identifier: .iso8601); iso.timeZone = .current
            let comps = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            let start = iso.date(from: comps) ?? now
            return (start, iso.date(byAdding: .day, value: 7, to: start) ?? now)
        case .month:
            let comps = cal.dateComponents([.year, .month], from: now)
            let start = cal.date(from: comps) ?? now
            return (start, cal.date(byAdding: .month, value: 1, to: start) ?? now)
        case .year:
            let comps = cal.dateComponents([.year], from: now)
            let start = cal.date(from: comps) ?? now
            return (start, cal.date(byAdding: .year, value: 1, to: start) ?? now)
        case .custom:
            return (customFrom, customTo)
        }
    }

    var usageTab: some View {
        let range = currentUsageRange()
        let summary = usageStore.summary(from: range.from, to: range.to)

        return VStack(alignment: .leading, spacing: 14) {
            Text("Prehľad").font(Theme.title(22))

            HStack(spacing: 10) {
                Picker("", selection: $usagePeriod) {
                    ForEach(UsagePeriod.allCases, id: \.self) { p in
                        Text(p.label).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 460)

                if usagePeriod == .custom {
                    DatePicker("Od", selection: $customFrom,
                               in: earliestStoredDate...customTo, displayedComponents: .date)
                    DatePicker("Do", selection: $customTo,
                               in: customFrom...Date(), displayedComponents: .date)
                }
                Spacer()
            }
            .font(Theme.body(11))

            // One card, three tiles — the figures are the point of this tab.
            card {
                HStack(spacing: 0) {
                    usageTile(timeSavedString(summary), "ušetrený čas")
                    Divider().frame(height: 44)
                    usageTile(minutesString(summary.dictationSeconds),
                              "diktovanie · \(summary.dictationWords) slov · \(dictationCostString(summary.dictationSeconds))")
                    Divider().frame(height: 44)
                    usageTile("\(summary.readingWords)",
                              "prečítaných slov" + (tts.mode == .googleCloud ? " · \(readingCostString(summary.readingChars))" : ""))
                }
                .padding(.vertical, 14)
            }
            Text("Odhad: písanie ~40 slov/min, čítanie ~120, počúvanie ~180 slov/min.")
                .font(Theme.body(11)).foregroundStyle(Theme.textSecondary).padding(.horizontal, 4)
            usageChart(range: range)
        }
    }

    /// Earliest selectable date for the custom range — matches UsageStore's own retention,
    /// so the picker can't offer a date the store has already pruned.
    var earliestStoredDate: Date {
        Calendar.current.date(byAdding: .day, value: -UsageStore.maxAgeDays, to: Date()) ?? Date.distantPast
    }

    func usageChart(range: (from: Date, to: Date)) -> some View {
        let buckets = usageStore.dictationDailyByModel(from: range.from, to: range.to)
        return card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Vývoj diktovania").font(Theme.bodyBold(13))
                    Spacer()
                    Picker("", selection: $chartKind) {
                        ForEach(ChartKind.allCases, id: \.self) { k in Text(k.label).tag(k) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 120)
                    Picker("", selection: $chartMetric) {
                        ForEach(ChartMetric.allCases, id: \.self) { m in Text(m.label).tag(m) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 230)
                }

                if buckets.isEmpty {
                    Text("Zatiaľ žiadne dáta za toto obdobie.")
                        .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
                } else {
                    Chart(buckets) { b in
                        switch chartKind {
                        case .bar:
                            BarMark(
                                x: .value("Deň", b.day, unit: .day),
                                y: .value(chartMetric.label, chartValue(b))
                            )
                            .foregroundStyle(by: .value("Model", modelLabel(b.model)))
                        case .line:
                            LineMark(
                                x: .value("Deň", b.day, unit: .day),
                                y: .value(chartMetric.label, chartValue(b))
                            )
                            .foregroundStyle(by: .value("Model", modelLabel(b.model)))
                            .symbol(by: .value("Model", modelLabel(b.model)))
                        }
                    }
                    .chartForegroundStyleScale(range: [accent, accent.opacity(0.55), accent.opacity(0.3)])
                    .chartLegend(position: .bottom, spacing: 8)
                    .frame(height: 180)
                }
            }
            .padding(16)
        }
    }

    func chartValue(_ b: UsageStore.DailyModelBucket) -> Double {
        switch chartMetric {
        case .words:     Double(b.words)
        case .timeSaved: max(0, Double(b.words) / 40.0 - Double(b.seconds) / 60.0)
        }
    }

    func modelLabel(_ raw: String) -> String {
        switch raw {
        case "gpt-live-transcribe":     "Live"
        case "gpt-realtime-whisper":    "Realtime"
        case "gpt-transcribe":          "Transcribe"
        case "gpt-4o-mini-transcribe":  "4o-mini"
        case "gpt-4o-transcribe":       "4o"
        case "whisper-1":               "Whisper-1"
        default:                        raw.isEmpty ? "—" : raw
        }
    }

    func usageTile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(Theme.title(22).monospacedDigit())
            Text(label).font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }

    func usageStatRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value).font(Theme.body(12).monospacedDigit())
        }
    }

    func minutesString(_ seconds: Int) -> String {
        let m = seconds / 60, s = seconds % 60
        return String(format: "%d:%02d min", m, s)
    }

    func dictationCostString(_ seconds: Int) -> String {
        "~" + currency.format(usd: Double(seconds) / 60 * dictation.costPerMinute)
    }

    func readingCostString(_ chars: Int) -> String {
        let rate = Pricing.googleTTSUSDPerChar(voice: google.selectedVoiceName)
        return "~" + currency.format(usd: Double(chars) * rate)
    }

    /// ponytail: closed-form estimate, no real playback-duration tracking —
    /// dictation compares actual seconds to a 40wpm typing baseline; reading
    /// compares a 120wpm manual-reading baseline to a 180wpm TTS-listening baseline.
    func timeSavedString(_ s: UsageStore.Summary) -> String {
        UsageStore.savedTimeText(s)
    }
}
