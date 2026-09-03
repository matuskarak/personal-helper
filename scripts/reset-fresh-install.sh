#!/bin/bash
# Simulates "brand new user just downloaded the app" on the SAME macOS account —
# no user-switching, no VM. Resets everything the app treats as "already set up":
# TCC permissions, UserDefaults, Keychain items, local data files, logs.
#
# What it does NOT reset: Gatekeeper's quarantine/trust cache for this exact .app
# bundle path (macOS remembers you already approved "Otvoriť napriek tomu" for a
# binary at this path+signature). To also re-test THAT step, download a fresh zip
# via Safari instead of using the already-built OsobnyPomocnik.app in this repo —
# or use a VM (UTM) for a truly untouched Mac.
#
# Run: ./scripts/reset-fresh-install.sh
set -euo pipefail
BUNDLE_ID="sk.matuskarak.osobny-pomocnik"

echo "🛑 Ukončujem appku (ak beží)…"
pkill -f OsobnyPomocnik.app 2>/dev/null || true
sleep 1

echo "🔐 Resetujem TCC povolenia (Accessibility, Mikrofón, Nahrávanie obrazovky)…"
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null || true
tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || true
tccutil reset ListenEvent "$BUNDLE_ID" 2>/dev/null || true

echo "⚙️  Mažem UserDefaults (onboarding, skratky, nastavenia, prístupový kód)…"
defaults delete "$BUNDLE_ID" 2>/dev/null || true

echo "🔑 Mažem kľúče z Kľúčenky (OpenAI, Gemini, Google TTS)…"
for acct in openai.dictation.key gemini.dictation.key google.api.key; do
    security delete-generic-password -s "$BUNDLE_ID" -a "$acct" >/dev/null 2>&1 || true
done

echo "🗑  Mažem lokálne dáta (história, čakajúce nahrávky, screenshoty)…"
rm -rf ~/Library/Application\ Support/OsobnyPomocnik

echo "📄 Mažem logy…"
rm -rf ~/Library/Logs/OsobnyPomocnik

echo ""
echo "✅ Hotovo — appka sa pri ďalšom spustení bude správať ako čerstvo stiahnutá."
echo "   Spusti: open \"OsobnyPomocnik.app\"  (alebo make run)"
