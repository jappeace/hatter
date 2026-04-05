# iOS Simulator locale integration test.
#
# Verifies that locale detection works end-to-end on iOS:
#   1. setup_ios_ui_bridge() caches the system locale via setSystemLocale()
#   2. haskellLogLocale() logs the raw and parsed locale via platformLog
#
# Reuses mkSimulatorTest with custom events that match the log output
# from haskellLogLocale in HaskellMobile.Locale.
{ sources ? import ../npins }:
let
  lib = import ./lib.nix { inherit sources; };
  simulatorApp = import ./simulator-app.nix { inherit sources; };
in
lib.mkSimulatorTest {
  inherit simulatorApp;
  bundleId = "me.jappie.haskellmobile";
  scheme = "HaskellMobile";
  name = "haskell-mobile-simulator-locale-test";
  events = [
    "Locale raw:"
    "Locale parsed:"
  ];
}
