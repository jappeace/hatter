# Staged iOS simulator app sources.
#
# Bundles everything needed to build the iOS app for the simulator:
# - Pre-built Haskell static library (from ios.nix with simulator=true)
# - Swift/ObjC sources from ios/HaskellMobile/
# - C headers (HaskellMobile.h, UIBridge.h)
# - project.yml for xcodegen
#
# Does NOT run xcodegen/xcodebuild (requires Xcode, not in Nix sandbox).
# Consumer test scripts (simulator.nix, simulator-ui.nix) handle the build.
#
# Usage:
#   simulatorApp = import ./simulator-app.nix { inherit sources; };
#   # Then reference ${simulatorApp}/share/ios/...
{ sources ? import ../npins }:
let
  pkgs = import sources.nixpkgs {};

  iosLib = import ./ios.nix { inherit sources; simulator = true; };

in pkgs.stdenv.mkDerivation {
  name = "haskell-mobile-simulator-app";

  dontUnpack = true;

  buildPhase = ''
    mkdir -p $out/share/ios/lib $out/share/ios/include

    # Stage Swift + ObjC sources
    cp -r ${../ios}/HaskellMobile $out/share/ios/
    cp ${../ios/project.yml} $out/share/ios/project.yml

    # Stage pre-built Haskell library + headers
    cp ${iosLib}/lib/libHaskellMobile.a $out/share/ios/lib/
    cp ${iosLib}/include/HaskellMobile.h $out/share/ios/include/
    cp ${iosLib}/include/UIBridge.h $out/share/ios/include/
  '';

  installPhase = "true";
}
