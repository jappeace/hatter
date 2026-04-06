# Cross-compile Hackage packages for aarch64-android.
#
# Uses cabal-install with the cross-GHC to build packages offline from
# locally-fetched sources.  The output contains:
#   $out/lib/*.a       — static archives
#   $out/hi/           — interface files (.hi)
#   $out/pkgdb/        — GHC package database (.conf + cache)
#
# Consumers can supply their own dependencies via consumerCabalFile (IFD) or
# consumerCabal2Nix (pre-generated).  When neither is given, builds just
# direct-sqlite for backward compatibility.
{ sources
, consumerCabalFile ? null
, consumerCabal2Nix ? null
, extraPackages ? []
}:
let
  pkgs = import sources.nixpkgs {
    config.allowUnfree = true;
    config.android_sdk.accept_license = true;
  };

  # Cross-compilation toolchain
  androidPkgs = pkgs.pkgsCross.aarch64-android-prebuilt;
  ghc = androidPkgs.haskellPackages.ghc;
  ghcBin = "${ghc}/bin";
  ghcPrefix = ghc.targetPrefix;
  ghcCmd = "${ghcBin}/${ghcPrefix}ghc";
  ghcPkgCmd = "${ghcBin}/${ghcPrefix}ghc-pkg";
  hsc2hsCmd = "${ghcBin}/${ghcPrefix}hsc2hs";

  resolvedDeps = import ./resolve-deps.nix {
    inherit pkgs consumerCabalFile consumerCabal2Nix;
  };

  # Default: just direct-sqlite (backward compat when no consumer cabal given)
  directSqliteSrc = pkgs.fetchurl {
    url = "https://hackage.haskell.org/package/direct-sqlite-2.3.29/direct-sqlite-2.3.29.tar.gz";
    sha256 = "1byhnk4jcv83iw7rqw48p8xk6s2dfs1dh6ibwwzkc9m9lwwcwajz";
  };

  defaultPackages = [{
    pname = "direct-sqlite";
    version = "2.3.29";
    src = directSqliteSrc;
  }];

  packages =
    if resolvedDeps == [] then defaultPackages ++ extraPackages
    else resolvedDeps ++ extraPackages;

in import ./mk-deps.nix {
  inherit sources pkgs ghc ghcCmd ghcPkgCmd hsc2hsCmd packages;
  extraBuildInputs = [ androidPkgs.libffi androidPkgs.gmp ];
  extraCabalBuildFlags = [
    "--extra-lib-dirs=${androidPkgs.gmp}/lib"
    "--extra-lib-dirs=${androidPkgs.libffi}/lib"
  ];
  derivationName = "haskell-mobile-cross-deps";
  perPackageFlags = { direct-sqlite = "-systemlib"; };
}
