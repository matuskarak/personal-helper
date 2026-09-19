#!/bin/bash
# Simulates "brand new user just downloaded the app" on the SAME macOS account —
# no user-switching, no VM.
#
# DESTRUCTIVE. It wipes the live install's settings, history and API keys. It backs up
# everything it can first (settings, history, logs) so a reset is reversible:
#     ./scripts/reset-fresh-install.sh --restore
# API keys are backed up too, via backup-settings.sh (the Keychain may ask to allow it).
# Not restorable: macOS permissions (TCC) — they have to be granted again after a reset.
# The script still asks for explicit confirmation before doing anything.
#
# Also not reset: Gatekeeper's quarantine/trust for this exact .app path. To re-test
# "Otvoriť napriek tomu", download a fresh zip via Safari or use a VM (UTM).
#
# Run: ./scripts/reset-fresh-install.sh          (reset, asks to confirm)
#      ./scripts/reset-fresh-install.sh --restore [YYYYMMDD-HHMMSS] (put a backup back;
#                                                   default = newest)
set -euo pipefail
BUNDLE_ID="sk.matuskarak.osobny-pomocnik"
APP_SUPPORT="$HOME/Library/Application Support/OsobnyPomocnik"
LOGS="$HOME/Library/Logs/OsobnyPomocnik"
PLIST="$HOME/Library/Preferences/$BUNDLE_ID.plist"
BACKUP_ROOT="$HOME/Library/Application Support/OsobnyPomocnik-zalohy"

if [ "${1:-}" = "--restore" ]; then
    # Optional explicit folder: after two resets in a row, "latest" is the backup of the
    # already-empty install — naming the folder is the only safe way back.
    if [ -n "${2:-}" ]; then
        LATEST="$2"; [ -d "$LATEST" ] || LATEST="$BACKUP_ROOT/$2"
    else
        LATEST=$(ls -1d "$BACKUP_ROOT"/* 2>/dev/null | tail -1 || true)
    fi
    [ -d "${LATEST:-}" ] || { echo "❌ Záloha nenájdená: ${LATEST:-v $BACKUP_ROOT}"; exit 1; }
    echo "♻️  Obnovujem z: $LATEST"
    # Matches both the legacy bundle name and the current one (Ozvena — premenované 2026-09-19,
    # pozri CLAUDE.md) — testeri, čo ešte nedostali premenovaný build, majú stále OsobnyPomocnik.app.
    pkill -f "OsobnyPomocnik.app|Ozvena.app" 2>/dev/null || true
    sleep 1
    [ -d "$LATEST/OsobnyPomocnik" ] && { rm -rf "$APP_SUPPORT"; cp -R "$LATEST/OsobnyPomocnik" "$APP_SUPPORT"; echo "   ✓ história a dáta"; }
    [ -d "$LATEST/Logs" ] && { rm -rf "$LOGS"; cp -R "$LATEST/Logs" "$LOGS"; echo "   ✓ logy"; }
    if [ -f "$LATEST/defaults.plist" ]; then
        defaults import "$BUNDLE_ID" "$LATEST/defaults.plist"
        echo "   ✓ nastavenia"
    fi
    if [ -f "$LATEST/keys.plist" ]; then
        python3 - "$BUNDLE_ID" "$LATEST/keys.plist" <<'PY'
import plistlib, subprocess, sys
bundle, path = sys.argv[1], sys.argv[2]
for acct, val in plistlib.load(open(path, "rb")).items():
    if subprocess.run(["security","find-generic-password","-s",bundle,"-a",acct],capture_output=True).returncode == 0:
        print(f"   ⏭  {acct} — v Kľúčenke už je, nechávam"); continue
    subprocess.run(["security","add-generic-password","-s",bundle,"-a",acct,"-w",val,"-U"],capture_output=True)
    print(f"   ✓ {acct} obnovený")
PY
    else
        echo "   ⚠️  záloha nemá keys.plist — kľúče treba vložiť ručne (zálohy z backup-settings.sh ich majú)"
    fi
    echo ""
    echo "✅ Obnovené."
    exit 0
fi

cat <<WARN

⚠️  POZOR — toto zmaže ŽIVÉ dáta na tomto účte ($USER):
      • API kľúče v Kľúčenke (OpenAI, Gemini, Google TTS) — zálohujú sa (Kľúčenka sa môže pýtať)
      • nastavenia, skratky, kľúčové slová, prístupový kód
      • históriu diktovaní, čakajúce nahrávky, screenshoty
      • povolenia (Accessibility, Mikrofón, Nahrávanie obrazovky)

    Všetko sa zálohuje a dá vrátiť cez:  $0 --restore
    (povolenia Mikrofón/Accessibility/Nahrávanie obrazovky sa NEobnovia — povolíš ich znova)

WARN
read -r -p "Naozaj pokračovať? Napíš ANO: " CONFIRM
[ "$(echo "$CONFIRM" | tr "[:upper:]" "[:lower:]" | tr -d "[:space:]")" = "ano" ] || { echo "Zrušené."; exit 0; }

# The full backup, API keys included. This used to copy everything EXCEPT the keys, and
# --restore picks the newest backup — i.e. exactly this key-less one, so a reset + restore
# silently lost the keys. Abort if it fails: never wipe without a backup to come back to.
"$(dirname "$0")/backup-settings.sh" || { echo "❌ Záloha zlyhala — nič nemažem."; exit 1; }

echo "🛑 Ukončujem appku (ak beží)…"
pkill -f "OsobnyPomocnik.app|Ozvena.app" 2>/dev/null || true
sleep 1

echo "🔐 Resetujem TCC povolenia…"
for svc in Accessibility Microphone ScreenCapture ListenEvent; do
    tccutil reset "$svc" "$BUNDLE_ID" >/dev/null 2>&1 || true
done

echo "⚙️  Mažem UserDefaults…"
defaults delete "$BUNDLE_ID" 2>/dev/null || true

echo "🔑 Mažem kľúče z Kľúčenky…"
for acct in openai.dictation.key gemini.dictation.key google.api.key; do
    security delete-generic-password -s "$BUNDLE_ID" -a "$acct" >/dev/null 2>&1 || true
done

echo "🗑  Mažem lokálne dáta a logy…"
rm -rf "$APP_SUPPORT" "$LOGS"

echo ""
echo "✅ Hotovo — appka sa pri ďalšom spustení správa ako čerstvo stiahnutá."
echo "   Späť do pôvodného stavu:  $0 --restore"
