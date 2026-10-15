#!/bin/bash
# ---------------------------------------------------------------------
# release.sh — Vydá novú verziu appky priateľom cez Sparkle auto-update.
#
# Použitie:
#   ./release.sh <verzia> [poznámky k vydaniu]
#   ./release.sh 0.2.0 "Nová sekcia Prehľad, oprava BT mikrofónu"
#   Viac bodov = viac riadkov (napr. riadky z CHANGELOG „Nevydané“, s „- “ alebo bez) —
#   v okne aktualizácie sa ukážu ako zoznam.
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

# APP_NAME = interný SwiftPM názov (Package.swift, Sources/ priečinok) — premenovanie appky
# na "Ozvena" (2026-09-19, CLAUDE.md) sa ho netýka. BUNDLE_NAME = to, čo vidí user a čo
# nesú release artefakty (zip/dmg), zostavuje ho build-app.sh.
APP_NAME="OsobnyPomocnik"
BUNDLE_NAME="Ozvena"
BUNDLE="$BUNDLE_NAME.app"
INFO_PLIST="Sources/$APP_NAME/Resources/Info.plist"
RELEASES_DIR="releases"
# DMG lives in its own dir, NOT releases/ — generate_appcast scans releases/ for
# update artifacts (.zip and also .dmg, it supports both) and would otherwise add
# the DMG to appcast.xml as if it were a Sparkle update payload. The DMG is a
# human-facing first-install download, not a Sparkle update artifact — it must
# stay out of that scan. Also gitignored, same as releases/.
DMG_DIR="releases-dmg"
ZIP_NAME="$BUNDLE_NAME-$VERSION.zip"
DMG_NAME="$BUNDLE_NAME-$VERSION.dmg"
REPO="matuskarak/personal-helper"
RELEASE_TAG="builds" # one durable release — every version's zip uploaded here as a new asset

mkdir -p "$RELEASES_DIR" "$DMG_DIR"

echo "🔢 Verzia $VERSION…"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((CURRENT_BUILD + 1))" "$INFO_PLIST"

echo "🔨 Release build…"
./build-app.sh release

echo "🤐 Zip…"
rm -f "$RELEASES_DIR/$ZIP_NAME"
ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "$RELEASES_DIR/$ZIP_NAME"
# HTML bez DOCTYPE/body → generate_appcast ho vloží priamo do appcastu (CDATA), Sparkle ho
# vykreslí ako zoznam. Starší .txt cez releaseNotesLink sa zobrazoval ako jeden súvislý odsek.
{
    echo "<ul>"
    printf '%s\n' "$NOTES" | sed -e 's/^[[:space:]]*[-•*][[:space:]]*//' -e '/^[[:space:]]*$/d' \
        -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's#.*#  <li>&</li>#'
    echo "</ul>"
} > "$RELEASES_DIR/$BUNDLE_NAME-$VERSION.html"

# Notarizácia — beží len keď existuje uložený notarytool profil (jednorazovo:
# xcrun notarytool store-credentials "notary-profile" --apple-id … --team-id … --password …).
# Bez profilu sa preskočí a build ostáva self-signed (dnešný stav).
if xcrun notarytool history --keychain-profile notary-profile >/dev/null 2>&1; then
    echo "🍎 Notarizácia…"
    xcrun notarytool submit "$RELEASES_DIR/$ZIP_NAME" --keychain-profile notary-profile --wait
    xcrun stapler staple "$BUNDLE"
    # Zip so stapled ticketom — to, čo sa distribuuje, musí byť ten istý artefakt.
    rm -f "$RELEASES_DIR/$ZIP_NAME"
    ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "$RELEASES_DIR/$ZIP_NAME"
else
    echo "⚠️  notarytool profil 'notary-profile' nenájdený — vydávam bez notarizácie."
fi

echo "💿 DMG…"
rm -f "$DMG_DIR/$DMG_NAME"
./scripts/make-dmg.sh "$BUNDLE" "$DMG_DIR/$DMG_NAME"

echo "📰 Appcast…"
./.sparkle-tools/bin/generate_appcast "$RELEASES_DIR" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$RELEASE_TAG/"
cp "$RELEASES_DIR/appcast.xml" appcast.xml
# Poznámky sú vložené v appcaste (HTML vyššie). Staršie verzie odkazujú cez releaseNotesLink na
# .txt v koreni repa — tie súbory tam musia ostať.

echo "🚀 GitHub Release…"
gh release view "$RELEASE_TAG" --repo "$REPO" >/dev/null 2>&1 \
    || gh release create "$RELEASE_TAG" --repo "$REPO" --title "Aktualizácie" \
        --notes "Priebežné buildy pre Sparkle auto-update — nesťahuj priamo, appka sa aktualizuje sama."
gh release upload "$RELEASE_TAG" "$RELEASES_DIR/$ZIP_NAME" --repo "$REPO" --clobber
gh release upload "$RELEASE_TAG" "$DMG_DIR/$DMG_NAME" --repo "$REPO" --clobber

echo "📤 Commit + push appcast…"
git add "$INFO_PLIST" appcast.xml
git commit -m "Release v$VERSION"
git push

echo ""
echo "✅ v$VERSION vydaná — priatelia ju dostanú do 24h, alebo hneď cez menu → Skontrolovať aktualizácie…"
