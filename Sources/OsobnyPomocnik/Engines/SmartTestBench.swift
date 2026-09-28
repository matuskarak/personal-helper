import Foundation

/// Developer-mode bench: `open ozvena://smartTest` runs fixed, made-up transcripts through Smart
/// for every category (and every tone for e-mail) and writes the results to
/// ~/Library/Logs/OsobnyPomocnik/smart-test.md — to judge formatting without dictating.
/// Only synthetic text below, never a real transcript.
@MainActor
enum SmartTestBench {
    private static let cases: [(AppCategory, String)] = [
        (.email, "ahoj peťo tak teda posielam ti ten návrh na tú spoluprácu s tým že by sme vlastne začali niekedy zhruba v októbri no a cena za ten projekt bude teda nejakých dvetisíc eur toto prosím ťa zvýrazni a ešte potrebujem od teba vlastne podklady ako logo a texty do konca týždňa ďakujem pekne maj sa"),
        (.messaging, "čau no tak ja tam budem asi tak o siedmej že ešte musím teda skočiť do obchodu a potom idem rovno k tebe ok"),
        (.document, "poznámky z porady nadpis úlohy na tento týždeň odrážka dokončiť web pre klienta odrážka poslať faktúru odrážka zavolať dodávateľovi nový odsek termín dodania je piatok to je dôležité zvýrazni to"),
        (.aiChat, "napíš mi teda nejaký krátky článok o tom ako proste šetriť energiu doma nejakých päť tipov a aby to bolo také priateľské pre bežného človeka a nie príliš dlhé"),
        (.generic, "dobrý deň chcel by som sa opýtať či máte ešte voľný termín na budúci týždeň vlastne v utorok alebo v stredu ide o servis auta ďakujem"),
    ]

    static func run() async {
        guard RemoteConfig.shared.developerModeGranted else { return }
        let engine = SmartRewriteEngine.shared
        let key = DictationEngine.shared.openAIKey
        let savedTone = engine.tone
        defer { engine.tone = savedTone }
        var out = "# Smart test — \(engine.model) — \(Date())\n"
        for (category, text) in cases {
            let tones: [SmartRewriteEngine.Tone] = category == .email ? SmartRewriteEngine.Tone.allCases : [savedTone]
            for tone in tones {
                engine.tone = tone
                let profile = AppProfileStore.defaults.first { $0.category == category } ?? AppProfileStore.defaults[0]
                out += "\n## \(category.rawValue) · \(tone.rawValue)\n\n**Vstup:** \(text)\n\n"
                do {
                    let r = try await engine.rewrite(transcript: text, screenshotJPEG: nil, profile: profile,
                                                     category: category, apiKey: key)
                    out += "**Výstup:**\n\n\(r.text)\n\n_zmeny: \(r.changes) · cieľ: \(r.target) · issues: \(r.issues)_\n"
                } catch {
                    out += "**Chyba:** \(error)\n\n\(engine.lastRejected ?? "")\n"
                }
            }
        }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/OsobnyPomocnik/smart-test.md")
        try? out.write(to: url, atomically: true, encoding: .utf8)
        AppLogger.log("[SmartTestBench] hotovo → smart-test.md")
    }
}
