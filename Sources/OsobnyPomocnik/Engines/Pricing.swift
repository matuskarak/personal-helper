import Foundation

/// Display currency for the cost estimates. Just the two that were asked for.
enum AppCurrency: String, CaseIterable, Sendable {
    case eur, usd

    var label: String { self == .eur ? "Euro (€)" : "Dolár ($)" }
    var symbol: String { self == .eur ? "€" : "$" }

    private static let key = "ui.currency"

    static var selected: AppCurrency {
        get { AppCurrency(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .eur }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// Both APIs bill in USD, so EUR is a conversion.
    @MainActor var perUSD: Double { self == .eur ? Pricing.eurPerUSD : 1 }

    /// Formats a USD amount in this currency. Sub-10-cent totals get a third decimal —
    /// otherwise a real but tiny cost renders as "0,00 €" and reads as broken, not cheap.
    @MainActor func format(usd: Double) -> String {
        let v = usd * perUSD
        return String(format: v < 0.1 ? "%.3f %@" : "%.2f %@", v, symbol)
    }
}

/// API list prices, compiled in.
///
/// ponytail: there is no public pricing API at either provider to read these from, so they
/// can't be genuinely live. Rather than pretend otherwise, the rates carry the date they
/// were last checked and the UI shows it — a stale number is then visibly stale instead of
/// quietly wrong. If keeping them current becomes a chore, the natural next step is to serve
/// them from the same GitHub JSON that already feeds RemoteConfig, so prices can be updated
/// without shipping a new build.
@MainActor
enum Pricing {
    /// Shown next to the rates so the figure is never mistaken for a live quote.
    static var ratesCheckedOn: String { RemoteConfig.shared.catalog.ratesCheckedOn }

    /// Fixed conversion, not an FX lookup — these are "~" estimates next to a tilde. Served
    /// from models.json so a drifted rate can be nudged without a build.
    static var eurPerUSD: Double { RemoteConfig.shared.catalog.eurPerUSD }

    /// USD per minute of audio, per transcription model — remote catalog first, old
    /// hardcoded switch as fallback for ids the catalog doesn't carry.
    static func usdPerMinute(realtime: Bool, batchModel: String) -> Double {
        guard !realtime else { return 0.017 }
        if let info = RemoteConfig.shared.catalog.info(for: batchModel) { return info.usdPerMinute }
        switch batchModel {
        case "gpt-4o-mini-transcribe": return 0.003
        case "gpt-transcribe":         return 0.0045
        case "gemini-3.5-transcribe":  return 0.005
        default:                       return 0.006 // gpt-4o-transcribe, whisper-1
        }
    }

    /// Human-readable per-minute rate for a model, for the picker in Nastavenia.
    static func perMinuteLabel(realtime: Bool, batchModel: String = "") -> String {
        let usd = usdPerMinute(realtime: realtime, batchModel: batchModel)
        return "\(AppCurrency.selected.format(usd: usd)) / min"
    }

    /// USD per character for Google Cloud TTS, by voice tier.
    static func googleTTSUSDPerChar(voice: String) -> Double {
        if voice.contains("Chirp3-HD") || voice.contains("Chirp-HD") { return 0.00016 }
        if voice.contains("WaveNet") || voice.contains("Neural2")    { return 0.000016 }
        return 0.000004
    }
}
