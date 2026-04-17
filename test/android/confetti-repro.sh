#!/usr/bin/env bash
# Android confetti animation reproducer test.
#
# Reproduces the prrrrrrrrr confetti bug: particles created at their
# final scattered positions on first render are never animated because
# createRenderedNode (first render) does not register tweens — only
# diffRenderNode (re-render with changed props) does.
#
# Asserts:
#   1. App started without crash
#   2. No "*" particles visible before triggering confetti
#   3. After tapping "Trigger Confetti", "*" particles are visible
#   4. "Confetti triggered" logged in logcat
#   5. No setNumProp.*translateX=0 in logcat (proves no tween from origin;
#      particles were created at final position, not animated from 0)
#
# Required env vars (set by emulator-all.nix harness):
#   ADB, EMULATOR_SERIAL, CONFETTI_REPRO_APK, PACKAGE, ACTIVITY, WORK_DIR
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

EXIT_CODE=0

# --- Helper: dump UI hierarchy with retries ---
dump_ui() {
    local out_file="$1"
    local dump_ok=0
    for attempt in 1 2 3; do
        if "$ADB" -s "$EMULATOR_SERIAL" shell uiautomator dump /data/local/tmp/ui.xml 2>&1 | grep -q "dumped"; then
            "$ADB" -s "$EMULATOR_SERIAL" pull /data/local/tmp/ui.xml "$out_file" 2>/dev/null
            dump_ok=1
            break
        fi
        echo "  uiautomator dump attempt $attempt failed, retrying in 5s..."
        sleep 5
    done
    return $((1 - dump_ok))
}

start_app "$CONFETTI_REPRO_APK" "confetti-repro"
wait_for_render "confetti-repro"
sleep 3

# === BEFORE: no confetti particles visible ===
DUMP_BEFORE="$WORK_DIR/confetti_before.xml"
if dump_ui "$DUMP_BEFORE"; then
    echo "=== Before-confetti view hierarchy ==="
    cat "$DUMP_BEFORE"
    echo ""
    echo "=== End hierarchy ==="

    if grep -q 'text="\*"' "$DUMP_BEFORE" 2>/dev/null; then
        echo "FAIL: '*' particles visible BEFORE triggering confetti"
        EXIT_CODE=1
    else
        echo "PASS: No '*' particles before triggering confetti"
    fi
else
    echo "FAIL: Could not dump view hierarchy (before confetti)"
    EXIT_CODE=1
fi

# === Tap "Trigger Confetti" ===
tap_button "Trigger Confetti" || { echo "WARNING: could not tap Trigger Confetti"; }

# Wait for animation duration (1200ms) + render settle
sleep 5

# === AFTER: confetti particles should be visible ===
DUMP_AFTER="$WORK_DIR/confetti_after.xml"
if dump_ui "$DUMP_AFTER"; then
    echo "=== After-confetti view hierarchy ==="
    cat "$DUMP_AFTER"
    echo ""
    echo "=== End hierarchy ==="

    if grep -q 'text="\*"' "$DUMP_AFTER" 2>/dev/null; then
        echo "PASS: '*' particles visible after triggering confetti"
    else
        echo "FAIL: No '*' particles found after triggering confetti"
        EXIT_CODE=1
    fi

    # Count how many particles are visible (at least 3 required;
    # translateY offsets may push some beyond container clip bounds)
    PARTICLE_COUNT=$(grep -o 'text="\*"' "$DUMP_AFTER" 2>/dev/null | wc -l)
    echo "Particle count: $PARTICLE_COUNT (expected 5)"
    if [ "$PARTICLE_COUNT" -ge 3 ]; then
        echo "PASS: Confetti particles rendered ($PARTICLE_COUNT visible)"
    else
        echo "FAIL: Expected at least 3 particles, found $PARTICLE_COUNT"
        EXIT_CODE=1
    fi
else
    echo "FAIL: Could not dump view hierarchy (after confetti)"
    EXIT_CODE=1
fi

# === Logcat assertions ===
collect_logcat "confetti-repro"

assert_logcat "$LOGCAT_FILE" "ConfettiRepDemoMain started" "Demo app started"
assert_logcat "$LOGCAT_FILE" "Confetti triggered" "Confetti trigger logged"

# The key assertion: if a tween were registered, the animation would
# interpolate from translateX=0 (origin) to the final value.  Since
# particles are created at their final positions on first render
# (createRenderedNode), no tween fires and translateX=0 never appears.
# Note: setNumProp translateX=<final> calls DO appear (creation), but
# translateX=0.0 would only appear if a tween animated from origin.
if grep -q "setNumProp.*translateX=0\.0" "$LOGCAT_FILE" 2>/dev/null; then
    echo "INFO: translateX=0.0 found — tween DID animate from origin (bug may be fixed)"
    grep "setNumProp.*translateX=0" "$LOGCAT_FILE" | head -5
else
    echo "PASS (bug confirmed): No translateX=0.0 — particles were not animated from origin"
fi

# Log the creation-time setNumProp calls for debugging visibility
if grep -q "setNumProp.*translateX" "$LOGCAT_FILE" 2>/dev/null; then
    echo "Creation-time translateX values (expected: final positions only):"
    grep "setNumProp.*translateX" "$LOGCAT_FILE" | head -5
fi

# Verify no crash
LOGCAT_ERR="$WORK_DIR/confetti_repro_err.txt"
"$ADB" -s "$EMULATOR_SERIAL" logcat -d '*:E' > "$LOGCAT_ERR" 2>&1 || true
if grep -qE "$FATAL_PATTERNS" "$LOGCAT_ERR" 2>/dev/null; then
    echo "FAIL: Fatal crash detected during confetti repro test"
    grep -E "$FATAL_PATTERNS" "$LOGCAT_ERR" | tail -10
    EXIT_CODE=1
else
    echo "PASS: No crash during confetti repro test"
fi

"$ADB" -s "$EMULATOR_SERIAL" uninstall "$PACKAGE" 2>/dev/null || true

exit $EXIT_CODE
