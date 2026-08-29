import Foundation

/// Word-level comparison of two transcripts of the SAME audio, for the shadow A/B in
/// Nastavenia. Kept separate from the UI so scripts/check-transcript-diff.sh can exercise it.
enum TranscriptDiff {
    /// Punctuation and capitalisation differ between providers on nearly every sentence and
    /// say nothing about who heard the words right, so both are normalised away. Diacritics
    /// are NOT — "ostrú" vs "ostru" is exactly the kind of mistake this is meant to catch.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".-")) }
            .filter { !$0.isEmpty }
    }

    /// 1.0 = identical wording, 0.0 = nothing in common. Symmetric (Sørensen–Dice on the
    /// aligned words), so it doesn't matter which transcript is passed first.
    static func agreement(_ a: String, _ b: String) -> Double {
        let (wa, wb) = (words(a), words(b))
        guard !wa.isEmpty || !wb.isEmpty else { return 1 }
        guard !wa.isEmpty, !wb.isEmpty else { return 0 }
        let removed = wb.difference(from: wa).removals.count   // words of `wa` not aligned
        let common = wa.count - removed
        return max(0, 2 * Double(common) / Double(wa.count + wb.count))
    }

    /// The words each side has that the other doesn't — the actual content of the comparison.
    /// Order follows the transcript so a reader can find them in context.
    static func differences(_ a: String, _ b: String) -> (onlyA: [String], onlyB: [String]) {
        let diff = words(b).difference(from: words(a))
        var onlyA: [String] = [], onlyB: [String] = []
        for change in diff {
            switch change {
            case .remove(_, let word, _): onlyA.append(word)   // in a, missing from b
            case .insert(_, let word, _): onlyB.append(word)   // in b, missing from a
            }
        }
        return (onlyA, onlyB)
    }
}
