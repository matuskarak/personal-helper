#!/bin/bash
# Every action must have its OWN default shortcut. Two actions sharing one combo means the
# first match in HotkeyManager.handle() silently wins and the other action is unreachable —
# invisible in the UI, since both rows would just show the same combo. Run: ./scripts/check-shortcut-defaults.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/check.swift" <<'EOF'
import AppKit

@main
struct Check {
    @MainActor static func main() {
        var seen: [String: String] = [:]
        for action in ShortcutStore.Action.allCases {
            let combo = action.defaultShortcut.displayString
            if combo == "?" || combo.count < 2 {
                print("FAIL: \(action.rawValue) má nečitateľný default: \(combo)"); exit(1)
            }
            if let other = seen[combo] {
                print("FAIL: \(action.rawValue) a \(other) zdieľajú default \(combo)"); exit(1)
            }
            seen[combo] = action.rawValue
        }
        print("OK — \(seen.count) akcií, každá s vlastnou skratkou: "
              + seen.map { "\($0.value)=\($0.key)" }.sorted().joined(separator: ", "))
    }
}
EOF

# Shortcut.swift's sync() calls into HotkeyManager; stub it rather than dragging the whole
# app into the compile just to read a table of constants.
cat > "$TMP/stub.swift" <<'EOF'
import AppKit
@MainActor final class HotkeyManager {
    static let shared = HotkeyManager()
    func updateShortcuts(readText: [Shortcut], ocr: [Shortcut], dictateRealtime: [Shortcut],
                         dictateBatch: [Shortcut], smartStop: [Shortcut],
                         cancelDictation: [Shortcut], insertFromMemory: [Shortcut]) {}
}
EOF

swiftc -o "$TMP/check" "$TMP/stub.swift" \
    "$ROOT/Sources/OsobnyPomocnik/HotkeyManager/Shortcut.swift" "$TMP/check.swift"

"$TMP/check"
