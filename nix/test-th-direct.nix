# Integration test: build an Android library with consumer-side TH.
#
# Unlike test-th.nix (TH in a dependency package), this tests TH splices
# directly in consumer code compiled by mkAndroidLib.  Requires the
# iserv-proxy wrapper threaded through crossDeps.
{ sources ? import ../npins }:
import ./android.nix {
  inherit sources;
  mainModule = ../test/THDirectMain.hs;
}
