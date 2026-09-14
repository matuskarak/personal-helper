import SwiftUI
import AVFoundation
import AppKit
import ServiceManagement
import Charts

extension PreferencesView {
    // MARK: - Mikrofón

    var microphoneTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Mikrofón").font(Theme.title(22))
            Text("Pri štarte diktovania sa použije prvý pripojený mikrofón z poradia.")
                .font(Theme.body(11)).foregroundStyle(Theme.textSecondary).padding(.horizontal, 4)

            let deviceByKey   = Dictionary(inputDevices.map { ($0.stableKey, $0) }, uniquingKeysWith: { first, _ in first })
            let resolvedKey   = inputDevices.first(where: { $0.uid == dictation.resolvedInputDeviceUID() })?.stableKey
            let unprioritized = inputDevices.filter { !dictation.micPriority.contains($0.stableKey) }

            sectionCard("Poradie",
                        status: dictation.micPriority.isEmpty ? "systémový mikrofón"
                            : Self.plural(dictation.micPriority.count, "zariadenie", "zariadenia", "zariadení"),
                        isExpanded: $micOrderExpanded) {
                if !dictation.micPriority.isEmpty {
                    List {
                        ForEach(dictation.micPriority, id: \.self) { key in
                            let device = deviceByKey[key]
                            let connected = device != nil
                            HStack(spacing: 14) {
                                Image(systemName: "line.3.horizontal")
                                    .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                                Image(systemName: connected ? deviceIcon(device!.name) : "mic.slash")
                                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                                    .frame(width: 18)
                                Text(device?.name ?? savedDeviceName(key))
                                    .font(key == resolvedKey ? Theme.bodyBold(13) : Theme.body(13))
                                if key == resolvedKey { statusChip("aktívny", color: accent) }
                                Spacer()
                                Text(connected ? "Pripojené" : "Nedostupné")
                                    .font(Theme.body(11)).foregroundStyle(connected ? greenDot : Theme.textSecondary)
                                Button {
                                    dictation.micPriority.removeAll { $0 == key }
                                } label: {
                                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                .buttonStyle(.plain).pointingHandCursor()
                                .accessibilityLabel("Odstrániť z poradia")
                            }
                            .padding(.vertical, 4)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                        .onMove { indices, newOffset in
                            dictation.micPriority.move(fromOffsets: indices, toOffset: newOffset)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .frame(height: CGFloat(dictation.micPriority.count) * 40 + 16)
                    .padding(.horizontal, 4)
                }
                if dictation.micPriority.isEmpty && unprioritized.isEmpty {
                    captionRow("Nenašiel som žiadny mikrofón.")
                }
                ForEach(unprioritized) { device in
                    rowDivider
                    Button {
                        dictation.micPriority.append(device.stableKey)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 13)).foregroundStyle(accent).frame(width: 18)
                            Image(systemName: deviceIcon(device.name))
                                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                            Text(device.name)
                            Spacer()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).pointingHandCursor()
                    .accessibilityHint("Pridá mikrofón na koniec poradia")
                }
                rowDivider
                HStack {
                    Spacer()
                    Button("Obnoviť zoznam") { inputDevices = AudioDeviceManager.inputDevices() }
                        .buttonStyle(.bordered).controlSize(.small)
                    if !dictation.micPriority.isEmpty {
                        Button("Vymazať poradie") { dictation.micPriority = [] }
                            .buttonStyle(.bordered).controlSize(.small).foregroundStyle(Theme.error)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }

            micTestCard
        }
    }

    var micTestStatus: String? {
        guard let r = micTest.result else { return nil }
        return "\(verdictLabel(r.verdict)) · \(Int(r.peakDBFS)) dBFS"
    }

    @ViewBuilder
    var micTestCard: some View {
        sectionCard("Test mikrofónu", status: micTestStatus, isExpanded: $micTestExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Prečítaj vetu nahlas — skontrolujem hlasitosť, šum a zhodu prepisu.")
                    .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                Text("„\(micTest.referenceText)“")
                    .font(Theme.body(12).italic())
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(accent.opacity(0.06)))
                switch micTest.phase {
                case .idle, .done, .failed:
                    if case .failed(let msg) = micTest.phase {
                        Text(msg).font(Theme.body(11)).foregroundStyle(Theme.error)
                    }
                    if let r = micTest.result {
                        micTestResultView(r)
                    }
                    Button(micTest.result == nil ? "Spustiť test" : "Skúsiť znova") {
                        micTest.startTest()
                    }
                    .buttonStyle(.borderedProminent).tint(accent)
                case .preparing(let secondsLeft):
                    HStack(spacing: 12) {
                        MicEqualizerView(isActive: false, tint: .secondary)
                        Text("Priprav sa… \(secondsLeft)s").foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button("Zrušiť") { micTest.cancel() }.buttonStyle(.bordered)
                    }
                case .recording(let secondsLeft):
                    HStack(spacing: 12) {
                        MicEqualizerView(isActive: true, tint: Theme.brandBlue, level: micTest.liveLevel)
                        Text("Nahrávam… \(secondsLeft)s").foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button("Zrušiť") { micTest.cancel() }.buttonStyle(.bordered)
                    }
                case .analyzing:
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Analyzujem nahrávku…").foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    func micTestResultView(_ r: MicTestEngine.Result) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(verdictColor(r.verdict)).frame(width: 8, height: 8)
                Text(verdictLabel(r.verdict)).font(Theme.bodyBold(13)).foregroundStyle(verdictColor(r.verdict))
            }
            HStack(spacing: 20) {
                metricStat("Hlasitosť (peak)", String(format: "%.0f dBFS", r.peakDBFS))
                if let snr = r.snrDB {
                    metricStat("Šum (SNR)", String(format: "%.0f dB", snr))
                }
                if r.clippingPercent > 0.05 {
                    metricStat("Skreslenie", String(format: "%.1f%%", r.clippingPercent))
                }
                if let match = r.matchPercent {
                    metricStat("Zhoda prepisu", String(format: "%.0f%%", match))
                }
            }
            ForEach(r.suggestions, id: \.self) { s in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundStyle(Theme.textSecondary)
                    Text(s).font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                }
            }
            if let t = r.transcript {
                Text("Prepis: „\(t)“").font(Theme.body(10)).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    func metricStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.bodyBold(12).monospacedDigit())
            Text(label).font(Theme.body(10)).foregroundStyle(Theme.textSecondary)
        }
    }

    func verdictColor(_ v: MicTestEngine.Verdict) -> Color {
        switch v {
        case .excellent, .good: greenDot
        case .marginal: Theme.brandAmberSafe
        case .poor: Theme.error
        }
    }

    func verdictLabel(_ v: MicTestEngine.Verdict) -> String {
        switch v {
        case .excellent: "Výborné"
        case .good: "Dobré"
        case .marginal: "Priemerné"
        case .poor: "Slabé"
        }
    }

    func deviceIcon(_ name: String) -> String {
        let l = name.lowercased()
        if l.contains("airpod")                          { return "airpodspro" }
        if l.contains("macbook") || l.contains("built")  { return "laptopcomputer" }
        return "mic.circle"
    }

    /// Best-effort display name for a disconnected device, parsed straight out of its
    /// stableKey — still `AppleUSBAudioEngine:<Manufacturer>:<Product>` for USB, so the
    /// product name is at the same index whether or not the device is currently plugged in.
    func savedDeviceName(_ key: String) -> String {
        let parts = key.split(separator: ":").map(String.init)
        return parts.count >= 3 ? parts[2] : key
    }
}
