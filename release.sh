#!/bin/bash
# ---------------------------------------------------------------------
# release.sh — Vydá novú verziu appky priateľom cez Sparkle auto-update.
#
# Použitie:
#   ./release.sh <verzia> [poznámky k vydaniu]
#   ./release.sh 0.2.0 "Nová sekcia Prehľad, oprava BT mikrofónu"
#
# Robí: bump verzie v Info.plist → release build → zip → appcast.xml
#       → GitHub Release (asset) → commit + push appcast.
# Priatelia s appkou dostanú upgrade ponuku pri najbližšej kontrole
# (do 24h automaticky, alebo hneď cez "Skontrolovať aktualizácie…").
# ---------------------------------------------------------------------
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

VERSION="$1"
NOTES="${2:-Nové vydanie.}"
if [ -z "$VERSION" ]; then
    echo "Použitie: ./release.sh <verzia> [poznámky k vydaniu]"
    exit 1
fi

APP_NAME="OsobnyPomocnik"
BUNDLE="$APP_NAME.app"
INFO_PLIST="Sources/$APP_NAME/Resources/Info.plist"
RELEASES_DIR="releases"
ZIP_NAME="$APP_NAME-$VERSION.zip"
REPO="matuskarak/personal-helper"
RELEASE_TAG="builds" # one durable release — every version's zip uploaded here as a new asset

mkdir -p "$RELEASES_DIR"

echo "🔢 Verzia $VERSION…"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((CURRENT_BUILD + 1))" "$INFO_PLIST"

echo "🔨 Release build…"
./build-app.sh release

echo "🤐 Zip…"
rm -f "$RELEASES_DIR/$ZIP_NAME"
ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "$RELEASES_DIR/$ZIP_NAME"
echo "$NOTES" > "$RELEASES_DIR/$APP_NAME-$VERSION.txt"

echo "📰 Appcast…"
./.sparkle-tools/bin/generate_appcast "$RELEASES_DIR" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$RELEASE_TAG/"
cp "$RELEASES_DIR/appcast.xml" appcast.xml

echo "🚀 GitHub Release…"
gh release view "$RELEASE_TAG" --repo "$REPO" >/dev/null 2>&1 \
    || gh release create "$RELEASE_TAG" --repo "$REPO" --title "Aktualizácie" \
        --notes "Priebežné buildy pre Sparkle auto-update — nesťahuj priamo, appka sa aktualizuje sama."
gh release upload "$RELEASE_TAG" "$RELEASES_DIR/$ZIP_NAME" --repo "$REPO" --clobber

echo "📤 Commit + push appcast…"
git add "$INFO_PLIST" appcast.xml
git commit -m "Release v$VERSION"
git push

echo ""
echo "✅ v$VERSION vydaná — priatelia ju dostanú do 24h, alebo hneď cez menu → Skontrolovať aktualizácie…"
