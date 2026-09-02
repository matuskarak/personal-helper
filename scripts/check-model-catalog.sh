#!/bin/bash
# models.json is served remotely and consumed by a strict decoder — a malformed edit would
# silently leave every install on its cached/builtin catalog. Validate the JSON and that the
# Swift decoder accepts it verbatim. Run: ./scripts/check-model-catalog.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

python3 -m json.tool "$ROOT/models.json" >/dev/null

# Extract just the catalog types (the RemoteConfig class needs half the app to compile).
awk '/^struct ModelInfo/,0' "$ROOT/Sources/OsobnyPomocnik/Engines/RemoteConfig.swift" > "$TMP/types.swift"

cat > "$TMP/check.swift" <<EOF
import Foundation

@main
struct Check {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "$ROOT/models.json"))
        let cat = try JSONDecoder().decode(ModelCatalog.self, from: data)
        assert(!cat.batchModels.isEmpty, "prázdny katalóg")
        assert(cat.batchModels.contains { \$0.available }, "žiadny dostupný model")
        for m in cat.batchModels {
            assert(["openai", "gemini"].contains(m.provider), "neznámy provider '\(m.provider)' pre \(m.id)")
            assert(m.usdPerMinute > 0 && m.usdPerMinute < 0.1, "podozrivá cena \(m.usdPerMinute) pre \(m.id)")
        }
        // The builtin fallback must satisfy the same invariants — it's what offline installs run on.
        assert(!ModelCatalog.builtin.batchModels.isEmpty)
        assert(ModelCatalog.builtin.info(for: "gpt-transcribe")?.provider == "openai")
        assert(ModelCatalog.builtin.info(for: "gemini-3.5-transcribe")?.provider == "gemini")
        print("OK — models.json aj vstavaný katalóg dekódujú a dávajú zmysel")
    }
}
EOF
swiftc -o "$TMP/check" "$TMP/types.swift" "$TMP/check.swift"
"$TMP/check"
