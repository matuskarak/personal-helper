#!/bin/bash
# Simulates "brand new user just downloaded the app" on the SAME macOS account —
# no user-switching, no VM.
#
# DESTRUCTIVE. It wipes the live install's settings, history and API keys. It backs up
# everything it can first (settings, history, logs) so a reset is reversible:
#     ./scripts/reset-fresh-install.sh --restore
# The Keychain is the exception — API keys CANNOT be backed up without prompting for
# every single one, so they have to be re-entered after a reset. That is why this
# script asks for explicit confirmation before doing anything.
#
# Also not reset: Gatekeeper's quarantine/trust for this exact .app path. To re-test
# "Otvoriť napriek tomu", download a fresh zip via Safari or use a VM (UTM).
#
# Run: ./scripts/reset-fresh-install.sh          (reset, asks to confirm)
#      ./scripts/reset-fresh-install.sh --restore (put the last backup back)
set -euo pipefail
BUNDLE_ID="sk.matuskarak.osobny-pomocnik"
APP_SUPPORT="$HOME/Library/Application Support/OsobnyPomocnik"
LOGS="$HOME/Library/Logs/OsobnyPomocnik"
PLIST="$HOME/Library/Preferences/$BUNDLE_ID.plist"
BACKUP_ROOT="$HOME/Library/Application Support/OsobnyPomocnik-zalohy"

if [ "${1:-}" = "--restore" ]; then
    LATEST=$(ls -1d "$BACKUP_ROOT"/* 2>/dev/null | tail -1 || true)
    [ -z "$LATEST" ] && { echo "❌ Žiadna záloha v $BACKUP_ROOT"; exit 1; }
    echo "♻️  Obnovujem z: $LATEST"
    pkill -f OsobnyPomocnik.app 2>/dev/null || true
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
      • API kľúče v Kľúčenke (OpenAI, Gemini, Google TTS) — NEDAJÚ sa zálohovať
      • nastavenia, skratky, kľúčové slová, prístupový kód
      • históriu diktovaní, čakajúce nahrávky, screenshoty
      • povolenia (Accessibility, Mikrofón, Nahrávanie obrazovky)

    Všetko sa zálohuje a dá vrátiť cez:  $0 --restore
    (kľúče len ak si predtým spustil ./scripts/backup-settings.sh — tento reset ich nečíta)

WARN
read -r -p "Naozaj pokračovať? Napíš ANO: " CONFIRM
[ "$CONFIRM" = "ANO" ] || { echo "Zrušené."; exit 0; }

STAMP="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STAMP"
echo "💾 Zálohujem do $STAMP…"
[ -d "$APP_SUPPORT" ] && cp -R "$APP_SUPPORT" "$STAMP/OsobnyPomocnik"
[ -d "$LOGS" ] && cp -R "$LOGS" "$STAMP/Logs"
defaults export "$BUNDLE_ID" "$STAMP/defaults.plist" 2>/dev/null || true

echo "🛑 Ukončujem appku (ak beží)…"
pkill -f OsobnyPomocnik.app 2>/dev/null || true
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
echo "   Späť do pôvodného stavu:  $0 --restore  (okrem API kľúčov)"
