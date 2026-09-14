import Foundation

/// One AI-suggested keyword, waiting for the user to approve it before it touches any real
/// keyword field. `profileID == nil` means "global" (Nastavenia → Diktovanie); otherwise it
/// targets that App profile's own keyword list.
struct KeywordSuggestion: Identifiable, Equatable {
    let id = UUID()
    let term: String
    let reason: String
    let profileID: UUID?
}

/// Reads recent dictation history and asks a cheap OpenAI model to spot names, tools and
/// foreign-language terms worth adding as transcription keywords — the exact thing keywords
/// exist for (see DictationTab's own explanation). Manual only: nothing here runs unless the
/// user presses the button, and nothing it returns is written anywhere until the user approves
/// individual suggestions in the popover. See UI/Preferences/KeywordSuggestionPopover.swift.
@MainActor
enum KeywordSuggestionEngine {
    /// Keeps the request comfortably under token/cost limits — older entries past this are
    /// simply left out, newest first (most relevant to "how do I dictate now").
    private static let maxInputChars = 120_000
    private static let minEntries = 5

    enum SuggestionError: LocalizedError {
        case noKey
        case notEnoughHistory
        case http(Int, String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .noKey:             "OpenAI API kľúč nie je nastavený (Nastavenia → Všeobecné)."
            case .notEnoughHistory:  "Zatiaľ nemáš dosť histórie diktovaní na zmysluplný návrh."
            case .http(let c, let m): "OpenAI API chyba \(c): \(m.prefix(160))"
            case .badResponse:       "Neočakávaná odpoveď servera."
            }
        }
    }

    /// Analyzes the last `days` of dictation history and returns suggestions the user hasn't
    /// already covered. Never modifies any keyword field itself.
    static func suggest(days: Int = 30) async throws -> [KeywordSuggestion] {
        let key = DictationEngine.shared.openAIKey
        guard !key.isEmpty else { throw SuggestionError.noKey }

        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let entries = DictationHistoryStore.shared.entries
            .filter { $0.date >= cutoff && !$0.text.isEmpty }
            .sorted { $0.date > $1.date }
        guard entries.count >= minEntries else { throw SuggestionError.notEnoughHistory }

        let profiles = AppProfileStore.shared.profiles
        let existingGlobal = AppProfile.parseKeywords(DictationEngine.shared.defaultKeywords)

        // Grouped by profile under a "### " header, instead of repeating "[profil] " on every
        // single line. The old per-line bracket was itself indistinguishable from real content
        // to the model — it once suggested "Generický (fallback)" back as a keyword because
        // that literal bracketed text sat right next to the transcript. A header line marked
        // as metadata in the prompt (below) removes that trap and is far cheaper token-wise.
        var byProfile: [(name: String, lines: [String])] = []
        var used = 0
        outer: for entry in entries {
            let profile = AppProfileStore.shared.matchingProfile(bundleID: entry.bundleID.isEmpty ? nil : entry.bundleID, windowTitle: nil)
            var line = entry.text
            if let rewritten = entry.rewrittenText, rewritten != entry.text {
                line += "\n↳ oprava: \(rewritten)"
            }
            if let shadow = entry.shadowText, !shadow.isEmpty, shadow != entry.text {
                line += "\n↳ druhý model: \(shadow)"
            }
            guard used + line.count <= maxInputChars else { break outer }
            used += line.count
            if let idx = byProfile.firstIndex(where: { $0.name == profile.displayName }) {
                byProfile[idx].lines.append(line)
            } else {
                byProfile.append((profile.displayName, [line]))
            }
        }
        let transcript = byProfile
            .map { "### \($0.name)\n" + $0.lines.joined(separator: "\n") }
            .joined(separator: "\n\n")
        AppLogger.log("[KeywordSuggestion] vstup: \(entries.count) záznamov za \(days) dní, použitých \(used) znakov")

        let existingBlock = existingBlockText(existingGlobal: existingGlobal, profiles: profiles)
        let body = requestBody(transcript: transcript, existingBlock: existingBlock, profileNames: profiles.map(\.displayName))

        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 60

        let t0 = Date()
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw SuggestionError.badResponse }
        guard http.statusCode == 200 else {
            throw SuggestionError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "?")
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let contentText = message["content"] as? String,
            let contentData = contentText.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any]
        else { throw SuggestionError.badResponse }

        let suggestions = parse(parsed, profiles: profiles, existingGlobal: existingGlobal)
        AppLogger.log("[KeywordSuggestion] hotovo — \(suggestions.filter { $0.profileID == nil }.count) globálnych, \(suggestions.filter { $0.profileID != nil }.count) profilových, \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        return suggestions
    }

    // MARK: - Prompt construction

    private static func existingBlockText(existingGlobal: [String], profiles: [AppProfile]) -> String {
        var lines = ["Globálne: " + (existingGlobal.isEmpty ? "(žiadne)" : existingGlobal.joined(separator: ", "))]
        for profile in profiles where !profile.transcriptionKeywords.isEmpty {
            lines.append("\(profile.displayName): " + profile.transcriptionKeywords.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    private static func requestBody(transcript: String, existingBlock: String, profileNames: [String]) -> [String: Any] {
        let systemPrompt = """
        Analyzuješ históriu diktovaní z hlasového asistenta a navrhuješ NOVÉ kľúčové slová, ktoré \
        pomôžu prepisovaciemu modelu (Whisper/GPT-transcribe) rozpoznávať vlastné mená, názvy \
        firiem/klientov/produktov/nástrojov, skratky a anglické odborné termíny v slovenskej vete. \
        Uprednostni termíny, ktoré sa opakujú, alebo kde sa prepis a jeho oprava/druhý model líšia \
        (to je znak, že sa slovo komolí). Vráť kanonický (správny) pravopis. Nevracaj bežné slová \
        ani výplňové slová ("proste", "vlastne", "hej").

        PRÍSNE PRAVIDLO — žiadne vymýšľanie: každý návrh MUSÍ byť slovo alebo fráza, ktorá sa \
        DOSLOVNE (prípadne v skomolenej/nesprávne prepísanej podobe) nachádza v texte v \
        <historia_diktovani> nižšie. NIKDY nenavrhuj termín len preto, že by „typicky sedel" k \
        danej appke, profilu alebo téme (napr. nesmieš navrhnúť „Node.js" alebo „Laravel" len \
        preto, že ide o programátorský profil — iba ak sa tie slová v histórii SKUTOČNE vyskytujú). \
        Ak si nie si istý, že sa termín v histórii reálne objavuje, radšej ho vynechaj — menej \
        návrhov je lepšie ako jeden vymyslený.

        Riadky začínajúce "### " sú METADÁTA — meno App profilu, do ktorého sa diktovalo, nie \
        súčasť nadiktovaného textu. Nikdy ich neber ako obsah na návrh kľúčového slova (napr. \
        "### Generický (fallback)" nesmie samo osebe viesť k návrhu "Generický" ani "fallback").

        <existujuce_klucove_slova>
        \(existingBlock)
        </existujuce_klucove_slova>

        Vyššie uvedené slová sú UŽ NASTAVENÉ a mimo tvojej právomoci:
        1. Sú referenčný pravopis — ak sa v histórii objaví ich skomolená verzia, NEnavrhuj ju, \
        existujúce slovo to už rieši.
        2. NIKDY ich nevracaj znova, ani ako variant (iné písmená, pád, množné číslo, s/bez diakritiky).
        3. Nenavrhuj ich úpravu ani odstránenie — navrhuješ VÝHRADNE nové doplnky.
        4. Slovo, ktoré je už globálne, nenavrhuj znova do žiadneho profilu.

        Existujúce App profily, ku ktorým môžeš priradiť návrh (profileName musí byť presne jeden \
        z tohto zoznamu, inak sa návrh zaradí ako globálny): \(profileNames.joined(separator: ", ")).

        Max 25 globálnych návrhov a max 8 návrhov na jeden profil, len pre profily s dostatkom \
        záznamov v histórii. Ku každému návrhu pridaj jeden krátky dôvod (do 12 slov) po slovensky, \
        ktorý spomenie, že/ako sa termín v histórii reálne vyskytol.
        """

        return [
            "model": "gpt-4o-mini",
            "temperature": 0,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "<historia_diktovani>\n\(transcript)\n</historia_diktovani>"]
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "keyword_suggestions",
                    "strict": true,
                    "schema": [
                        "type": "object",
                        "properties": [
                            "global": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "properties": ["term": ["type": "string"], "reason": ["type": "string"]],
                                    "required": ["term", "reason"],
                                    "additionalProperties": false
                                ]
                            ],
                            "perApp": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "profileName": ["type": "string"],
                                        "terms": [
                                            "type": "array",
                                            "items": [
                                                "type": "object",
                                                "properties": ["term": ["type": "string"], "reason": ["type": "string"]],
                                                "required": ["term", "reason"],
                                                "additionalProperties": false
                                            ]
                                        ]
                                    ],
                                    "required": ["profileName", "terms"],
                                    "additionalProperties": false
                                ]
                            ]
                        ],
                        "required": ["global", "perApp"],
                        "additionalProperties": false
                    ]
                ]
            ],
            "max_tokens": 2000
        ]
    }

    // MARK: - Response parsing + dedupe

    private static func parse(_ json: [String: Any], profiles: [AppProfile], existingGlobal: [String]) -> [KeywordSuggestion] {
        let existingGlobalLower = Set(existingGlobal.map { $0.lowercased() })
        var seen = existingGlobalLower   // grows as we accept terms, so a term can't appear twice
        var out: [KeywordSuggestion] = []

        func accept(_ raw: [String: Any], profileID: UUID?, alreadyInProfile: Set<String>) {
            guard
                let term = (raw["term"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: ""),
                !term.isEmpty
            else { return }
            let key = term.lowercased()
            guard !seen.contains(key), !alreadyInProfile.contains(key) else { return }
            seen.insert(key)
            let reason = (raw["reason"] as? String) ?? ""
            out.append(KeywordSuggestion(term: term, reason: reason, profileID: profileID))
        }

        for item in (json["global"] as? [[String: Any]]) ?? [] {
            accept(item, profileID: nil, alreadyInProfile: [])
        }
        for group in (json["perApp"] as? [[String: Any]]) ?? [] {
            let name = group["profileName"] as? String
            let terms = (group["terms"] as? [[String: Any]]) ?? []
            // An unrecognised profile name (model drifted from the list it was given) still
            // carries a real suggestion — it just can't be pinned to a specific profile, so it
            // falls back to global rather than being silently dropped.
            guard let profile = profiles.first(where: { $0.displayName == name }) else {
                for item in terms { accept(item, profileID: nil, alreadyInProfile: []) }
                continue
            }
            let existingForProfile = Set(profile.transcriptionKeywords.map { $0.lowercased() })
            for item in terms {
                accept(item, profileID: profile.id, alreadyInProfile: existingForProfile)
            }
        }
        return out
    }

    #if DEBUG
    /// Cheap assert-based check for the dedupe logic — the one bit of real parsing here.
    static func selfCheck() {
        let profile = AppProfile(displayName: "TestApp", bundleID: "", instructions: "", keywords: "Existujúce\nRize")
        let json: [String: Any] = [
            "global": [
                ["term": "Nové", "reason": "r"],
                ["term": "rize", "reason": "duplicate of existing global, different case"]
            ],
            "perApp": [
                ["profileName": "TestApp", "terms": [
                    ["term": "Existujúce", "reason": "already in this profile"],
                    ["term": "ProfilNove", "reason": "r"]
                ]],
                ["profileName": "Neznámy", "terms": [["term": "PadloDoGlobal", "reason": "r"]]]
            ]
        ]
        let result = parse(json, profiles: [profile], existingGlobal: ["Rize"])
        let terms = Set(result.map(\.term))
        assert(terms.contains("Nové"), "nový globálny návrh musí prejsť")
        assert(!terms.contains("rize"), "variant existujúceho globálneho slova sa nesmie navrhnúť")
        assert(terms.contains("ProfilNove"), "nový profilový návrh musí prejsť")
        assert(!terms.contains("Existujúce"), "slovo už v profile sa nesmie navrhnúť znova")
        assert(result.first { $0.term == "PadloDoGlobal" }?.profileID == nil,
               "neznámy profil sa má priradiť ako globálny, nie zahodiť")
        AppLogger.log("[KeywordSuggestion] selfCheck OK")
    }
    #endif
}
