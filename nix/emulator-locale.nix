# Android emulator locale integration test.
#
# Verifies that locale detection works end-to-end on Android:
#   1. JNI_OnLoad caches the system locale via setSystemLocale()
#   2. haskellLogLocale() logs the raw and parsed locale via platformLog
#
# Reuses mkEmulatorTest with custom events that match the log output
# from haskellLogLocale in HaskellMobile.Locale.
{ sources ? import ../npins }:
let
  lib = import ./lib.nix { inherit sources; };
  apk = import ./apk.nix { inherit sources; };
in
lib.mkEmulatorTest {
  inherit apk;
  apkFileName = "haskell-mobile.apk";
  packageName = "me.jappie.haskellmobile";
  name = "haskell-mobile-emulator-locale-test";
  events = [
    "Locale raw:"
    "Locale parsed:"
  ];
}
