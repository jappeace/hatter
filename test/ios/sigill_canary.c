// Canary for iOS SIGILL issue #216.
//
// This dot-product loop auto-vectorizes into UDOT (ARMv8.4-A) at -O2
// on Apple Silicon when clang targets the host CPU.  UDOT causes SIGILL
// on pre-A13 devices (A12/A12X lack the instruction).
//
// The iOS build test compiles this with the same toolchain GHC uses and
// checks the disassembly for UDOT.  If found, the build would produce
// binaries that crash on older devices.
#include <stdint.h>

int dotProduct(const uint8_t *a, const uint8_t *b, int n) {
    int sum = 0;
    for (int i = 0; i < n; i++) {
        sum += a[i] * b[i];
    }
    return sum;
}
