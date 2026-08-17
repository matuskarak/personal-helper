import Foundation

/// Light pre-processing applied before text reaches the TTS engine (system or Google Cloud).
/// Neither engine reliably speaks long unbroken digit runs, glued units, or bare currency/percent
/// symbols in Slovak — this doesn't do full number-to-words grammar (declension of Slovak
/// numerals is too irregular to get right in general), it just reshapes the text into a form
/// both engines already read correctly on their own.
enum SpeechTextNormalizer {
    static func normalize(_ text: String, language: String) -> String {
        guard language.hasPrefix("sk") else { return text }
        var t = text

        // "12.8.2026" / "12.8.2026." -> "12. 8. 2026" so it isn't parsed as a decimal chain.
        t = t.replacingOccurrences(of: #"(\d{1,2})\.\s?(\d{1,2})\.\s?(\d{4})"#,
                                    with: "$1. $2. $3", options: .regularExpression)

        // Bare currency/percent symbols glued to a number.
        t = t.replacingOccurrences(of: #"(\d)\s?€"#, with: "$1 eur", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(\d)\s?\$"#, with: "$1 dolárov", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(\d)\s?%"#, with: "$1 percent", options: .regularExpression)

        // Units glued straight to a number: "12kg" -> "12 kg".
        t = t.replacingOccurrences(of: #"(\d)(kg|km/h|km|cm|mm|kč|Kč)\b"#,
                                    with: "$1 $2", options: .regularExpression)

        // Long unbroken digit runs (phone numbers, IDs, big totals) get grouped in 3s —
        // "1250000" -> "1 250 000", "0905123456" -> "090 512 345 6" — both engines read a
        // grouped number as a sequence of smaller numbers instead of one giant value.
        t = groupLongDigitRuns(t)

        return t
    }

    private static func groupLongDigitRuns(_ text: String) -> String {
        var result = ""
        var buffer = ""
        for ch in text {
            if ch.isNumber {
                buffer.append(ch)
            } else {
                result += spaceIfLong(buffer)
                buffer = ""
                result.append(ch)
            }
        }
        result += spaceIfLong(buffer)
        return result
    }

    private static func spaceIfLong(_ digits: String) -> String {
        guard digits.count >= 7 else { return digits }
        // Group from the right (thousands-separator style), not the left — "1250000"
        // must read as "1 250 000", not "125 000 0".
        let reversed = String(digits.reversed())
        var grouped = ""
        for (i, ch) in reversed.enumerated() {
            if i > 0 && i % 3 == 0 { grouped.append(" ") }
            grouped.append(ch)
        }
        return String(grouped.reversed())
    }
}
