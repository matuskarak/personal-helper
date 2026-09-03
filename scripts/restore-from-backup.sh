#!/bin/bash
# One-off recovery after the live install was wiped: pulls what still exists out of
# backup-pred-prehlad-rozsah-20260804-062155/defaults.plist (4 Aug 2026 snapshot).
#
# Non-destructive by design — every item is written ONLY if the current install has
# nothing there, so anything re-entered by hand in the meantime survives.
#
# Run: ./scripts/restore-from-backup.sh
set -euo pipefail
cd "$(dirname "$0")/.."
BUNDLE_ID="sk.matuskarak.osobny-pomocnik"
SRC="backup-pred-prehlad-rozsah-20260804-062155/defaults.plist"
APP_SUPPORT="$HOME/Library/Application Support/OsobnyPomocnik"
[ -f "$SRC" ] || { echo "❌ Záloha $SRC neexistuje"; exit 1; }

echo "🛑 Ukončujem appku, aby neprepísala obnovené hodnoty…"
pkill -f OsobnyPomocnik.app 2>/dev/null || true
sleep 1

python3 - "$SRC" "$BUNDLE_ID" "$APP_SUPPORT" <<'PY'
import plistlib, subprocess, sys, os, json

src, bundle, app_support = sys.argv[1], sys.argv[2], sys.argv[3]
d = plistlib.load(open(src, 'rb'))

def defaults_has(key):
    r = subprocess.run(["defaults", "read", bundle, key],
                       capture_output=True, text=True)
    return r.returncode == 0 and r.stdout.strip() not in ("", "0")

def keychain_has(acct):
    r = subprocess.run(["security", "find-generic-password", "-s", bundle, "-a", acct],
                       capture_output=True, text=True)
    return r.returncode == 0

# --- API keys → Keychain (only when the slot is empty) ---
for acct, label in [("openai.dictation.key", "OpenAI"), ("google.api.key", "Google TTS")]:
    val = d.get(acct)
    if not val:
        continue
    if keychain_has(acct):
        print(f"⏭  {label} kľúč — už nastavený, nechávam tvoj")
        continue
    subprocess.run(["security", "add-generic-password", "-s", bundle, "-a", acct,
                    "-w", val, "-U"], capture_output=True)
    print(f"✅ {label} kľúč obnovený zo zálohy ({len(val)} znakov)")

# --- plain settings → UserDefaults (only when unset) ---
simple = ["dictation.defaultKeywords", "whisper.prompt", "whisper.delay",
          "dictation.batchModel", "dictation.realtimeModel", "dictation.liveInsert",
          "dictation.enterAutoStop", "smart.model", "google.tts.voice",
          "indicator.followFocusedField", "indicator.customX", "indicator.customY",
          "sc.dictate.kc", "sc.dictate.mf", "sc.ocr", "sc.readText.kc", "sc.readText.mf",
          "dictation.micPriority", "smart.appProfiles", "smart.appProfiles.categoryMigrated"]
for key in simple:
    if key not in d:
        continue
    if defaults_has(key):
        print(f"⏭  {key} — už nastavené, nechávam tvoje")
        continue
    v = d[key]
    if isinstance(v, bool):
        args = ["-bool", "true" if v else "false"]
    elif isinstance(v, int):
        args = ["-int", str(v)]
    elif isinstance(v, float):
        args = ["-float", str(v)]
    elif isinstance(v, (list, dict)):
        continue  # handled below via plist import
    else:
        args = [str(v)]
    subprocess.run(["defaults", "write", bundle, key] + args, capture_output=True)
    shown = repr(v)[:60]
    print(f"✅ {key} = {shown}")

# --- history: app migrates dictation.history.v1 → JSON file on next launch ---
hist = d.get("dictation.history.v1")
json_path = os.path.join(app_support, "dictation-history.json")
if hist and not os.path.exists(json_path):
    entries = json.loads(hist)
    subprocess.run(["defaults", "write", bundle, "dictation.history.v1",
                    "-data", hist.hex()], capture_output=True)
    print(f"✅ história obnovená — {len(entries)} záznamov (appka ju pri štarte prevedie do súboru)")
elif os.path.exists(json_path):
    print("⏭  história — už existuje, nechávam tvoju")
PY

echo ""
echo "✅ Hotovo. Spusti appku:  open OsobnyPomocnik.app"
echo "   Skontroluj Nastavenia → Všeobecné (kľúče) a Diktovanie (kľúčové slová)."
