#!/bin/bash
# Self-check for the Gemini request/response shaping. Two things break silently here:
# a malformed body (Google answers 400 and the dictation looks like a network failure), and
# a response walk that folds in per-word `annotations` — which returns the whole transcript
# twice, once as a sentence and once word by word, and reads as a model bug, not a parser bug.
# Compiles the real shipped source. Run: ./scripts/check-gemini-transcription.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/check.swift" <<'EOF'
import Foundation

@main
struct Check {
    static func main() throws {
        // --- request body
        let body = try GeminiTranscription.requestBody(
            base64WAV: "AAAA", model: "gemini-3.5-transcribe", keywords: ["Elementor", "carousel"])
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        assert(json["model"] as? String == "gemini-3.5-transcribe", "chýba model")
        let input = (json["input"] as! [[String: Any]])[0]
        assert(input["type"] as? String == "audio" && input["data"] as? String == "AAAA",
               "audio sa neposiela inline")
        let cfg = (json["generation_config"] as! [String: Any])["transcription_config"] as! [String: Any]
        assert(cfg["language_codes"] as? [String] == ["sk-SK"], "chýba sk-SK")
        assert(cfg["custom_vocabulary"] as? [String] == ["Elementor", "carousel"],
               "kľúčové slová sa neposielajú ako custom_vocabulary — celý dôvod tejto integrácie")
        assert((cfg["mode"] as! [String: Any])["type"] as? String == "verbatim", "mode nie je verbatim")

        // Keywords are optional; an empty list must omit the field, not send [].
        let bare = try GeminiTranscription.requestBody(base64WAV: "AAAA", model: "m", keywords: [])
        let bareCfg = ((try JSONSerialization.jsonObject(with: bare) as! [String: Any])["generation_config"]
                       as! [String: Any])["transcription_config"] as! [String: Any]
        assert(bareCfg["custom_vocabulary"] == nil, "prázdny slovník sa nemá posielať")

        // --- response parsing
        func parse(_ s: String) -> String? { GeminiTranscription.transcript(from: s.data(using: .utf8)!) }

        assert(parse(#"{"output_text":"ahoj svet"}"#) == "ahoj svet", "output_text sa nečíta")

        // The shape that matters: annotations carry one entry per word. Reading them too
        // would return "ahoj svetahojsvet".
        let withAnnotations = #"""
        {"steps":[{"content":[{"text":"ahoj svet","annotations":[
            {"type":"word_info","text":"ahoj"},{"type":"word_info","text":"svet"}]}]}]}
        """#
        assert(parse(withAnnotations) == "ahoj svet", "parser počíta anotácie dvakrát: \(parse(withAnnotations) ?? "nil")")

        assert(parse(#"{"steps":[{"content":[{"text":"a "},{"text":"b"}]}]}"#) == "a b",
               "viac častí sa nespája")
        assert(parse(#"{"steps":[]}"#) == nil, "prázdna odpoveď musí byť nil, nie \"\"")
        assert(parse(#"{"output_text":""}"#) == nil, "prázdny output_text musí byť nil")
        assert(parse("nie json") == nil, "nevalidný JSON musí byť nil")

        print("OK — telo requestu aj parsovanie odpovede sedia")
    }
}
EOF

swiftc -o "$TMP/check" "$ROOT/Sources/OsobnyPomocnik/Engines/GeminiTranscription.swift" "$TMP/check.swift"
"$TMP/check"
