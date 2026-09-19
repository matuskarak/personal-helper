import Foundation
import Observation

/// Licenčný kľúč — appka bez platného kľúča nefunguje. Kľúč sa overuje proti vlastnému hosted
/// backendu (`Ozvena-licencie/`, PHP + SQLite na Hostingeri — nie tento repo, kľúče sa nikdy
/// nedostanú na verejný GitHub). Endpoint dostane presne jeden kľúč a vráti, či je platný a aké
/// má entitlements — nikdy nevracia zoznam platných kľúčov, appka nemá ako "vylistovať" ostatné.
///
/// `hasValidLicense` je `true` len po aspoň jednom skutočnom úspešnom overení — offline potom
/// appka ďalej funguje (posledné entitlements zostanú v cache), ale kým sa nikdy neoverila,
/// fail-open neplatí: žiadna sieť pri prvom spustení = appka zostáva zamknutá, nie otvorená.
/// Model catalog (`models.json`, ceny) je nezávislý od licencií — zostáva verejný GitHub fetch.
@Observable
@MainActor
final class RemoteConfig {
    static let shared = RemoteConfig()

    // Dočasná Hostinger doména (bez vlastnej domény zatiaľ) — pozri "~/Cluade Projects/Ozvena-licencie/README.md".
    private static let licenseValidationURL = URL(string: "https://paleturquoise-hedgehog-719343.hostingersite.com/api/validate.php")!
    private static let modelsURL = URL(string: "https://raw.githubusercontent.com/matuskarak/personal-helper/master/models.json")!
    private static let entitlementsCacheKey = "license.entitlementsCache.v1"
    private static let modelsCacheKey = "remoteConfig.modelsCache.v1"
    private static let keyKey = "license.key"
    private static let validatedKey = "license.hasValidated"
    private static let refreshInterval: TimeInterval = 3600

