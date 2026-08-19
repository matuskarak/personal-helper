#!/bin/bash
# Pick & preview macOS system sounds (for choosing the DictationSounds "inserted" cue).
# Keeps re-prompting so you can click through several before deciding — Cancel to quit.
set -euo pipefail

SOUNDS_DIR="/System/Library/Sounds"
NAMES=$(ls "$SOUNDS_DIR"/*.aiff | xargs -n1 basename | sed 's/\.aiff$//' | sort)

while true; do
    CHOICE=$(osascript -e "
        set soundList to paragraphs of \"$NAMES\"
        set pick to choose from list soundList with prompt \"Vyber zvuk (prehrá sa hneď):\" default items {\"Bottle\"}
        if pick is false then
            return \"__CANCEL__\"
        else
            return item 1 of pick
        end if
    ")
    [ "$CHOICE" = "__CANCEL__" ] && break
    afplay "$SOUNDS_DIR/$CHOICE.aiff"
    echo "Prehraté: $CHOICE"
done
