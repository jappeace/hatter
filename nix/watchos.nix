# watchOS static library — thin wrapper around lib.nix.
{ sources ? import ../npins
, simulator ? false
, mainModule ? ../test/ScrollDemoMain.hs
, consumerCabalFile ? null
, consumerCabal2Nix ? null
, hpkgs ? (_: _: {})       # consumer haskellPackages overrides
, deviceCpu ? "apple-a12"  # minimum CPU target for device builds (issue #216)
}:
let
  lib = import ./lib.nix { inherit sources; };
  iosDeps = import ./ios-deps.nix {
    inherit sources consumerCabalFile consumerCabal2Nix hpkgs deviceCpu;
    hatterSrc = ../.;
  };
in
lib.mkWatchOSLib {
  hatterSrc = ../.;
  inherit mainModule simulator deviceCpu;
  crossDeps = iosDeps;
}
