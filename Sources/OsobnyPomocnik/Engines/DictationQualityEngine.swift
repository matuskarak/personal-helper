import Foundation

/// Purely local, zero-cost analysis of a finished dictation — no network, no state.
/// Backs the "Kvalita" tab: shows the user how they actually speak so they can improve.
///
/// ponytail: deliberately no composite 0–100 score. Local metrics can count filler
/// words and measure pace, but they say nothing about whether the intent was clear —
/// a made-up score would be false precision. Honest numbers with published thresholds
/// instead; a real score belongs to the AI layer (phase 2).
struct DictationMetrics: Codable, Equatable {
    var wordCount = 0
    var fillers: [String: Int] = [:]   // filler word → occurrences
    var fillerCount = 0
    var wordsPerMinute = 0
    var avgSentenceWords = 0
    var repeatedSentenceStarts = 0
    /// Normalized word-level edit distance between the raw transcript and the Smart
    /// rewrite (0…1). Only set when Smart diktovanie ran. High = the AI had to fix a
    /// lot, which is the cheapest quality signal available — it needs no extra API call.
    var rewriteDistanceRatio: Double?

    init() {}

    // ponytail: same reason as the two stores — phase 2 will add fields here (AI score,
    // clarity rating). Without this, one added field makes every stored entry's metrics
    // decode as nil and the whole Kvalita history goes blank.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wordCount              = try c.decodeIfPresent(Int.self, forKey: .wordCount) ?? 0
        fillers                = try c.decodeIfPresent([String: Int].self, forKey: .fillers) ?? [:]
        fillerCount            = try c.decodeIfPresent(Int.self, forKey: .fillerCount) ?? 0
        wordsPerMinute         = try c.decodeIfPresent(Int.self, forKey: .wordsPerMinute) ?? 0
        avgSentenceWords       = try c.decodeIfPresent(Int.self, forKey: .avgSentenceWords) ?? 0
        repeatedSentenceStarts = try c.decodeIfPresent(Int.self, forKey: .repeatedSentenceStarts) ?? 0
        rewriteDistanceRatio   = try c.decodeIfPresent(Double.self, forKey: .rewriteDistanceRatio)
    }

    /// Fillers per minute — the comparable rate. Research puts ≤5/min in acceptable range.
    var fillersPerMinute: Double {
        guard wordsPerMinute > 0, wordCount > 0 else { return 0 }
        let minutes = Double(wordCount) / Double(wordsPerMinute)
        return minutes > 0 ? Double(fillerCount) / minutes : 0
    }
}

enum DictationQualityEngine {

    // MARK: - Filler lexicon

    /// SK + EN fillers. Stored diacritic-free and lowercased because that's the form
    /// `normalizeWords` produces — "akože" only ever matches as "akoze".
    ///
    /// ponytail: intentionally excludes "no", "nejako" and "jednoducho" even though the
    /// original brainstorm listed some of them — they're ordinary Slovak content words far
    /// more often than they're fillers, and false positives would make the whole tab
    /// untrustworthy. Under-report rather than cry wolf.
    static let fillerWords: Set<String> = [
        // hesitation sounds
        "eee", "eeee", "emm", "hmm", "mmm", "aaa",
        // slovak filler words
        "vlastne", "akoze", "proste", "teda", "takze", "jakoby", "vies",
        // english
        "um", "uh", "uhm", "erm", "like", "actually", "basically", "literally"
    ]

    // MARK: - Analysis

    static func analyze(text: String, rewritten: String? = nil, seconds: Int) -> DictationMetrics {
        var m = DictationMetrics()

        let words = normalizeWords(text)
        m.wordCount = words.count
        guard !words.isEmpty else { return m }

        for word in words where fillerWords.contains(word) {
            m.fillers[word, default: 0] += 1
        }
        m.fillerCount = m.fillers.values.reduce(0, +)

        if seconds > 0 {
            m.wordsPerMinute = Int((Double(words.count) / Double(seconds) * 60).rounded())
        }

        let sentences = splitSentences(text)
        if !sentences.isEmpty {
            let counts = sentences.map { normalizeWords($0).count }.filter { $0 > 0 }
            if !counts.isEmpty {
                m.avgSentenceWords = Int((Double(counts.reduce(0, +)) / Double(counts.count)).rounded())
            }
            m.repeatedSentenceStarts = countRepeatedStarts(sentences)
        }

        // Only meaningful when the rewrite actually produced something different.
        if let rewritten, !rewritten.isEmpty {
            let rw = normalizeWords(rewritten)
            if !rw.isEmpty {
                let distance = wordLevenshtein(words, rw)
                m.rewriteDistanceRatio = min(1, Double(distance) / Double(max(words.count, rw.count)))
            }
        }

        return m
    }

    // MARK: - Text helpers

