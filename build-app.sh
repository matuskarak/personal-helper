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

echo "✍️  Podpisujem (OsobnyPomocnikDev) s entitlements…"
codesign \
    --sign "OsobnyPomocnikDev" \
    --force \
    --deep \
    --entitlements "$ENTITLEMENTS" \
    "$BUNDLE"

echo ""
echo "✅ $BUNDLE je pripravený!"
echo ""
echo "Spusti:  open \"$SCRIPT_DIR/$BUNDLE\""
echo "         alebo:  make run"
