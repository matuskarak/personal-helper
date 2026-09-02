import SwiftUI
import AVFoundation
import AppKit
import ServiceManagement
import Charts

extension PreferencesView {
    // MARK: - Mikrofón

    var microphoneTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mikrofón").font(.title2.bold())
            Text("Zoraď mikrofóny podľa dôležitosti — pri štarte diktovania appka použije prvý pripojený z tohto poradia. Ak nie je pripojený žiadny, použije systémový mikrofón.")
                .font(.caption).foregroundStyle(.secondary)

            // Keyed by stableKey, not raw uid — the priority list is stored as stableKeys
            // (see AudioInputDevice.stableKey) so the same USB mic still matches after
            // being moved to a different port. uniquingKeysWith just keeps the first when
            // two simultaneously-connected devices happen to collapse to one key.
            let deviceByKey   = Dictionary(inputDevices.map { ($0.stableKey, $0) }, uniquingKeysWith: { first, _ in first })
            let resolvedKey   = inputDevices.first(where: { $0.uid == dictation.resolvedInputDeviceUID() })?.stableKey
            let unprioritized = inputDevices.filter { !dictation.micPriority.contains($0.stableKey) }

            if !dictation.micPriority.isEmpty {
                card {
                    List {
                        ForEach(dictation.micPriority, id: \.self) { key in
                            let device = deviceByKey[key]
                            let connected = device != nil
                            HStack(spacing: 14) {
                                Image(systemName: "line.3.horizontal")
                                    .font(.caption).foregroundStyle(.tertiary)
                                Image(systemName: connected ? deviceIcon(device!.name) : "mic.slash")
                                    .font(.system(size: 13)).foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text(device?.name ?? savedDeviceName(key))
                                    .font(key == resolvedKey ? .body.bold() : .body)
                                if key == resolvedKey {
                                    Text("aktívny").font(.caption2).foregroundStyle(accent)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(accent.opacity(0.12)))
                                }
                                Spacer()
                                HStack(spacing: 5) {
                                    Circle().fill(connected ? greenDot : Color.secondary.opacity(0.45))
                                        .frame(width: 6, height: 6)
                                    Text(connected ? "Pripojené" : "Nedostupné")
                                        .font(.caption).foregroundStyle(connected ? greenDot : Color.secondary)
                                }
                                Button {
                                    dictation.micPriority.removeAll { $0 == key }
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain).pointingHandCursor()
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
            }

            if !unprioritized.isEmpty {
                card {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(dictation.micPriority.isEmpty ? "Dostupné zariadenia" : "Pridať do poradia")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
                        ForEach(unprioritized) { device in
                            Divider().padding(.leading, 50)
                            Button {
                                dictation.micPriority.append(device.stableKey)
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "plus.circle")
                                        .font(.system(size: 13)).foregroundStyle(accent)
                                        .frame(width: 18)
                                    Image(systemName: deviceIcon(device.name))
                                        .font(.system(size: 13)).foregroundStyle(.secondary)
                                    Text(device.name)
                                    Spacer()
                                }
                                .padding(.horizontal, 16).padding(.vertical, 13)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).pointingHandCursor()
                        }
                    }
                }
            }

            HStack {
                Button("Obnoviť zoznam") { inputDevices = AudioDeviceManager.inputDevices() }
                    .buttonStyle(.bordered).font(.caption)
                if !dictation.micPriority.isEmpty {
                    Button("Vymazať poradie") { dictation.micPriority = [] }
                        .buttonStyle(.bordered).font(.caption).foregroundStyle(.red)
                }
            }

            micTestCard
        }
    }

    // MARK: - Mic test

    @ViewBuilder
    var micTestCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Test mikrofónu").font(.body.bold())
                Text("Prečítaj nahlas zobrazenú vetu — appka skontroluje hlasitosť, šum na pozadí a či prepis sedí s tým, čo si povedal.")
                    .font(.caption).foregroundStyle(.secondary)

                // Reference sentence stays visible for the whole test — it needs to be
                // readable WHILE recording, not just before/after.
                Text("„\(micTest.referenceText)“")
                    .font(.callout.italic())
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(accent.opacity(0.06)))

                switch micTest.phase {
                case .idle, .done, .failed:
                    if case .failed(let msg) = micTest.phase {
                        Text(msg).font(.caption).foregroundStyle(.red)
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
                        Text("Priprav sa… \(secondsLeft)s").foregroundStyle(.secondary)
                        Spacer()
                        Button("Zrušiť") { micTest.cancel() }.buttonStyle(.bordered)
                    }

                case .recording(let secondsLeft):
                    HStack(spacing: 12) {
                        MicEqualizerView(isActive: true, tint: .blue, level: micTest.liveLevel)
                        Text("Nahrávam… \(secondsLeft)s").foregroundStyle(.secondary)
                        Spacer()
                        Button("Zrušiť") { micTest.cancel() }.buttonStyle(.bordered)
                    }

                case .analyzing:
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Analyzujem nahrávku…").foregroundStyle(.secondary)
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
                Text(verdictLabel(r.verdict)).font(.body.bold()).foregroundStyle(verdictColor(r.verdict))
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
                    Text("•").foregroundStyle(.secondary)
                    Text(s).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let t = r.transcript {
                Text("Prepis: „\(t)“").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    func metricStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.callout.monospacedDigit().bold())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    func verdictColor(_ v: MicTestEngine.Verdict) -> Color {
        switch v {
        case .excellent, .good: greenDot
        case .marginal: .orange
        case .poor: .red
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
