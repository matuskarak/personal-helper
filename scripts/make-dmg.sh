#!/bin/bash
# ---------------------------------------------------------------------
# make-dmg.sh — Zostaví štylizované inštalačné DMG pre Ozvenu.
#
# Použitie:
#   scripts/make-dmg.sh <path/to/Ozvena.app> <output.dmg>
#
# Plain bash + macOS built-ins only (hdiutil, osascript, SetFile) — žiadny
# brew/create-dmg/PIL. Finder okno vo výslednom DMG ukazuje kroky inštalácie
# priamo (pozadie generované scripts/dmg-background.swift), takže netechnický
# tester nemusí nič hľadať: potiahne appku do Aplikácií podľa šípky, macOS ju
# prvýkrát zablokuje, tester ide do Systémových nastavení a klikne "Otvoriť
# napriek tomu" (presný postup je aj v NAVOD.md).
#
# DÔLEŽITÉ PREVIAZANIE s scripts/dmg-background.swift: ikony sa vo Finderi
# umiestňujú na súradnice APP_ICON_X/Y a APPLICATIONS_X/Y nižšie — tie musia
# zodpovedať prázdnym miestam vypáleným do pozadia (pozri komentár v
# dmg-background.swift). Ak zmeníš jedny, zmeň aj druhé.
# ---------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

APP_PATH="${1:-}"
OUT_DMG="${2:-}"

if [ -z "$APP_PATH" ] || [ -z "$OUT_DMG" ]; then
    echo "Použitie: scripts/make-dmg.sh <path/to/Ozvena.app> <output.dmg>"
    exit 1
fi

if [ ! -d "$APP_PATH" ]; then
    echo "❌ Appka nenájdená: $APP_PATH"
    exit 1
fi

APP_NAME="$(basename "$APP_PATH")" # odvodené od vstupu, nie hardcoded — dnes "Ozvena.app"
VOLUME_NAME="Ozvena"

# Rozloženie Finder okna — MUSÍ zodpovedať prázdnym miestam v dmg-background.swift.
# Pozadie je 720×540pt; okno je zámerne o ~100pt vyššie (WINDOW_HEIGHT), lebo aj so
# skrytým toolbarom/statusbarom/pathbarom si macOS 27 Finder necháva vlastnú hlavičku
# a bez tejto rezervy sa spodok pozadia (panel s krokmi 2/3) orezáva a treba okno
# ručne zväčšiť.
WINDOW_WIDTH=720
WINDOW_HEIGHT=640
WINDOW_X=200
WINDOW_Y=120
ICON_SIZE=112
APP_ICON_X=190
APP_ICON_Y=185
APPLICATIONS_X=530
APPLICATIONS_Y=185

OUT_DMG="$(cd "$(dirname "$OUT_DMG")" && pwd)/$(basename "$OUT_DMG")"
mkdir -p "$(dirname "$OUT_DMG")"

WORK_DIR="$(mktemp -d /tmp/ozvena-dmg.XXXXXX)"
STAGING_DIR="$WORK_DIR/staging"
TEMP_DMG="$WORK_DIR/temp.dmg"
BACKGROUND_PNG="$WORK_DIR/background.png"
MOUNT_POINT=""

cleanup() {
    local status=$?
    if [ -n "$MOUNT_POINT" ] && mount | grep -q "$MOUNT_POINT"; then
        hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK_DIR"
    exit $status
}
trap cleanup EXIT INT TERM

echo "🖼  Generujem pozadie…"
if ! swift "$SCRIPT_DIR/dmg-background.swift" "$BACKGROUND_PNG"; then
    echo "❌ Generovanie pozadia zlyhalo."
    exit 1
fi

echo "📁 Pripravujem obsah DMG…"
mkdir -p "$STAGING_DIR/.background"
cp "$BACKGROUND_PNG" "$STAGING_DIR/.background/background.png"
ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME"
ln -s /Applications "$STAGING_DIR/Applications"

# Odhad veľkosti temp DMG (appka + rezerva na .background/ a filesystem overhead).
APP_SIZE_KB=$(du -sk "$STAGING_DIR" | cut -f1)
DMG_SIZE_MB=$(( (APP_SIZE_KB / 1024) + 50 ))

echo "💽 Vytváram writable DMG (~${DMG_SIZE_MB}MB)…"
rm -f "$TEMP_DMG"
hdiutil create -srcfolder "$STAGING_DIR" -volname "$VOLUME_NAME" -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" -format UDRW -size "${DMG_SIZE_MB}m" "$TEMP_DMG" >/dev/null

echo "🔗 Mountujem…"
ATTACH_OUT=$(hdiutil attach "$TEMP_DMG" -readwrite -noverify -noautoopen)
MOUNT_POINT=$(echo "$ATTACH_OUT" | grep -E '/Volumes/' | sed -E 's/^.*(\/Volumes\/.*)$/\1/')
if [ -z "$MOUNT_POINT" ]; then
    echo "❌ Nepodarilo sa zistiť mount point."
    exit 1
