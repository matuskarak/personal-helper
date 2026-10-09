import Foundation

/// Developer-mode prompt bench — Smart tuning without dictating and without a rebuild per
/// prompt change. Everything lives in ~/Library/Logs/OsobnyPomocnik/bench/ and only ever holds
/// made-up test text, never a real transcript.
///
/// - `ozvena://smartTest`   — fixed transcripts through the real `rewrite()` → smart-test.md
/// - `ozvena://benchDump`   — reads dump-in.json [{id, category, transcript}] and writes the
///   exact request bodies Smart would send → dump-out.json (the baseline to vary)
/// - `ozvena://benchRun`    — reads run-in.json [{id, body}] (any Chat Completions body),
///   sends them with the stored OpenAI key → run-out.json [{id, status, content, ms}].
///   The key stays in the app; the bench only proxies to api.openai.com.
@MainActor
enum SmartTestBench {
    private static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/OsobnyPomocnik/bench")

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
        var rows: [[String: Any]] = []
        // A corpus in dump-in.json (from the prompt bench) replaces the built-in cases.
        // Optional "selection" = Smart úprava označeného textu; transcript is then the instruction.
        let corpus = read("dump-in.json")?.compactMap { item -> (String, AppCategory, String, String?)? in
            guard let id = item["id"] as? String, let t = item["transcript"] as? String,
                  let c = AppCategory(rawValue: item["category"] as? String ?? "") else { return nil }
            return (id, c, t, item["selection"] as? String)
        } ?? cases.enumerated().map { ("c\($0.offset)", $0.element.0, $0.element.1, nil) }
        for (id, category, text, selection) in corpus {
            let tones: [SmartRewriteEngine.Tone] = [savedTone]
            for tone in tones {
                engine.tone = tone
                out += "\n## \(category.rawValue) · \(tone.rawValue)\n\n**Vstup:** \(text)\n\n"
                do {
                    let r = try await engine.rewrite(transcript: text, screenshotJPEG: nil, profile: profile(category),
                                                     category: category, apiKey: key, selection: selection)
                    out += "**Výstup:**\n\n\(r.text)\n\n_zmeny: \(r.changes) · cieľ: \(r.target) · issues: \(r.issues)_\n"
                    rows.append(["id": id, "out": r.text])
                } catch {
                    out += "**Chyba:** \(error)\n\n\(engine.lastRejected ?? "")\n"
                    rows.append(["id": id, "out": "<<chyba \(error)"])
                }
            }
        }
        write(out.data(using: .utf8), "smart-test.md")
        write(try? JSONSerialization.data(withJSONObject: rows, options: .prettyPrinted), "smart-test.json")
        AppLogger.log("[SmartTestBench] hotovo → smart-test.md")
    }

    static func dump() {
        guard RemoteConfig.shared.developerModeGranted,
              let items = read("dump-in.json") else { return }
        let bodies: [[String: Any]] = items.compactMap { item in
            guard let id = item["id"] as? String, let text = item["transcript"] as? String,
                  let category = AppCategory(rawValue: item["category"] as? String ?? "") else { return nil }
            let (body, _) = SmartRewriteEngine.shared.requestBody(transcript: text, screenshotJPEG: nil,
                                                                  profile: profile(category), category: category)
            return ["id": id, "body": body]
        }
        write(try? JSONSerialization.data(withJSONObject: bodies, options: [.prettyPrinted, .sortedKeys]), "dump-out.json")
        AppLogger.log("[SmartTestBench] dump hotovo — \(bodies.count)")
    }

    static func proxy() async {
        guard RemoteConfig.shared.developerModeGranted,
              let items = read("run-in.json") else { return }
        let key = DictationEngine.shared.openAIKey
        var results: [[String: Any]] = []
        // ponytail: batches of 6 in parallel, enough to stay under rate limits for a bench
        for chunk in stride(from: 0, to: items.count, by: 6).map({ Array(items[$0..<min($0 + 6, items.count)]) }) {
            await withTaskGroup(of: [String: Any].self) { group in
                for item in chunk {
                    guard let body = item["body"], let data = try? JSONSerialization.data(withJSONObject: body) else { continue }
                    let id = item["id"] as? String ?? "?"
                    group.addTask {
                        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!, timeoutInterval: 90)
                        req.httpMethod = "POST"
                        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        req.httpBody = data
                        let t0 = Date()
                        do {
                            let (resp, http) = try await URLSession.shared.data(for: req)
                            let json = try? JSONSerialization.jsonObject(with: resp) as? [String: Any]
                            let msg = (json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
                            return ["id": id, "status": (http as? HTTPURLResponse)?.statusCode ?? 0,
                                    "content": msg?["content"] as? String ?? String(data: resp, encoding: .utf8) ?? "",
                                    "usage": json?["usage"] ?? [:],
                                    "ms": Int(Date().timeIntervalSince(t0) * 1000)]
                        } catch {
                            return ["id": id, "status": -1, "content": "\(error)", "ms": 0]
                        }
                    }
                }
                for await r in group { results.append(r) }
            }
        }
        write(try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]), "run-out.json")
        AppLogger.log("[SmartTestBench] run hotovo — \(results.count) odpovedí")
    }

    private static func profile(_ category: AppCategory) -> AppProfile {
        AppProfileStore.defaults.first { $0.category == category } ?? AppProfileStore.defaults[0]
    }

    private static func read(_ name: String) -> [[String: Any]]? {
        (try? Data(contentsOf: dir.appendingPathComponent(name)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
    }

    private static func write(_ data: Data?, _ name: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data?.write(to: dir.appendingPathComponent(name))
    }
}
