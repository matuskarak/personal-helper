#!/bin/bash
# ---------------------------------------------------------------------
# build-app.sh — Zostaví OsobnyPomocnik.app z SPM projektu
#
# Použitie:
#   ./build-app.sh          # debug build (rýchlejší, pre vývoj)
#   ./build-app.sh release  # optimalizovaný release build
# ---------------------------------------------------------------------
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

CONFIG="${1:-debug}"
APP_NAME="OsobnyPomocnik"
BUNDLE="$APP_NAME.app"
INFO_PLIST="Sources/$APP_NAME/Resources/Info.plist"
ENTITLEMENTS="$APP_NAME.entitlements"

echo "🔨 Zostavujem ($CONFIG)…"
if [ "$CONFIG" = "release" ]; then
    swift build -c release
    BINARY=".build/release/$APP_NAME"
else
    swift build
    BINARY=".build/debug/$APP_NAME"
fi

echo "📦 Vytváram bundle $BUNDLE…"

# Vymaž starý bundle
rm -rf "$BUNDLE"

# Vytvor adresárovú štruktúru
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"

# Skopíruj binárku a Info.plist
cp "$BINARY" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp "$INFO_PLIST" "$BUNDLE/Contents/Info.plist"

# Sparkle.framework je dynamický — zabaľ ho a nasmeruj naň rpath.
SPARKLE_FRAMEWORK=$(find .build/artifacts/sparkle -maxdepth 4 -iname "Sparkle.framework" -type d | head -1)
if [ -n "$SPARKLE_FRAMEWORK" ]; then
    echo "📦 Vkladám Sparkle.framework…"
    mkdir -p "$BUNDLE/Contents/Frameworks"
    rm -rf "$BUNDLE/Contents/Frameworks/Sparkle.framework"
    cp -R "$SPARKLE_FRAMEWORK" "$BUNDLE/Contents/Frameworks/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
fi

# Podpis: debug = lokálny self-signed cert (rýchla iterácia, TCC povolenia prežijú
# rebuild), release = Developer ID + hardened runtime (Gatekeeper/notarizácia).
# SIGN_IDENTITY sa dá prebiť env premennou; Developer ID zisti automaticky z keychain.
if [ -z "${SIGN_IDENTITY:-}" ]; then
    if [ "$CONFIG" = "release" ]; then
        SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
        if [ -z "$SIGN_IDENTITY" ]; then
            echo "⚠️  Developer ID certifikát nenájdený — release podpisujem self-signed (OsobnyPomocnikDev)."
            echo "    Po zápise do Apple Developer Programu si nainštaluj 'Developer ID Application' cert."
            SIGN_IDENTITY="OsobnyPomocnikDev"
        fi
    else
        SIGN_IDENTITY="OsobnyPomocnikDev"
    fi
fi

HARDENED=()
if [ "$SIGN_IDENTITY" != "OsobnyPomocnikDev" ]; then
    HARDENED=(--options runtime --timestamp)
fi

echo "✍️  Podpisujem ($SIGN_IDENTITY)…"
# Inside-out, bez --deep: najprv vnútornosti Sparkle (XPC služby + Autoupdate),
# potom framework, nakoniec app s entitlements. --deep je s hardened runtime nespoľahlivý.
if [ -d "$BUNDLE/Contents/Frameworks/Sparkle.framework" ]; then
    SPARKLE="$BUNDLE/Contents/Frameworks/Sparkle.framework"
    for inner in \
        "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
        "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
        "$SPARKLE/Versions/B/Autoupdate" \
        "$SPARKLE/Versions/B/Updater.app"; do
        [ -e "$inner" ] && codesign --sign "$SIGN_IDENTITY" --force "${HARDENED[@]}" "$inner"
    done
    codesign --sign "$SIGN_IDENTITY" --force "${HARDENED[@]}" "$SPARKLE"
fi
codesign \
    --sign "$SIGN_IDENTITY" \
    --force \
    "${HARDENED[@]}" \
    --entitlements "$ENTITLEMENTS" \
    "$BUNDLE"

echo ""
echo "✅ $BUNDLE je pripravený!"
echo ""
echo "Spusti:  open \"$SCRIPT_DIR/$BUNDLE\""
echo "         alebo:  make run"
