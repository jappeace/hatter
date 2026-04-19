/*
 * Run the user's Haskell main after hs_init.
 *
 * GHC compiles Main.main into ZCMain_main_closure, but does not
 * make it callable as a C function.  This wrapper uses the RTS API
 * (rts_evalIO) to evaluate that closure and capture the return value,
 * which is a Ptr AppContext.
 *
 * This removes the need for "foreign export ccall" in the user's
 * Main.hs — they write a plain main :: IO (Ptr AppContext) and we
 * call it, returning the context pointer to the platform bridge.
 */

#include "Rts.h"
#include <stdio.h>

extern void hatterLog(const char *msg);

/* Initialize the GHC RTS with compile-time RTS options.
 * Uses hs_init_ghc() with RtsConfig.rts_opts instead of passing
 * argv to hs_init() — the argv parsing codepath hangs on iOS/watchOS
 * cross-compiled builds.
 *
 * rts_opts: space-separated RTS flags, e.g. "-M512m -xr4G".
 *           -M sets max heap; -xr sets virtual address space reservation
 *           (default 1 TiB — too large for iOS/watchOS).
 *           Pass NULL to use default RTS settings. */
void hatter_hs_init(const char *rts_opts)
{
    char buf[256];
    snprintf(buf, sizeof(buf), "hatter_hs_init: rts_opts=\"%s\"",
             rts_opts ? rts_opts : "(null)");
    hatterLog(buf);

    RtsConfig conf = defaultRtsConfig;
    if (rts_opts) {
        conf.rts_opts_enabled = RtsOptsAll;
        conf.rts_opts = rts_opts;
    }
    hs_init_ghc(NULL, NULL, conf);

    hatterLog("hatter_hs_init: RTS initialized");
}

/* GHC's Z-encoded symbol for :Main.main (the program's main closure) */
extern StgClosure ZCMain_main_closure;

void* haskellRunMain(void)
{
    Capability *cap = rts_lock();
    HaskellObj result;
    rts_evalIO(&cap, &ZCMain_main_closure, &result);
    rts_checkSchedStatus("haskellRunMain", cap);
    void *ctx = rts_getPtr(result);
    rts_unlock(cap);
    return ctx;
}
