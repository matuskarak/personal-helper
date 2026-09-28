import Foundation

/// Spoken formatting commands in Smart ("toto zvýrazni", "nový odsek", "odrážka"…).
///
/// A small model asked to find and remove such a command inside free speech kept it in the text
/// (2026-09-28: "Toto prosím ťa zvýrazni." ended up in the e-mail, bolded). Research (Notion →
/// Engine → Prieskum hlasových pokynov): nobody leaves this to the LLM alone. So:
/// 1. `mark` — the app flags candidate commands with ⟦…⟧ before the LLM sees the transcript,
/// 2. the LLM returns commands and content SEPARATELY (blocks/spans, see SmartRewriteEngine),
/// 3. `render` builds the formatted text in code, and `removeLeftovers` drops any command
///    phrase that still slipped into the content.
enum VoiceCommands {
    static let open: Character = "⟦", close: Character = "⟧"

    /// Standalone phrases — marked exactly.
    private static let phrases = [
        "zacni tucne", "zacni tucny", "koniec tucneho", "zacni zvyraznene", "koniec zvyrazneneho",
        "novy odsek", "novy riadok", "nova odrazka", "odrazka", "toto je nadpis",
    ]
    /// Stems that make a short clause a candidate ("toto prosím ťa zvýrazni", "daj to tučne").
    private static let clauseStems = #"\b(zvyrazn|tucn|zdorazn|vynechaj|vymaz|skrtni)"#
    private static let maxClauseWords = 8

    static func mark(_ text: String) -> String {
        let chars = Array(text)
        let folded = String(chars.map(fold))
        var marks: [Range<Int>] = []   // Character offsets, same in `text` and `folded`

        func offsets(_ r: NSRange) -> Range<Int>? {
            guard let sr = Range(r, in: folded) else { return nil }
            let lo = folded.distance(from: folded.startIndex, to: sr.lowerBound)
            return lo..<(lo + folded.distance(from: sr.lowerBound, to: sr.upperBound))
        }
        let ns = folded as NSString
        let all = NSRange(location: 0, length: ns.length)

        let phraseRx = try! NSRegularExpression(pattern: #"\b("# + phrases.joined(separator: "|") + #")\b"#)
        for m in phraseRx.matches(in: folded, range: all) {
            if let r = offsets(m.range) { marks.append(r) }
        }

        let clauseRx = try! NSRegularExpression(pattern: #"[^.,;!?\n]+"#)
        let stemRx = try! NSRegularExpression(pattern: clauseStems)
        for m in clauseRx.matches(in: folded, range: all) {
            let clause = ns.substring(with: m.range)
            let trimmed = clause.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  trimmed.split(separator: " ").count <= maxClauseWords,
                  stemRx.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) != nil,
                  var r = offsets(m.range)
            else { continue }
            let lead = clause.prefix { $0 == " " }.count, trail = clause.reversed().prefix { $0 == " " }.count
            r = (r.lowerBound + lead)..<(r.upperBound - trail)
            if !marks.contains(where: { $0.overlaps(r) }) { marks.append(r) }
        }

        var out = chars
        for r in marks.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            out.insert(close, at: r.upperBound)
            out.insert(open, at: r.lowerBound)
        }
        return String(out)
    }

    // MARK: - Model output → text

    struct Span { let text: String; let bold: Bool }
    struct Block { let type: String; let spans: [Span] }   // paragraph | heading | bullet | numbered

    static func parseBlocks(_ raw: Any?) -> [Block] {
        (raw as? [[String: Any]] ?? []).map { b in
            Block(type: b["type"] as? String ?? "paragraph",
                  spans: (b["spans"] as? [[String: Any]] ?? []).map {
                      Span(text: $0["text"] as? String ?? "", bold: $0["bold"] as? Bool ?? false)
                  })
        }
    }

