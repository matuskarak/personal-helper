#!/bin/bash
# The Keychain migration must never destroy a user's only API key: the plaintext UserDefaults
# copy may be deleted ONLY after the Keychain write verifiably stuck. This exercises the real
# Security framework via an isolated account name, then cleans up. Run: ./scripts/check-keychain.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/logger.swift" <<'EOF'
enum AppLogger { static func log(_ msg: String) { print(msg) } }
EOF

cat > "$TMP/check.swift" <<'EOF'
import Foundation

@main
struct Check {
    static func main() {
        let acct = "check-keychain-selftest"
        defer { KeychainStore.set(nil, for: acct); UserDefaults.standard.removeObject(forKey: acct) }

        // Round-trip.
        KeychainStore.set("sk-test-123", for: acct)
        assert(KeychainStore.string(for: acct) == "sk-test-123", "round-trip zlyhal")

        // Overwrite, not duplicate.
        KeychainStore.set("sk-test-456", for: acct)
        assert(KeychainStore.string(for: acct) == "sk-test-456", "prepis hodnoty zlyhal")

        // nil / empty deletes.
        KeychainStore.set(nil, for: acct)
        assert(KeychainStore.string(for: acct) == nil, "delete cez nil zlyhal")
        KeychainStore.set("x", for: acct); KeychainStore.set("", for: acct)
        assert(KeychainStore.string(for: acct) == nil, "delete cez prázdny string zlyhal")

        // Migration: legacy UserDefaults value moves to Keychain and the plaintext copy dies.
        UserDefaults.standard.set("legacy-key", forKey: acct)
        let migrated = KeychainStore.stringMigratingFromDefaults(account: acct)
        assert(migrated == "legacy-key", "migrácia nevrátila hodnotu")
        assert(KeychainStore.string(for: acct) == "legacy-key", "migrácia nezapísala do Keychain")
        assert(UserDefaults.standard.string(forKey: acct) == nil, "plaintext kópia prežila migráciu")

        // Second call is a plain read — no defaults resurrection.
        assert(KeychainStore.stringMigratingFromDefaults(account: acct) == "legacy-key", "idempotencia zlyhala")

        // Missing everywhere → empty string, no crash.
        KeychainStore.set(nil, for: acct)
        assert(KeychainStore.stringMigratingFromDefaults(account: acct) == "", "chýbajúci kľúč nevrátil prázdno")

        print("OK — KeychainStore round-trip aj migrácia z UserDefaults sedia")
    }
}
EOF
swiftc -o "$TMP/check" "$ROOT/Sources/OsobnyPomocnik/Engines/KeychainStore.swift" "$TMP/logger.swift" "$TMP/check.swift"
"$TMP/check"
