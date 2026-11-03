{ pkgs ? import ./pkgs.nix { }
,
}:
# you can pin a specific ghc version with
# pkgs.haskell.packages.ghc984 for example.
# this allows you to create multiple compiler targets via nix.
(import ./ghc.nix pkgs).override {
  overrides = hnew: hold: {
    # NB this is a bit silly because nix files are now considered for the build
    # bigger projects should consider putting haskell stuff in a subfolder
    hatter-project = hnew.callCabal2nix "hatter" ../. { };
    # The terminal platform, with its unit tests.
    hatter-terminal = hnew.callCabal2nix "hatter-terminal" (pkgs.lib.fileset.toSource {
      root = ../terminal;
      fileset = pkgs.lib.fileset.unions [
        ../terminal/hatter-terminal.cabal
        ../terminal/src
        ../terminal/cbits
        ../terminal/test
      ];
    }) { hatter = hnew.hatter-project; };
    # The Qt Quick desktop platform and its demo, on the host built with
    # its tests. The demo is built to check it compiles, not run, so it
    # isn't wrapped with Qt's paths. Of the host's pkg-config modules only
    # its own, not all of Qt's and theirs, whose flags outgrow what a
    # compiler can be given.
    hatter-desktop = (pkgs.haskell.lib.overrideCabal (hnew.callCabal2nix "hatter-desktop" (pkgs.lib.fileset.toSource {
      root = ../desktop;
      fileset = pkgs.lib.fileset.unions [
        ../desktop/hatter-desktop.cabal
        ../desktop/src
        ../desktop/cbits
        ../desktop/demo
      ];
    }) {
      hatter = hnew.hatter-project;
      hatter-qt-host = pkgs.callPackage ../desktop/host.nix { include = ../include; };
    }) { __onlyPropagateKnownPkgConfigModules = true; }).overrideAttrs { dontWrapQtApps = true; };
    # Hackage's revision 2 allows GHC 9.14's containers 0.8; nixpkgs still has
    # revision 1.
    config-ini = pkgs.haskell.lib.overrideCabal hold.config-ini {
      revision = "2";
      editedCabalFile = "0djfq7v7b0fhxyzap9m4jrsii3z56fznsx8b3nv28bvp2gajvv6a";
    };
    # 2.9 doesn't allow GHC 9.14's base.
    brick = hnew.brick_2_12;
    unwitch = hnew.callCabal2nix "unwitch" (builtins.fetchTarball {
      url = "https://github.com/jappeace/unwitch/archive/2759bdd153f293e0e6524d0170e861e51302caa4.tar.gz";
      sha256 = "sha256:BGxZ1CQGIYP/gg/J9jua2/wSEH4qq7bW91qooNELUlI=";
    }) {};
  };
}
