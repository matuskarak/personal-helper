#!/bin/bash
# The shadow A/B is only worth its doubled API bill if the comparison is right. The trap is
# direction: CollectionDifference reports removals against the SOURCE, so it is easy to ship a
# card that attributes every mistake to the wrong model. Run: ./scripts/check-transcript-diff.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/check.swift" <<'EOF'
import Foundation

@main
struct Check {
    static func main() {
        func approx(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.001 }

        // Identical text, and text differing only in punctuation/case, must both score 1.
        assert(approx(TranscriptDiff.agreement("Ahoj svet", "Ahoj svet"), 1), "zhodné texty nie sú 100 %")
        assert(approx(TranscriptDiff.agreement("Ahoj, svet!", "ahoj svet"), 1), "interpunkcia ovplyvnila zhodu")
        // Diacritics must count as a difference — that is the mistake worth catching.
        assert(TranscriptDiff.agreement("ostrú doménu", "ostru domenu") < 0.5, "diakritika sa ignoruje")
        assert(TranscriptDiff.agreement("ahoj", "úplne iné slová") < 0.4, "nesúvisiace texty majú vysokú zhodu")

        // Symmetry: the card shows one number regardless of argument order.
        let (x, y) = ("prepis cez Elementor kit", "prepis cez elementor kid dnes")
        assert(approx(TranscriptDiff.agreement(x, y), TranscriptDiff.agreement(y, x)), "zhoda nie je symetrická")

        // Direction: onlyA holds what the FIRST argument said, onlyB the second. Swapping these
        // would blame each model for the other's mistake — silently and plausibly.
        let d = TranscriptDiff.differences("venoval som sa ČUBP", "venoval som sa ČOBP")
        assert(d.onlyA == ["čubp"], "onlyA nesedí: \(d.onlyA)")
        assert(d.onlyB == ["čobp"], "onlyB nesedí: \(d.onlyB)")

        assert(TranscriptDiff.differences("a b", "a b") == ([], []), "zhodné texty hlásia rozdiel")
        assert(approx(TranscriptDiff.agreement("", ""), 1), "dva prázdne texty nie sú zhodné")
        assert(approx(TranscriptDiff.agreement("niečo", ""), 0), "prázdny oproti neprázdnemu nie je 0")

        print("OK — porovnávanie prepisov sedí vrátane smeru rozdielov")
    }
}
EOF
swiftc -o "$TMP/check" "$ROOT/Sources/OsobnyPomocnik/Engines/TranscriptDiff.swift" "$TMP/check.swift"
"$TMP/check"
