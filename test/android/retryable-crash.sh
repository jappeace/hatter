#!/usr/bin/env bash
# retryable-crash.sh OUTPUT_FILE
#
# Classifies a detected Android app crash so the test harness (run_with_retry in
# nix/emulator-all.nix) knows whether retrying is worthwhile. It is only called
# once a "^FATAL:" line has already been seen in OUTPUT_FILE, so a crash did
# happen; this decides whether that crash is transient or deterministic.
#
# Why this exists: the CI emulator is x86_64, but the app ships arm64-v8a /
# armeabi-v7a native code, so every native call runs under the emulator's
# ARM->x86 binary-translation layer. That layer intermittently SIGSEGVs in
# ndk_translation_HandleNoExec (issue #208) while managing its JIT code cache;
# the identical APK passes on a re-run, so such a crash is a flake worth
# retrying. A native library that fails to LOAD, or a deliberate abort, fails
# the same way on every attempt, so retrying it only wastes CI minutes.
#
# Exit 0: transient, retry.
# Exit 1: deterministic, do not retry.
set -u

output_file="${1:?usage: retryable-crash.sh OUTPUT_FILE}"

# Deterministic failures: a missing/unloadable native library, an unresolved
# symbol, or a deliberate abort (RTS panic, assertion) recur every attempt.
if grep -qE "UnsatisfiedLinkError|dlopen failed|cannot locate symbol|SIGABRT" "$output_file" 2>/dev/null; then
    exit 1
fi

# A runtime segfault on this translated emulator is dominated by the
# ndk_translation flake. Treat any SIGSEGV / fatal signal as retryable.
if grep -qE "SIGSEGV|Fatal signal" "$output_file" 2>/dev/null; then
    exit 0
fi

# Any other unrecognised FATAL: be conservative and do not retry.
exit 1
