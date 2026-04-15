#!/usr/bin/env bash
# Android stack-zorder test: Stack (FrameLayout) z-order after child mutations.
#
# Tests that after reordering Stack children, the z-order matches
# the new child order (last child on top, first at bottom).
#
# State0: [BG_LAYER, TAP_TARGET] — button on top, tappable
# State1: [TAP_TARGET, OVERLAY_TEXT] — text on top, button underneath
#
# Required env vars (set by emulator-all.nix harness):
#   ADB, EMULATOR_SERIAL, STACK_ZORDER_APK, PACKAGE, ACTIVITY, WORK_DIR
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

EXIT_CODE=0

start_app "$STACK_ZORDER_APK" "stack-zorder"
wait_for_render "stack-zorder"
sleep 5
collect_logcat "szorder-initial"

assert_logcat "$LOGCAT_FILE" "Stack state: ButtonOnTop" "Initial state is ButtonOnTop"

# Verify both items visible
DUMP_A="$WORK_DIR/szorder_a.xml"
dump_ok=0
for attempt in 1 2 3; do
    if "$ADB" -s "$EMULATOR_SERIAL" shell uiautomator dump /data/local/tmp/ui.xml 2>&1 | grep -q "dumped"; then
        "$ADB" -s "$EMULATOR_SERIAL" pull /data/local/tmp/ui.xml "$DUMP_A" 2>/dev/null
        dump_ok=1
        break
    fi
    sleep 5
done

if [ $dump_ok -eq 1 ]; then
    if grep -q 'TAP_TARGET' "$DUMP_A" 2>/dev/null; then
        echo "PASS: TAP_TARGET visible in ButtonOnTop"
    else
        echo "FAIL: TAP_TARGET not visible in ButtonOnTop"
        EXIT_CODE=1
    fi
    if grep -q 'BG_LAYER' "$DUMP_A" 2>/dev/null; then
        echo "PASS: BG_LAYER visible in ButtonOnTop"
    else
        echo "FAIL: BG_LAYER not visible in ButtonOnTop"
        EXIT_CODE=1
    fi
else
    echo "FAIL: Could not dump view hierarchy (ButtonOnTop)"
    EXIT_CODE=1
fi

# Tap the button to verify it works when on top
echo "=== Tapping TAP_TARGET (should work when on top) ==="
"$ADB" -s "$EMULATOR_SERIAL" logcat -c 2>/dev/null || true
tap_button "TAP_TARGET" || "$ADB" -s "$EMULATOR_SERIAL" shell input tap 540 400
sleep 3
collect_logcat "szorder-tap1"
assert_logcat "$LOGCAT_FILE" "Stack button tapped: 1" "Button tap works when on top"

# === Switch to TextOnTop ===
echo "=== Tapping Switch order ==="
tap_button "Switch order" || "$ADB" -s "$EMULATOR_SERIAL" shell input tap 540 100
sleep 5

collect_logcat "szorder-switched"
assert_logcat "$LOGCAT_FILE" "Stack state: TextOnTop" "Switched to TextOnTop"

# Verify hierarchy
DUMP_B="$WORK_DIR/szorder_b.xml"
dump_ok_b=0
for attempt in 1 2 3; do
    if "$ADB" -s "$EMULATOR_SERIAL" shell uiautomator dump /data/local/tmp/ui.xml 2>&1 | grep -q "dumped"; then
        "$ADB" -s "$EMULATOR_SERIAL" pull /data/local/tmp/ui.xml "$DUMP_B" 2>/dev/null
        dump_ok_b=1
        break
    fi
    sleep 5
done

if [ $dump_ok_b -eq 1 ]; then
    echo "=== TextOnTop hierarchy ==="
    cat "$DUMP_B"
    echo ""

    if grep -q 'TAP_TARGET' "$DUMP_B" 2>/dev/null; then
        echo "PASS: TAP_TARGET present in TextOnTop"
    else
        echo "FAIL: TAP_TARGET missing in TextOnTop"
        EXIT_CODE=1
    fi
    if grep -q 'OVERLAY_TEXT' "$DUMP_B" 2>/dev/null; then
        echo "PASS: OVERLAY_TEXT present in TextOnTop"
    else
        echo "FAIL: OVERLAY_TEXT missing in TextOnTop"
        EXIT_CODE=1
    fi

    # BG_LAYER should be gone (it was replaced by the button)
    if grep -q 'BG_LAYER' "$DUMP_B" 2>/dev/null; then
        echo "FAIL: BG_LAYER still visible in TextOnTop (orphaned)"
        EXIT_CODE=1
    else
        echo "PASS: BG_LAYER correctly absent in TextOnTop"
    fi
else
    echo "FAIL: Could not dump view hierarchy (TextOnTop)"
    EXIT_CODE=1
fi

"$ADB" -s "$EMULATOR_SERIAL" uninstall "$PACKAGE" 2>/dev/null || true

exit $EXIT_CODE
