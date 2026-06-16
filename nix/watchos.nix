# watchOS static library — thin wrapper around lib.nix.
{ sources ? import ../npins
, simulator ? false
, mainModule ? ../test/ScrollDemoMain.hs
, consumerCabalFile ? null
, consumerCabal2Nix ? null
, hpkgs ? (_: _: {})       # consumer haskellPackages overrides
, deviceCpu ? null          # optional CPU target for device builds (issue #216)
}:
let
  lib = import ./lib.nix { inherit sources deviceCpu; };
  iosDeps = import ./ios-deps.nix {
    inherit sources consumerCabalFile consumerCabal2Nix hpkgs deviceCpu;
    hatterSrc = ../.;
  };
in
lib.mkWatchOSLib {
  # Filtered source, not ../. , so platform-file edits don't bust the
  # cross-compile cache (see nix/hatter-src.nix and issue #208).
  hatterSrc = import ./hatter-src.nix { inherit sources; };
  inherit mainModule simulator;
  crossDeps = iosDeps;
}