    /// Lowercased, diacritic-folded, punctuation-stripped word list. Shared with
    /// MicTestEngine's transcript-accuracy check so there's one normalizer, not two.
    static func normalizeWords(_ s: String) -> [String] {
        s.lowercased()
         .folding(options: .diacriticInsensitive, locale: Locale(identifier: "sk"))
         .components(separatedBy: CharacterSet.alphanumerics.inverted)
         .filter { !$0.isEmpty }
    }

    static func wordLevenshtein(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var dp = Array(0...b.count)
        for i in 1...a.count {
            var prev = dp[0]
            dp[0] = i
            for j in 1...b.count {
                let temp = dp[j]
                dp[j] = a[i - 1] == b[j - 1] ? prev : 1 + min(prev, dp[j], dp[j - 1])
                prev = temp
            }
        }
        return dp[b.count]
    }

    private static func splitSentences(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// How many sentences open with the same first two words as an earlier one —
    /// the audible tic of restarting a thought the same way over and over.
    private static func countRepeatedStarts(_ sentences: [String]) -> Int {
        var seen: Set<String> = []
        var repeats = 0
        for sentence in sentences {
            let words = normalizeWords(sentence)
            guard words.count >= 2 else { continue }
            let opener = words[0] + " " + words[1]
            if seen.contains(opener) { repeats += 1 } else { seen.insert(opener) }
        }
        return repeats
    }

    // MARK: - Thresholds (shown in the Kvalita tab)

    enum Rating { case good, fair, poor }

    /// ≤5 disfluencies/min is broadly considered acceptable in speech research.
    static func fillerRating(perMinute: Double) -> Rating {
        if perMinute <= 5 { return .good }
        if perMinute <= 10 { return .fair }
        return .poor
    }

    /// Too slow wastes the user's time; too fast measurably hurts transcription accuracy.
    static func paceRating(wpm: Int) -> Rating {
        if wpm == 0 { return .fair }
        if wpm < 100 { return .fair }
        if wpm <= 170 { return .good }
        if wpm <= 200 { return .fair }
        return .poor
    }

    // MARK: - Self-check

    /// ponytail: the filler matcher has real edge cases (substring vs whole word,
    /// diacritics, casing) and the package has no test target — one assert-based
    /// check beats standing up a whole test target for a single pure function.
    static func selfCheck() {
        // whole-word matching only: "notebook"/"nozes" must not trip the "no" family,
        // and "television" must not match "like"
        let trap = analyze(text: "Notebook a televizor su nove.", seconds: 6)
        assert(trap.fillerCount == 0, "substring false positive: \(trap.fillers)")

        // diacritics folded + case-insensitive: Akože / TAKŽE / vlastne all count
        let sk = analyze(text: "Akože TAKŽE vlastne to proste funguje.", seconds: 12)
        assert(sk.fillerCount == 4, "expected 4 SK fillers, got \(sk.fillerCount): \(sk.fillers)")

        // repeated counting of the same filler
        let dupes = analyze(text: "Proste to proste proste je tak.", seconds: 6)
        assert(dupes.fillers["proste"] == 3, "expected proste×3, got \(dupes.fillers)")

        // WPM: 10 words in 30 s = 20 wpm
        let pace = analyze(text: "jeden dva tri styri pat sest sedem osem devat desat", seconds: 30)
        assert(pace.wordCount == 10 && pace.wordsPerMinute == 20,
               "expected 10 words @20wpm, got \(pace.wordCount) @\(pace.wordsPerMinute)")

        // repeated sentence openers: "chcem aby" twice → 1 repeat
        let starts = analyze(text: "Chcem aby si to spravil. Chcem aby to bolo rychle. Potom to posli.", seconds: 15)
        assert(starts.repeatedSentenceStarts == 1,
               "expected 1 repeated opener, got \(starts.repeatedSentenceStarts)")

        // identical rewrite = nothing to fix; a full replacement = ratio 1
        let same = analyze(text: "toto je text", rewritten: "toto je text", seconds: 5)
        assert(same.rewriteDistanceRatio == 0, "identical rewrite should be 0, got \(same.rewriteDistanceRatio ?? -1)")
        let diff = analyze(text: "aaa bbb ccc", rewritten: "xxx yyy zzz", seconds: 5)
        assert(diff.rewriteDistanceRatio == 1, "full rewrite should be 1, got \(diff.rewriteDistanceRatio ?? -1)")

        // no rewrite supplied → stays nil rather than a misleading 0
        let none = analyze(text: "toto je text", seconds: 5)
        assert(none.rewriteDistanceRatio == nil, "missing rewrite must stay nil")

        // empty input must not divide by zero
        let empty = analyze(text: "", seconds: 0)
        assert(empty.wordCount == 0 && empty.fillersPerMinute == 0, "empty input must be inert")

        AppLogger.log("[DictationQualityEngine] selfCheck OK")
    }
}
