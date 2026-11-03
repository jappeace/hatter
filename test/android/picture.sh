#!/usr/bin/env bash
# Android picture picker test: install APK, put a large picture in the
# gallery, tap Pick Picture, pick it in the system's picker, and assert that
# a PNG comes back.
#
# Required env vars (set by emulator-all.nix harness):
#   ADB, EMULATOR_SERIAL, PICTURE_APK, BIG_PICTURE, PACKAGE, ACTIVITY, WORK_DIR
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

EXIT_CODE=0

start_app "$PICTURE_APK" "picture"

wait_for_logcat "setRoot" 120 || true
wait_for_logcat "setHandler" 30 || true

# As large as a phone's RAW photo, which runs the app out of memory if read whole.
"$ADB" -s "$EMULATOR_SERIAL" push "$BIG_PICTURE" /sdcard/Pictures/hatter-big.png
# Newest, not from the Nix store's 1970.
"$ADB" -s "$EMULATOR_SERIAL" shell touch /sdcard/Pictures/hatter-big.png
"$ADB" -s "$EMULATOR_SERIAL" shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
    -d file:///sdcard/Pictures/hatter-big.png
# Android 10 on ignores the broadcast: its media store scans when asked so.
SCANNED=$("$ADB" -s "$EMULATOR_SERIAL" shell content call --uri content://media --method scan_volume \
    --arg external_primary 2>&1 || true)

tap_button "Pick Picture" || { echo "FAIL: could not tap Pick Picture"; EXIT_CODE=1; }

# The photo picker (Android 13 on) shows the newest picture first; before
# it, the system's file picker shows recent files by name. Recent can take
# a while on a slow emulator, and can stay empty although the media store
# has the picture, so then we search for it by name. The search's list rows
# have the name only in their description.
DUMP_FILE="$WORK_DIR/picker.xml"
BOUNDS=""
SEARCHED=0

# Dumps the screen and sets MATCH to the picture's element in it, BOUNDS to its bounds.
find_picture() {
    "$ADB" -s "$EMULATOR_SERIAL" shell uiautomator dump /data/local/tmp/ui.xml >/dev/null
    "$ADB" -s "$EMULATOR_SERIAL" pull /data/local/tmp/ui.xml "$DUMP_FILE" >/dev/null
    MATCH=$(grep -o -e 'content-desc="Photo taken on[^"]*"[^>]*bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' \
        -e 'text="hatter-big.png"[^>]*bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' \
        -e 'content-desc="hatter-big.png, [^"]*"[^>]*bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' "$DUMP_FILE" \
        | head -1 || true)
    BOUNDS=$(echo "$MATCH" | grep -o 'bounds="[^"]*"' | grep -o '\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]' || true)
}

for ATTEMPT in $(seq 1 12); do
    sleep 3
    find_picture
    [ -n "$BOUNDS" ] && break
    SEARCH=$(grep -o 'content-desc="Search"[^>]*bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' "$DUMP_FILE" \
        | head -1 | grep -o '\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]' || true)
    if [ "$ATTEMPT" -ge 4 ] && [ "$SEARCHED" = 0 ] && [ -n "$SEARCH" ] && grep -q 'text="No items"' "$DUMP_FILE"; then
        echo "Recent is empty, searching the picker for hatter-big"
        read -r LEFT TOP RIGHT BOTTOM <<< "$(echo "$SEARCH" | tr '[],' '   ')"
        "$ADB" -s "$EMULATOR_SERIAL" shell input tap $(( (LEFT + RIGHT) / 2 )) $(( (TOP + BOTTOM) / 2 ))
        sleep 2
        "$ADB" -s "$EMULATOR_SERIAL" shell input text hatter-big
        "$ADB" -s "$EMULATOR_SERIAL" shell input keyevent KEYCODE_ENTER
        SEARCHED=1
    fi
done
if [ -n "$BOUNDS" ]; then
    if echo "$MATCH" | grep -q 'hatter-big.png'; then
        # The system's file picker (API 30) ignores taps on files from `input`,
        # but picks the focused file on Enter.
        for _ in $(seq 1 10); do
            grep -o '<node [^>]*focused="true"[^>]*>' "$DUMP_FILE" | grep -q 'hatter-big.png' && break
            "$ADB" -s "$EMULATOR_SERIAL" shell input keyevent KEYCODE_TAB
            sleep 1
            find_picture
        done
        echo "Picking the picture with Enter: $MATCH"
        "$ADB" -s "$EMULATOR_SERIAL" shell input keyevent KEYCODE_ENTER
    else
        read -r LEFT TOP RIGHT BOTTOM <<< "$(echo "$BOUNDS" | tr '[],' '   ')"
        echo "Tapping the picture: $MATCH"
        "$ADB" -s "$EMULATOR_SERIAL" shell input tap $(( (LEFT + RIGHT) / 2 )) $(( (TOP + BOTTOM) / 2 ))
    fi
    sleep 5
    find_picture
    if [ -n "$BOUNDS" ]; then
        echo "The picker is still open, showing:"
        grep -o -e 'text="[^"]*"' -e 'content-desc="[^"]*"' "$DUMP_FILE" | grep -v '=""' | head -40
    fi
else
    echo "FAIL: no picture in the picker (searched: $SEARCHED), which shows:"
    grep -o -e 'text="[^"]*"' -e 'content-desc="[^"]*"' "$DUMP_FILE" | grep -v '=""' | head -40
    echo "Asking the media store to scan said: $SCANNED"
    echo "The media store's pictures named hatter:"
    # One string, so the device's shell gets the quotes.
    "$ADB" -s "$EMULATOR_SERIAL" shell "content query --uri content://media/external/images/media\
 --projection _display_name:date_modified:_size:mime_type --where \"_display_name LIKE 'hatter%'\"" 2>&1 | head -5
    EXIT_CODE=1
fi
wait_for_logcat "Picture picked" 60 || true

collect_logcat "picture"
echo "The app's picture log, and any crash:"
grep -e "HatterPicture" -e "Lifecycle" -e "FATAL" -e "AndroidRuntime" -e "lowmemorykiller" -e "Killing" -e "Picture picked" "$LOGCAT_FILE" | tail -60 || true

assert_logcat "$LOGCAT_FILE" "Picture picked: [0-9]* bytes" "a large picture comes back as a PNG"

"$ADB" -s "$EMULATOR_SERIAL" shell rm -f /sdcard/Pictures/hatter-big.png
"$ADB" -s "$EMULATOR_SERIAL" shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
    -d file:///sdcard/Pictures/hatter-big.png
"$ADB" -s "$EMULATOR_SERIAL" uninstall "$PACKAGE" 2>/dev/null || true

exit $EXIT_CODE
