# iOS simulator SQLite test — verifies database write/read on simulator.
{ sources ? import ../npins }:
let
  lib = import ./lib.nix { inherit sources; };

  iosLib = lib.mkIOSLib {
    haskellMobileSrc = ../.;
    mainModule = ../test/DbTestMain.hs;
    simulator = true;
    pname = "haskell-mobile-ios-db-test";
  };

  simulatorApp = lib.mkSimulatorApp {
    inherit iosLib;
    iosSrc = ../ios;
    name = "haskell-mobile-simulator-db-app";
  };
in
lib.mkSimulatorTest {
  inherit simulatorApp;
  bundleId = "me.jappie.haskellmobile";
  scheme = "HaskellMobile";
  events = [ "Lifecycle: Create" "SQLite roundtrip OK" ];
  name = "haskell-mobile-simulator-db-test";
}
