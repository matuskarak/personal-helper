#!/bin/bash
# Full snapshot of the live install: UserDefaults, Application Support (history, pending,
# screenshots), logs, AND the three API keys from the Keychain. The keys make this the one
# backup that can bring an install back completely — which is also why it lives OUTSIDE the
# repo (public) in ~/Library with 600 permissions, never in git.
#
# Run:     ./scripts/backup-settings.sh
# Restore: ./scripts/reset-fresh-install.sh --restore   (uses the newest backup)
set -euo pipefail
BUNDLE_ID="sk.matuskarak.osobny-pomocnik"
APP_SUPPORT="$HOME/Library/Application Support/OsobnyPomocnik"
LOGS="$HOME/Library/Logs/OsobnyPomocnik"
BACKUP_ROOT="$HOME/Library/Application Support/OsobnyPomocnik-zalohy"
STAMP="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STAMP"; chmod 700 "$BACKUP_ROOT" "$STAMP"

echo "💾 Záloha → $STAMP"
defaults export "$BUNDLE_ID" "$STAMP/defaults.plist" && echo "   ✓ nastavenia (defaults.plist)"
[ -d "$APP_SUPPORT" ] && cp -R "$APP_SUPPORT" "$STAMP/OsobnyPomocnik" && echo "   ✓ história a dáta"
[ -d "$LOGS" ] && cp -R "$LOGS" "$STAMP/Logs" && echo "   ✓ logy"

# Keys: one plist, owner-read-only. `security -w` may prompt once per key — click Always Allow.
KEYS="$STAMP/keys.plist"
python3 - "$BUNDLE_ID" "$KEYS" <<'PY'
import plistlib, subprocess, sys
bundle, out = sys.argv[1], sys.argv[2]
keys = {}
for acct in ["openai.dictation.key", "gemini.dictation.key", "google.api.key"]:
    r = subprocess.run(["security", "find-generic-password", "-s", bundle, "-a", acct, "-w"],
                       capture_output=True, text=True)
    if r.returncode == 0 and r.stdout.strip():
        keys[acct] = r.stdout.strip()
plistlib.dump(keys, open(out, "wb"))
print(f"   ✓ API kľúče: {len(keys)}/3 ({', '.join(k.split('.')[0] for k in keys)})")
PY
chmod 600 "$KEYS"

echo ""
echo "✅ Hotovo. Obnova:  ./scripts/reset-fresh-install.sh --restore"
ls -1 "$BACKUP_ROOT" | tail -3 | sed 's/^/   záloha: /'
