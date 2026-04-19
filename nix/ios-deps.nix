# Build Hackage packages with the host GHC for iOS.
#
# iOS builds use the native macOS GHC (not a cross-GHC) — the resulting
# Mach-O is later patched with mac2ios.  Uses nixpkgs haskellPackages
# infrastructure, then collects the results via collect-deps.nix.
#
# Output structure (same as cross-deps.nix):
#   $out/lib/*.a       — static archives
#   $out/pkgdb/        — GHC package database (.conf + cache)
#
# Consumers supply their own dependencies via consumerCabalFile (IFD),
# consumerCabal2Nix (pre-generated), or hpkgs overrides.
{ sources
, consumerCabalFile ? null
, consumerCabal2Nix ? null
, hpkgs ? (_: _: {})       # consumer haskellPackages overrides
}:
let
  pkgs = import sources.nixpkgs {};

  unwitchOverride = self: super: {
    unwitch = self.callCabal2nix "unwitch" (builtins.fetchTarball {
      url = "https://hackage.haskell.org/package/unwitch-2.2.0/unwitch-2.2.0.tar.gz";
      sha256 = "sha256:he/wdUN1XOcEo0VTmJVRrdQnGmZldxgCPCxlSDvzd9c=";
    }) {};
  };

  nativeHaskellPkgs = pkgs.haskellPackages.override {
    overrides = pkgs.lib.composeExtensions unwitchOverride hpkgs;
  };

  ghc = nativeHaskellPkgs.ghc;
  ghcPkgCmd = "${ghc}/bin/ghc-pkg";

  resolvedDeps = import ./resolve-deps.nix {
    inherit pkgs consumerCabalFile consumerCabal2Nix;
    haskellPkgs = nativeHaskellPkgs;
  };

  # Hatter's own non-boot dependencies — always included so mkIOSLib's
  # raw GHC invocation can find them even without a consumer cabal file.
  hatterOwnDeps = [ nativeHaskellPkgs.unwitch ];

in import ./collect-deps.nix {
  inherit pkgs ghc ghcPkgCmd;
  deps = resolvedDeps ++ hatterOwnDeps;
}