    /// Code-side cleanup of what models get wrong regardless of the prompt (bench 2026-09-28):
    /// Markdown typed into spans ("- - odrážka", "**"), bold headings, "Nadpis:" colons, and
    /// sentences starting lowercase. Lowercase stays only right under a greeting ending in ",".
    static func tidy(_ blocks: [Block]) -> [Block] {
        var prev = ""
        return blocks.map { b in
            var spans = b.spans.map { s in
                // A line the model broke itself ("Vďaka.\nmartin") starts uppercase too.
                let t = s.text.replacingOccurrences(of: "**", with: "")
                    .split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                    .map { $0.offset == 0 ? String($0.element) : $0.element.prefix(1).uppercased() + $0.element.dropFirst() }
                    .joined(separator: "\n")
                return Span(text: t, bold: s.bold && b.type != "heading")
            }
            if var first = spans.first {
                var t = first.text.replacingOccurrences(of: #"^\s*([-*•]|#+|\d+[.)])\s+"#, with: "", options: .regularExpression)
                if (b.type == "paragraph" || b.type == "heading"), !prev.trimmingCharacters(in: .whitespaces).hasSuffix(","),
                   let i = t.firstIndex(where: { !$0.isWhitespace }) {
                    t.replaceSubrange(i...i, with: t[i].uppercased())
                }
                first = Span(text: t, bold: first.bold); spans[0] = first
            }
            if b.type == "heading", let last = spans.last {
                spans[spans.count - 1] = Span(text: last.text.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ":")), bold: last.bold)
            }
            prev = spans.map(\.text).joined()
            return Block(type: b.type, spans: spans)
        }
    }

    /// E-mail: a lone name after a short closing ("Ďakujem." / "Martin") belongs on the next
    /// line of the same paragraph, not in its own — models split it even when told not to.
    static func joinSignoff(_ blocks: [Block]) -> [Block] {
        guard blocks.count >= 2, blocks.suffix(2).allSatisfy({ $0.type == "paragraph" }) else { return blocks }
        let last = blocks[blocks.count - 1].spans.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let prev = blocks[blocks.count - 2]
        let prevWords = prev.spans.map(\.text).joined().split(separator: " ").count
        guard !last.contains("\n"), (1...3).contains(last.split(separator: " ").count),
              !".!?".contains(last.last ?? "."), prevWords <= 4 else { return blocks }
        let name = last.prefix(1).uppercased() + last.dropFirst()
        return blocks.dropLast(2) + [Block(type: "paragraph", spans: prev.spans + [Span(text: "\n" + name, bold: false)])]
    }

    /// Blocks → the Markdown subset RichText pastes. `plain` (AI chats, code): no bold, lists as text.
    static func render(_ blocks: [Block], plain: Bool) -> String {
        var parts: [String] = []
        var n = 0
        var prevList = false
        for b in blocks {
            let line = b.spans.map { s -> String in
                guard s.bold, !plain else { return s.text }
                let core = s.text.trimmingCharacters(in: .whitespaces)
                guard !core.isEmpty else { return s.text }
                let lead = s.text.prefix { $0 == " " }, trail = String(s.text.reversed().prefix { $0 == " " })
                return lead + "**" + core + "**" + trail
            }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let isList = b.type == "bullet" || b.type == "numbered"
            n = b.type == "numbered" ? n + 1 : 0
            let text: String
            switch b.type {
            case "heading":  text = plain ? line : "## " + line
            case "bullet":   text = "- " + line
            case "numbered": text = "\(n). " + line
            default:         text = line
            }
            parts.append((parts.isEmpty ? "" : (isList && prevList ? "\n" : "\n\n")) + text)
            prevList = isList
        }
        return parts.joined()
    }

    /// Safety net: a phrase the model itself called a command must not be in the content.
    static func removeLeftovers(_ text: String, commands: [String]) -> String {
        var out = text.filter { $0 != open && $0 != close }
        for phrase in commands where phrase.count > 3 {
            let p = NSRegularExpression.escapedPattern(for: phrase.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)))
            out = out.replacingOccurrences(of: #"\s*"# + p + #"[.,!]?"#, with: "",
                                           options: [.regularExpression, .caseInsensitive])
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lowercase + Slovak diacritics stripped, one Character in → one Character out.
    private static func fold(_ c: Character) -> Character {
        let lower = Character(c.lowercased())
        return foldMap[lower] ?? lower
    }
    private static let foldMap: [Character: Character] = Dictionary(uniqueKeysWithValues:
        zip("áäčďéěíĺľňóôŕřšťúůýž", "aacdeeillnoorrstuuyz"))

    // MARK: - Few-shot (user message, right before the transcript — research: nearer = weighed more)

    /// Topics deliberately far from real dictation (weather, a garden, a trip): with a price/e-mail
    /// example gpt-4o-mini copied "Cena bude 2 000 €." into a real e-mail and dropped the greeting
    /// (2026-09-28). The examples only show the MECHANICS.
    static let examples = """
    <priklady>
    Toto sú LEN ukážky mechaniky pokynov. Ich slová a obsah NIKDY nepoužívaj vo výsledku — výsledok \
    obsahuje výhradne text z <text_to_correct>, celý, od prvej po poslednú vetu.
    ⟦…⟧ = appka tu našla MOŽNÝ hlasový pokyn; ty rozhodni, či to pokyn naozaj je.
    A) „zajtra má pršať celý deň, ⟦toto zvýrazni⟧, dáždnik je v aute“ → voice_commands: \
    [{phrase: "toto zvýrazni", action: bold_previous, removed_from_text: true}], blocks: \
    paragraph [„Zajtra má pršať celý deň.“ bold=true, „ Dáždnik je v aute.“]
    B) „⟦v knihe bolo zvýraznené⟧ celé prvé leto“ → not_a_command (opis, nie príkaz) — text zostáva celý.
    C) „v záhrade treba ⟦odrážka⟧ pokosiť ⟦odrážka⟧ poliať ⟦nový odsek⟧ vďaka“ → blocks: paragraph \
    „V záhrade treba:“, bullet „pokosiť“, bullet „poliať“, paragraph „Vďaka.“
    F) „vlak ide o siedmej ⟦to je dôležité, zvýrazni to⟧“ → bold_previous: „Vlak ide o siedmej.“ bold=true — \
    „to je dôležité“ je súčasť pokynu, do textu nepatrí.
    G) „vlak mešká. bufet je zatvorený ⟦vymaž poslednú vetu⟧ uvidíme sa“ → voice_commands: [{phrase: "vymaž \
    poslednú vetu", action: omit, removed_from_text: true}], blocks: „Vlak mešká. Uvidíme sa.“ — veta PRED pokynom zmizne.
    D) „⟦začni tučné⟧ vlak ide o siedmej ⟦koniec tučného⟧ lístky mám“ → bold_range: „Vlak ide o siedmej.“ \
    bold=true, „ Lístky mám.“
    E) prompt pre AI: „napíš mi teda nejakú krátku báseň o jeseni a nech sa to rýmuje“ → blocks: paragraph \
    „Napíš krátku rýmovanú báseň o jeseni.“ — výsledok je STÁLE zadanie, nikdy nie báseň samotná.
    Pravidlá: bold_previous = posledná veta alebo fráza PRED pokynom. Text pokynu NIKDY nepatrí do blocks. \
    Formátovanie vyjadri LEN cez blocks a bold — nepíš Markdown znaky (** # -).
    </priklady>
    """

    /// Share of the transcript's content words (4+ letters, pokyny excluded) found in the result.
    /// Low = the model dropped or replaced content — the caller falls back to the raw text.
    /// Compared by the first 5 letters: Slovak inflects ("priateľské" → "priateľským"), and a
    /// prompt rewrite changes endings a lot (whole-word matching kept only 37 % of a fine prompt).
    // ponytail: prefix stem, a real stemmer only if the guard misfires again
    static func coverage(raw: String, result: String, commands: [String]) -> Double {
        func words(_ s: String) -> [String] {
            String(Array(s).map(fold)).split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 }
        }
        // Fillers are meant to go (Smart tone) — not counted as lost content.
        let skip = Set(commands.flatMap(words)).union(DictationQualityEngine.fillerWords)
        let src = words(raw).filter { !skip.contains($0) }.map { $0.prefix(5) }
        guard !src.isEmpty else { return 1 }
        let out = Set(words(result).map { $0.prefix(5) })
        return Double(src.filter(out.contains).count) / Double(src.count)
    }

    #if DEBUG
    static func selfCheck() {
        assert(mark("Cena bude 2000 eur, toto prosím ťa zvýrazni, pošli to.")
               == "Cena bude 2000 eur, ⟦toto prosím ťa zvýrazni⟧, pošli to.", "clause command")
        assert(mark("kúp mlieko nová odrážka chlieb").contains("⟦nová odrážka⟧"), "phrase command")
        assert(mark("Dnes som bol v meste a kúpil som mlieko.") == "Dnes som bol v meste a kúpil som mlieko.", "no false mark")
        let blocks = [Block(type: "paragraph", spans: [Span(text: "Cena je 2 000 €.", bold: true), Span(text: " Pošli to.", bold: false)]),
                      Block(type: "bullet", spans: [Span(text: "a", bold: false)]),
                      Block(type: "bullet", spans: [Span(text: "b", bold: false)])]
        assert(render(blocks, plain: false) == "**Cena je 2 000 €.** Pošli to.\n\n- a\n- b", "render")
        assert(render(blocks, plain: true) == "Cena je 2 000 €. Pošli to.\n\n- a\n- b", "render plain")
        let messy = tidy([Block(type: "heading", spans: [Span(text: "**úlohy:**", bold: true)]),
                          Block(type: "bullet", spans: [Span(text: "- web", bold: false)]),
                          Block(type: "paragraph", spans: [Span(text: "ahoj Peťo,", bold: false)]),
                          Block(type: "paragraph", spans: [Span(text: "posielam návrh.", bold: false)])])
        assert(render(messy, plain: false) == "## Úlohy\n\n- web\n\nAhoj Peťo,\n\nposielam návrh.", "tidy")
        let signed = joinSignoff([Block(type: "paragraph", spans: [Span(text: "Vďaka.", bold: false)]),
                                  Block(type: "paragraph", spans: [Span(text: "martin", bold: false)])])
        assert(render(signed, plain: false) == "Vďaka.\nMartin", "signoff")
        assert(render(tidy([Block(type: "paragraph", spans: [Span(text: "Vďaka.\nmartin", bold: false)])]), plain: false)
               == "Vďaka.\nMartin", "line capital")
        assert(coverage(raw: "Čau Peťo, posielam ti návrh spolupráce, tie peniaze zvýrazni",
                        result: "**Cena bude 2 000 €.**", commands: ["tie peniaze zvýrazni"]) < 0.5, "lost greeting")
        assert(coverage(raw: "ahoj peťo posielam návrh", result: "Ahoj Peťo,\n\nposielam návrh.", commands: []) == 1, "kept")
        assert(coverage(raw: "priateľské články", result: "Priateľským článkom", commands: []) == 1, "inflection")
        assert(removeLeftovers("Cena. Toto prosím ťa zvýrazni. Pošli.", commands: ["toto prosím ťa zvýrazni"]) == "Cena. Pošli.", "leftover")
        AppLogger.log("[VoiceCommands] selfCheck OK")
    }
    #endif
}
