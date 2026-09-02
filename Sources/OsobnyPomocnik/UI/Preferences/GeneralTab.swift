import SwiftUI
import AVFoundation
import AppKit
import ServiceManagement
import Charts

extension PreferencesView {
    // MARK: - Všeobecné

    var generalTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Všeobecné").font(.title2.bold())

            card {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mena pre ceny").font(.body)
                        Text("Ceny sú orientačné, podľa cenníka OpenAI (\(Pricing.ratesCheckedOn)). Prepočet z dolárov je fixný, nie podľa aktuálneho kurzu.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { currency },
                        set: { currency = $0; AppCurrency.selected = $0 }
                    )) {
                        ForEach(AppCurrency.allCases, id: \.self) { c in
                            Text(c.label).tag(c)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    .labelsHidden()
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
    }
}