    /// Every flag defaults to false — čo dostane nová licencia, kým ju vlastník ručne neupraví.
    struct Entitlements: Codable {
        var smartDictationEnabled = false
        var realtimeEnabled       = false   // ⌘⇧S realtime + live insert (4× the price)
        var ocrEnabled            = false   // ⌘⇧O screen-region OCR
        var allModelsEnabled      = false   // show catalog models marked available:false
        // Remote equivalent of the local (#if DEBUG-only) DeveloperMode toggle — lets a
        // specific license auto-unlock every feature flag below AND surface dev-only/
        // testing UI (e.g. AboutTab's silence-trim A/B test) in a RELEASE build, without a
        // rebuild. Deliberately separate from "Diagnostika" logging, which stays on for
        // everyone by default and costs nothing — this one gates things that can double a
        // tester's OpenAI bill (A/B re-transcribes every dictation), so it must default
        // false and only ever be flipped per-license from the admin dashboard.
        var developerModeEnabled = false

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            smartDictationEnabled = try c.decodeIfPresent(Bool.self, forKey: .smartDictationEnabled) ?? false
            realtimeEnabled       = try c.decodeIfPresent(Bool.self, forKey: .realtimeEnabled) ?? false
            ocrEnabled            = try c.decodeIfPresent(Bool.self, forKey: .ocrEnabled) ?? false
            allModelsEnabled      = try c.decodeIfPresent(Bool.self, forKey: .allModelsEnabled) ?? false
            developerModeEnabled  = try c.decodeIfPresent(Bool.self, forKey: .developerModeEnabled) ?? false
        }
    }

    private struct ValidateResponse: Decodable {
        let valid: Bool
        let entitlements: Entitlements?
    }

    /// Kľúč, čo appka aktuálne skúša — editovateľný v Onboardingu aj v Nastavenia → Všeobecné.
    var licenseKey: String {
        didSet {
            guard licenseKey != oldValue else { return }
            UserDefaults.standard.set(licenseKey, forKey: Self.keyKey)
            // Zmena kľúča si musí znova "zaslúžiť" hasValidLicense — žiadny carry-over zo
            // starého kľúča, ani na chvíľu.
            hasValidLicense = false
            UserDefaults.standard.set(false, forKey: Self.validatedKey)
            entitlements = Entitlements()
            Task { await validate() }
        }
    }

    private(set) var hasValidLicense: Bool
    /// Drives a spinner in the UI while a `validate()` call is in flight — otherwise clicking
    /// "Uložiť a overiť" gives no feedback until the network round-trip finishes.
    private(set) var isValidating = false
    /// Result of the last finished check, for the UI's message — nil while one is running.
    /// Kept apart from `hasValidLicense`: "offline" must not look like "invalid", nor pass silently.
    enum ValidationOutcome { case valid, invalid, offline }
    private(set) var lastOutcome: ValidationOutcome?

    /// Save-and-verify from the UI. Re-submitting the same key used to do nothing at all
    /// (`licenseKey`'s didSet ignores an unchanged value), so the button gave no feedback.
    func submitLicenseKey(_ input: String) {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if key == licenseKey { Task { await validate() } } else { licenseKey = key }
    }
    private(set) var entitlements = Entitlements()
    /// Transcription models on offer — served remotely so a new model (same API shape as
    /// OpenAI transcriptions or Gemini interactions) reaches users without a new build.
    private(set) var catalog = ModelCatalog.builtin

    /// True when EITHER the license's own `developerModeEnabled` entitlement is set, or the
    /// local Xcode-debug-only `DeveloperMode` toggle is on. Drives both "unlock everything
    /// below" and visibility of dev-only/testing UI (see `Entitlements.developerModeEnabled`).
    var developerModeGranted: Bool { entitlements.developerModeEnabled || DeveloperMode.isEnabled }

    var smartDictationAllowed: Bool { entitlements.smartDictationEnabled || developerModeGranted }
    var realtimeAllowed:       Bool { entitlements.realtimeEnabled       || developerModeGranted }
    var ocrAllowed:            Bool { entitlements.ocrEnabled            || developerModeGranted }
    var allModelsAllowed:      Bool { entitlements.allModelsEnabled      || developerModeGranted }
    /// Dev-only, not a grantable entitlement — doubles transcription cost (2. model naviac),
    /// only ever meant for internal quality comparison. See `AboutTab`'s Developer mode card.
    var shadowCompareAllowed:  Bool { developerModeGranted }

    private init() {
        licenseKey = UserDefaults.standard.string(forKey: Self.keyKey) ?? ""
        hasValidLicense = UserDefaults.standard.bool(forKey: Self.validatedKey)
        if let data = UserDefaults.standard.data(forKey: Self.entitlementsCacheKey),
           let decoded = try? JSONDecoder().decode(Entitlements.self, from: data) {
            entitlements = decoded
        }
        if let data = UserDefaults.standard.data(forKey: Self.modelsCacheKey) { applyModels(data) }
        Task { await validate() }
        Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.validate() }
        }
    }

    /// Overí `licenseKey` proti hosted backendu. Sieťová chyba/timeout ponecháva presne to, čo
    /// appka mala predtým (fail-open, ale len pre inštaláciu, ktorá sa už niekedy overila) —
    /// vyslovene neplatný kľúč naopak hneď zamkne, aj offline dáta z cache sa zahodia.
    func validate() async {
        let key = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            AppLogger.log("[RemoteConfig] licencia: žiadny kľúč zadaný")
            return
        }
        isValidating = true
        lastOutcome = nil
        defer { isValidating = false }
        var req = URLRequest(url: Self.licenseValidationURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(["key": key])
        req.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            AppLogger.log("[RemoteConfig] overenie licencie zlyhalo (sieť): \(error) — ponechávam predchádzajúci stav")
            lastOutcome = .offline
            return
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(ValidateResponse.self, from: data)
        else {
            AppLogger.log("[RemoteConfig] overenie licencie zlyhalo (neplatná odpoveď) — ponechávam predchádzajúci stav")
            lastOutcome = .offline
            return
        }

        guard decoded.valid else {
            hasValidLicense = false
            UserDefaults.standard.set(false, forKey: Self.validatedKey)
            entitlements = Entitlements()
            AppLogger.log("[RemoteConfig] licencia: kľúč neplatný")
            lastOutcome = .invalid
            return
        }

        hasValidLicense = true
        lastOutcome = .valid
        entitlements = decoded.entitlements ?? Entitlements()
        UserDefaults.standard.set(true, forKey: Self.validatedKey)
        if let encoded = try? JSONEncoder().encode(entitlements) {
            UserDefaults.standard.set(encoded, forKey: Self.entitlementsCacheKey)
        }
        AppLogger.log("[RemoteConfig] licencia platná → smart=\(entitlements.smartDictationEnabled) realtime=\(entitlements.realtimeEnabled) ocr=\(entitlements.ocrEnabled) allModels=\(entitlements.allModelsEnabled) dev=\(entitlements.developerModeEnabled)")

        // Modely (ceny) idú nezávisle, rovnakým behom — bez ohľadu na výsledok vyššie.
        if let (mData, mResp) = try? await URLSession.shared.data(from: Self.modelsURL),
           (mResp as? HTTPURLResponse)?.statusCode == 200 {
            applyModels(mData)
            UserDefaults.standard.set(mData, forKey: Self.modelsCacheKey)
        }
    }

    private func applyModels(_ data: Data) {
        guard let decoded = try? JSONDecoder().decode(ModelCatalog.self, from: data),
              !decoded.batchModels.isEmpty else { return }
        catalog = decoded
    }
}

struct ModelInfo: Codable, Identifiable, Hashable {
    var id: String            // API model id, e.g. "gpt-transcribe"
    var provider: String      // "openai" | "gemini" — picks endpoint + key
    var displayName: String
    var usdPerMinute: Double
    var available: Bool
}

struct ModelCatalog: Codable {
    var batchModels: [ModelInfo]
    var eurPerUSD: Double
    var ratesCheckedOn: String

    /// Mirror of today's hardcoded values — offline first launch behaves exactly like before.
    static let builtin = ModelCatalog(
        batchModels: [
            ModelInfo(id: "gpt-transcribe",         provider: "openai", displayName: "gpt-transcribe (rýchly, odporúčaný)", usdPerMinute: 0.0045, available: true),
            ModelInfo(id: "gemini-3.5-transcribe",  provider: "gemini", displayName: "gemini-3.5-transcribe (presný na odborné termíny)", usdPerMinute: 0.005, available: true),
            ModelInfo(id: "gpt-4o-mini-transcribe", provider: "openai", displayName: "gpt-4o-mini-transcribe (najlacnejší)", usdPerMinute: 0.003, available: false),
            ModelInfo(id: "gpt-4o-transcribe",      provider: "openai", displayName: "gpt-4o-transcribe", usdPerMinute: 0.006, available: false),
            ModelInfo(id: "whisper-1",              provider: "openai", displayName: "whisper-1 (starší)", usdPerMinute: 0.006, available: false),
        ],
        eurPerUSD: 0.92,
        ratesCheckedOn: "júl 2026"
    )

    func info(for id: String) -> ModelInfo? { batchModels.first { $0.id == id } }
}
