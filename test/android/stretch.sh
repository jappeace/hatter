#!/usr/bin/env bash
# Android stretch test: install stretch APK, assert texts stretched across a
# column or row that wraps its content keep their own width or height.
#
# Required env vars (set by emulator-all.nix harness):
#   ADB, EMULATOR_SERIAL, STRETCH_APK, PACKAGE, ACTIVITY, WORK_DIR
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

EXIT_CODE=0

start_app "$STRETCH_APK" "stretch"
wait_for_render "stretch"
sleep 3

DUMP="$WORK_DIR/stretch_ui.xml"
dump_ok=0
for attempt in 1 2 3; do
    if "$ADB" -s "$EMULATOR_SERIAL" shell uiautomator dump /data/local/tmp/ui.xml 2>&1 | grep -q "dumped"; then
        "$ADB" -s "$EMULATOR_SERIAL" pull /data/local/tmp/ui.xml "$DUMP" 2>/dev/null
        dump_ok=1
        break
    fi
    sleep 5
done
if [ $dump_ok -eq 0 ]; then
    echo "FAIL: Could not dump stretch view hierarchy"
    exit 1
fi

# "x1 y1 x2 y2" of each "Wide" text: on its own, in the column, in the row.
mapfile -t WIDE < <(grep -o 'text="Wide"[^>]*bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' "$DUMP" \
    | sed 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]"/\1 \2 \3 \4/')
if [ "${#WIDE[@]}" -ne 3 ]; then
    echo "FAIL: expected 3 \"Wide\" texts, found ${#WIDE[@]}"
    exit 1
fi
read -r ax1 ay1 ax2 ay2 <<< "${WIDE[0]}"
read -r cx1 _ cx2 _ <<< "${WIDE[1]}"
read -r _ ry1 _ ry2 <<< "${WIDE[2]}"

if [ $((cx2 - cx1)) -ge $((ax2 - ax1)) ]; then
    echo "PASS: text stretched across a column is $((cx2 - cx1)) wide, at least its own $((ax2 - ax1))"
else
    echo "FAIL: text stretched across a column is $((cx2 - cx1)) wide, cut from its own $((ax2 - ax1))"
    EXIT_CODE=1
fi
if [ $((ry2 - ry1)) -ge $((ay2 - ay1)) ]; then
    echo "PASS: text stretched across a row is $((ry2 - ry1)) high, at least its own $((ay2 - ay1))"
else
    echo "FAIL: text stretched across a row is $((ry2 - ry1)) high, cut from its own $((ay2 - ay1))"
    EXIT_CODE=1
fi

"$ADB" -s "$EMULATOR_SERIAL" uninstall "$PACKAGE" 2>/dev/null || true

exit $EXIT_CODE
