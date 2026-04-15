#!/usr/bin/env bash
# Android scrollview-mutations test: add/remove/reorder children in ScrollView.
#
# Tests the inner LinearLayout wrapper handling in addChild/removeChild.
# Cycles through 4 states and verifies correct children visible at each step.
#
# Required env vars (set by emulator-all.nix harness):
#   ADB, EMULATOR_SERIAL, SCROLLVIEW_MUTATIONS_APK, PACKAGE, ACTIVITY, WORK_DIR
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

EXIT_CODE=0

start_app "$SCROLLVIEW_MUTATIONS_APK" "scrollview-mutations"
wait_for_render "scrollview-mutations"
sleep 5
collect_logcat "svm-initial"

assert_logcat "$LOGCAT_FILE" "ScrollView state: SV0" "Initial state is SV0"

# Helper: dump UI and check items
check_items() {
    local label="$1"
    shift
    local expected=("$@")

    local dump_file="$WORK_DIR/svm_${label}.xml"
    local dump_ok=0
    for attempt in 1 2 3; do
        if "$ADB" -s "$EMULATOR_SERIAL" shell uiautomator dump /data/local/tmp/ui.xml 2>&1 | grep -q "dumped"; then
            "$ADB" -s "$EMULATOR_SERIAL" pull /data/local/tmp/ui.xml "$dump_file" 2>/dev/null
            dump_ok=1
            break
        fi
        sleep 5
    done

    if [ $dump_ok -eq 1 ]; then
        echo "=== $label hierarchy ==="
        cat "$dump_file"
        echo ""

        for item in "${expected[@]}"; do
            if grep -q "$item" "$dump_file" 2>/dev/null; then
                echo "PASS: $item visible in $label"
            else
                echo "FAIL: $item not visible in $label"
                EXIT_CODE=1
            fi
        done

        # Check no unexpected SV_ITEM_ items
        for item in SV_ITEM_A SV_ITEM_B SV_ITEM_C SV_ITEM_D; do
            local expected_here=0
            for e in "${expected[@]}"; do
                if [ "$e" = "$item" ]; then
                    expected_here=1
                    break
                fi
            done
            if [ $expected_here -eq 0 ]; then
                if grep -q "$item" "$dump_file" 2>/dev/null; then
                    echo "FAIL: $item should NOT be visible in $label (orphaned)"
                    EXIT_CODE=1
                else
                    echo "PASS: $item correctly absent in $label"
                fi
            fi
        done
    else
        echo "FAIL: Could not dump view hierarchy ($label)"
        EXIT_CODE=1
    fi
}

# State0: A, B, C
check_items "SV0" SV_ITEM_A SV_ITEM_B SV_ITEM_C

# === Advance to SV1 (add D) ===
echo "=== Advancing to SV1 (add child) ==="
tap_button "Advance" || "$ADB" -s "$EMULATOR_SERIAL" shell input tap 540 100
sleep 5
collect_logcat "svm-sv1"
assert_logcat "$LOGCAT_FILE" "ScrollView state: SV1" "Advanced to SV1"
check_items "SV1" SV_ITEM_A SV_ITEM_B SV_ITEM_C SV_ITEM_D

# === Advance to SV2 (remove B) ===
echo "=== Advancing to SV2 (remove middle child) ==="
tap_button "Advance" || "$ADB" -s "$EMULATOR_SERIAL" shell input tap 540 100
sleep 5
collect_logcat "svm-sv2"
assert_logcat "$LOGCAT_FILE" "ScrollView state: SV2" "Advanced to SV2"
check_items "SV2" SV_ITEM_A SV_ITEM_C SV_ITEM_D

# === Advance to SV3 (reorder) ===
echo "=== Advancing to SV3 (reorder) ==="
tap_button "Advance" || "$ADB" -s "$EMULATOR_SERIAL" shell input tap 540 100
sleep 5
collect_logcat "svm-sv3"
assert_logcat "$LOGCAT_FILE" "ScrollView state: SV3" "Advanced to SV3"
check_items "SV3" SV_ITEM_D SV_ITEM_C SV_ITEM_A

"$ADB" -s "$EMULATOR_SERIAL" uninstall "$PACKAGE" 2>/dev/null || true

exit $EXIT_CODE
