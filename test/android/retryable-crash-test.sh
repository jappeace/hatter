#!/usr/bin/env bash
# Asserts retryable-crash.sh classifies crashes correctly.
# Pure log classification: no emulator or device needed, so it runs as a cheap
# nix check (ci.nix: retry-classification-test) in the normal build job.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
classify="$here/retryable-crash.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0

# expect EXPECTED_EXIT LABEL FIXTURE_FILE
expect() {
    local expected="$1" label="$2" fixture="$3"
    local rc=0
    bash "$classify" "$fixture" || rc=$?
    if [ "$rc" -ne "$expected" ]; then
        echo "FAIL: $label (expected exit $expected, got $rc)"
        failures=$((failures + 1))
    else
        echo "ok: $label (exit $rc)"
    fi
}

# The real ndk_translation SIGSEGV flake (issue #208): must be retryable.
cat > "$tmp/translation.log" <<'EOF'
=== FATAL: App crashed ===
F libc    : Fatal signal 11 (SIGSEGV), code 2 (SEGV_ACCERR), fault addr 0x70a481c43c74 in tid 6973 (e.jappie.hatter)
F DEBUG   :       #01 pc 0000000000208e30  /system/lib64/libndk_translation.so (ndk_translation_HandleNoExec+208)
FATAL: App crashed before rendering, aborting lifecycle
EOF
expect 0 "ndk_translation SIGSEGV is retryable" "$tmp/translation.log"

# A genuine native-library load failure: deterministic, must not retry.
cat > "$tmp/load.log" <<'EOF'
E AndroidRuntime: java.lang.UnsatisfiedLinkError: dlopen failed: library "libhatter.so" not found
FATAL: Native library failed to load, aborting
EOF
expect 1 "UnsatisfiedLinkError is not retryable" "$tmp/load.log"

# A deliberate abort (RTS panic / assertion): deterministic, must not retry.
cat > "$tmp/abort.log" <<'EOF'
F libc    : Fatal signal 6 (SIGABRT), code -1 in tid 100 (e.jappie.hatter)
FATAL: App crashed before rendering, aborting node-pool
EOF
expect 1 "SIGABRT is not retryable" "$tmp/abort.log"

if [ "$failures" -ne 0 ]; then
    echo "retryable-crash classification test FAILED ($failures case(s))"
    exit 1
fi
echo "retryable-crash classification test passed"