fi

# Daj Finderu chvíľu, nech si volume "všimne" pred AppleScriptom.
sleep 1

# .fseventsd: HFS+ nechá kernel/fseventsd démon vytvoriť tento priečinok pri mountnutí
# read-write volume (journaling metadát) — na macOS 27 sa ukázal ako viditeľná položka aj
# keď "show hidden files" zapne len bežný tester, nie developer. "no_log" súbor vnútri je
# zdokumentovaný trik, ktorý fseventsd povie, nech pre tento volume vôbec nezapisuje log —
# to väčšinou zabráni tomu, aby sa priečinok znova naplnil/objavil. Skús ho teda zmazať a
# nahradiť prázdnym + no_log, a pre istotu ho aj skry a nižšie v AppleScripte odsuň mimo okna
# (belt-and-suspenders, keby fseventsd log medzitým aj tak vytvoril).
if [ -d "$MOUNT_POINT/.fseventsd" ]; then
    rm -rf "$MOUNT_POINT/.fseventsd" 2>/dev/null || true
fi
mkdir -p "$MOUNT_POINT/.fseventsd" 2>/dev/null || true
touch "$MOUNT_POINT/.fseventsd/no_log" 2>/dev/null || true
chflags hidden "$MOUNT_POINT/.fseventsd" 2>/dev/null || true
SetFile -a V "$MOUNT_POINT/.fseventsd" 2>/dev/null || true

echo "🎨 Nastavujem vzhľad Finder okna (AppleScript)…"
OSASCRIPT_ERR="$WORK_DIR/osascript.err"
if ! osascript >"$WORK_DIR/osascript.out" 2>"$OSASCRIPT_ERR" <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        -- macOS 27 Finder stále vie ukázať vlastnú hlavičku/pathbar aj po "false" nižšie —
        -- každý z týchto troch je zabalený vo "try", lebo nie všetky existujú/fungujú na
        -- každej macOS verzii a jeden zlyhaný by inak zhodil celý skript.
        try
            set toolbar visible of container window to false
        end try
        try
            set statusbar visible of container window to false
        end try
        try
            set pathbar visible of container window to false
        end try
        set the bounds of container window to {$WINDOW_X, $WINDOW_Y, $((WINDOW_X + WINDOW_WIDTH)), $((WINDOW_Y + WINDOW_HEIGHT))}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to $ICON_SIZE
        set background picture of theViewOptions to file ".background:background.png"
        set position of item "$APP_NAME" of container window to {$APP_ICON_X, $APP_ICON_Y}
        set position of item "Applications" of container window to {$APPLICATIONS_X, $APPLICATIONS_Y}
        -- Finder skrýva príponu appiek defaultne, ale poistka pre istotu (napr. po
        -- premenovaní appky 2026-09-19 — pozri CLAUDE.md), aby sa pod ikonou v DMG okne
        -- nezobrazilo "$APP_NAME.app" namiesto len "$APP_NAME".
        try
            set extension hidden of item "$APP_NAME" of container window to true
        end try
        -- Skryté položky (.background, .fseventsd, prípadne .DS_Store/.Trashes) odsuň ďaleko
        -- mimo viditeľnú oblasť okna — poistka pre testera, čo má v Finderi zapnuté "Zobraziť
        -- skryté súbory": chflags hidden/SetFile -a V ich pred takým testerom neschová.
        try
            set position of item ".background" of container window to {900, 900}
        end try
        try
            set position of item ".fseventsd" of container window to {900, 900}
        end try
        try
            set position of item ".DS_Store" of container window to {900, 900}
        end try
        try
            set position of item ".Trashes" of container window to {900, 900}
        end try
        set sidebar width of container window to 0
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
APPLESCRIPT
then
    echo "❌ AppleScript nastavenie Finder okna zlyhalo."
    echo "   Terminál (alebo iTerm) pravdepodobne nemá povolenie ovládať Finder."
    echo "   Over v: Systémové nastavenia → Súkromie a bezpečnosť → Automatizácia →"
    echo "   povoľ svojmu terminálu ovládať Finder, potom skús znova."
    if [ -s "$OSASCRIPT_ERR" ]; then
        echo "   Detail chyby:"
        sed 's/^/   /' "$OSASCRIPT_ERR"
    fi
    exit 1
fi

# Skry .background priečinok pred bežným zobrazením (obe metódy, kvôli konzistencii medzi
# rôznymi Finder verziami — SetFile nastavuje klasický "invisible" bit, chflags BSD flag).
chflags hidden "$MOUNT_POINT/.background" 2>/dev/null || true
SetFile -a V "$MOUNT_POINT/.background" 2>/dev/null || true

sync
echo "📤 Odpájam…"
hdiutil detach "$MOUNT_POINT" -force >/dev/null
MOUNT_POINT=""

echo "🗜  Komprimujem na finálny read-only DMG…"
rm -f "$OUT_DMG"
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUT_DMG" >/dev/null

echo "✅ Hotovo: $OUT_DMG"
