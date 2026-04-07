#!/usr/bin/env bash
# Common helper functions for iOS simulator test scripts.
# Source this file; do not run directly.
#
# Required env vars (set by simulator-all.nix harness):
#   SIM_UDID    — simulator UUID
#   BUNDLE_ID   — me.jappie.haskellmobile
#   WORK_DIR    — temp dir for log files

# Fatal patterns that indicate the native library failed to load on iOS.
# When any of these appear in the log, further retries are pointless.
IOS_FATAL_PATTERNS="dyld: Library not loaded|Symbol not found|image not found|SIGABRT|SIGSEGV|Fatal signal|EXC_BAD_ACCESS|EXC_CRASH"

# check_fatal_log LOGFILE
# Checks log file for fatal native-library errors.
# If found, prints the relevant lines and returns 0 (meaning "fatal found").
# Returns 1 if no fatal error detected.
check_fatal_log() {
    local logfile="$1"
    if grep -qE "$IOS_FATAL_PATTERNS" "$logfile" 2>/dev/null; then
        echo ""
        echo "=== FATAL: Native library loading error detected ==="
        grep -E "$IOS_FATAL_PATTERNS" "$logfile" | tail -20
        echo "=== End fatal log ==="
        echo ""
        return 0
    fi
    return 1
}

# dump_ios_log LOGFILE LABEL
# Dumps recent log lines to stdout for CI visibility.
dump_ios_log() {
    local logfile="$1"
    local label="$2"
    echo ""
    echo "=== Log dump ($label) — last 40 lines ==="
    tail -40 "$logfile"
    echo "=== End log dump ==="
    echo ""
}

# wait_for_log LOGFILE PATTERN TIMEOUT_SECONDS
# Polls LOGFILE for PATTERN every 2s.
# Also checks for fatal native-library errors each poll cycle.
# Returns 0 on success, 1 on timeout, 2 on fatal crash detected.
wait_for_log() {
    local logfile="$1"
    local pattern="$2"
    local timeout_seconds="$3"
    local elapsed=0
    while [ $elapsed -lt "$timeout_seconds" ]; do
        if grep -q "$pattern" "$logfile" 2>/dev/null; then
            echo "Found '$pattern' after ~${elapsed}s"
            return 0
        fi
        # Check for fatal errors every 10s
        if [ $((elapsed % 10)) -eq 0 ] && [ $elapsed -gt 0 ]; then
            if check_fatal_log "$logfile"; then
                echo "ERROR: Fatal crash detected while waiting for '$pattern'"
                return 2
            fi
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    echo "WARNING: '$pattern' not found after ${timeout_seconds}s"
    # One last check: was it a crash?
    if check_fatal_log "$logfile"; then
        return 2
    fi
    return 1
}

# assert_log LOGFILE PATTERN LABEL
# Greps LOGFILE for PATTERN, prints PASS/FAIL with LABEL.
# Sets EXIT_CODE=1 on failure (EXIT_CODE must be declared in caller).
assert_log() {
    local logfile="$1"
    local pattern="$2"
    local label="$3"
    if grep -qE "$pattern" "$logfile" 2>/dev/null; then
        echo "PASS: $label"
    else
        echo "FAIL: $label"
        EXIT_CODE=1
    fi
}

# get_full_log START_TIME OUTFILE
# Retrieves persistent log entries since START_TIME for BUNDLE_ID into OUTFILE.
get_full_log() {
    local start_time="$1"
    local outfile="$2"
    xcrun simctl spawn "$SIM_UDID" log show \
        --start "$start_time" \
        --predicate "subsystem == \"$BUNDLE_ID\"" \
        --style compact \
        --info \
        > "$outfile" 2>&1 || true
}
