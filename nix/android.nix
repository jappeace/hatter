# Android shared library — thin wrapper around lib.nix.
{ sources ? import ../npins
, mainModule ? ../app/MobileMain.hs
, consumerCabalFile ? null
, consumerCabal2Nix ? null
}:
let
  lib = import ./lib.nix { inherit sources; };
  crossDeps = import ./cross-deps.nix {
    inherit sources consumerCabalFile consumerCabal2Nix;
  };
in
lib.mkAndroidLib {
  haskellMobileSrc = ../.;
  inherit mainModule crossDeps;
}
