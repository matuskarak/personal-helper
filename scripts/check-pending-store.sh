#!/bin/bash
# Self-check for PendingDictationStore — the safety net that keeps a recording alive when
# its transcription request fails. If this breaks, failed dictations get silently lost again,
# which is the exact bug it was built to fix.
#
# Compiles the real shipped source (not a copy) against a stub logger and exercises the
# save → read → remove roundtrip. Run: ./scripts/check-pending-store.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/stub.swift" <<'EOF'
import Foundation
enum AppLogger { static func log(_ m: String) { FileHandle.standardError.write("[log] \(m)\n".data(using: .utf8)!) } }
EOF

cat > "$TMP/check.swift" <<'EOF'
import Foundation

@main
struct Check {
    @MainActor static func main() {
        let store = PendingDictationStore.shared
        let before = store.pending.count

        let payload = Data(repeating: 0xAB, count: 4096)
        guard let item = store.save(wav: payload, mode: "batch", appName: "TestApp",
                                    bundleID: "sk.test", seconds: 7) else {
            print("FAIL: save() vrátil nil"); exit(1)
        }
        assert(store.pending.count == before + 1, "položka nepribudla")
        assert(FileManager.default.fileExists(atPath: store.wavURL(for: item.id).path), "WAV nie je na disku")
        assert(store.wav(for: item) == payload, "WAV sa načítal poškodený")
        assert(item.displayName.contains("TestApp"), "displayName neobsahuje appku: \(item.displayName)")

        // remove() must clear the file AND the entry — a leftover file would resurrect the
        // item on the next launch and the user would keep retrying a finished dictation.
        store.remove(item)
        assert(store.pending.count == before, "položka sa neodstránila")
        assert(!FileManager.default.fileExists(atPath: store.wavURL(for: item.id).path), "WAV ostal na disku")

        print("OK — save/read/remove roundtrip prešiel (\(before) existujúcich položiek nedotknutých)")
    }
}
EOF

swiftc -o "$TMP/check" \
    "$TMP/stub.swift" \
    "$ROOT/Sources/OsobnyPomocnik/Engines/PendingDictationStore.swift" \
    "$TMP/check.swift"

"$TMP/check"
