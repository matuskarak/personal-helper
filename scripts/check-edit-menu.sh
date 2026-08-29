#!/bin/bash
# Text fields in this app can only be typed into, never pasted into, unless an Edit menu
# exists: macOS matches ⌘C/⌘V/⌘X/⌘A/⌘Z against NSApp.mainMenu's key equivalents, and an
# .accessory app that sets no main menu gets none of them. The app shipped that way for its
# whole life and it was invisible — nothing errors, the keystroke just does nothing.
# Run: ./scripts/check-edit-menu.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/check.swift" <<'EOF'
import AppKit

@main
struct Check {
    @MainActor static func main() {
        let menu = NSMenu.osobnyPomocnikMenu()
        // Flattened (key, modifiers, action) over every submenu.
        let items = menu.items.compactMap(\.submenu).flatMap(\.items)

        func requireItem(_ key: String, _ mods: NSEvent.ModifierFlags, _ action: String) {
            let found = items.contains {
                $0.keyEquivalent == key && $0.keyEquivalentModifierMask == mods
                    && $0.action.map(NSStringFromSelector) == action
            }
            if !found {
                print("FAIL: chýba položka \(action) na \(mods.contains(.shift) ? "⇧" : "")⌘\(key.uppercased())")
                exit(1)
            }
        }

        // Without these four, no field in the app can be pasted into or selected.
        requireItem("c", .command, "copy:")
        requireItem("v", .command, "paste:")
        requireItem("x", .command, "cut:")
        requireItem("a", .command, "selectAll:")
        requireItem("z", .command, "undo:")
        requireItem("z", [.command, .shift], "redo:")
        requireItem("q", .command, "terminate:")

        // A duplicate key equivalent means one of the two silently never fires.
        var seen = Set<String>()
        for item in items where !item.keyEquivalent.isEmpty {
            let combo = "\(item.keyEquivalentModifierMask.rawValue)-\(item.keyEquivalent)"
            if !seen.insert(combo).inserted {
                print("FAIL: dve položky menu zdieľajú skratku \(item.keyEquivalent)"); exit(1)
            }
        }

        print("OK — Edit menu má \(items.count) položiek, vkladanie aj výber textu fungujú")
    }
}
EOF

swiftc -o "$TMP/check" "$ROOT/Sources/OsobnyPomocnik/UI/AppMainMenu.swift" "$TMP/check.swift"
"$TMP/check"
