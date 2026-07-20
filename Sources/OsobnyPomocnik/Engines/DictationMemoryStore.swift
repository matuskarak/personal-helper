import Observation

/// Single-slot fallback memory for dictated text that couldn't be auto-inserted
/// (e.g. no editable field was focused when dictation stopped). Retrieved via a
/// dedicated keyboard shortcut so nothing dictated is ever silently lost.
@Observable
@MainActor
final class DictationMemoryStore {
    static let shared = DictationMemoryStore()
    private init() {}

    private(set) var savedText: String?

    func store(_ text: String) {
        savedText = text
    }

    /// Removes and returns the stored text (one-shot retrieval).
    func consume() -> String? {
        let t = savedText
        savedText = nil
        return t
    }
}
