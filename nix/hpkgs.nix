{ pkgs ? import ./pkgs.nix { }
,
}:
# you can pin a specific ghc version with
# pkgs.haskell.packages.ghc984 for example.
# this allows you to create multiple compiler targets via nix.
pkgs.haskellPackages.override {
  overrides = hnew: hold: {
    # NB this is a bit silly because nix files are now considered for the build
    # bigger projects should consider putting haskell stuff in a subfolder
    hatter-project = hnew.callCabal2nix "hatter" ../. { };
    unwitch = hnew.callCabal2nix "unwitch" (builtins.fetchTarball {
      url = "https://github.com/jappeace/unwitch/archive/2759bdd153f293e0e6524d0170e861e51302caa4.tar.gz";
      sha256 = "sha256:BGxZ1CQGIYP/gg/J9jua2/wSEH4qq7bW91qooNELUlI=";
    }) {};
  };
}
