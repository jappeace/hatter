# Build Hackage packages with the host GHC for iOS.
#
# iOS builds use the native macOS GHC (not a cross-GHC) — the resulting
# Mach-O is later patched with mac2ios.  This means we can build Hackage
# deps the simple way: just run cabal with the host compiler.
#
# Output structure (same as cross-deps.nix):
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
  pkgs = import sources.nixpkgs {};

  ghc = pkgs.haskellPackages.ghc;
  ghcCmd = "${ghc}/bin/ghc";
  ghcPkgCmd = "${ghc}/bin/ghc-pkg";
  hsc2hsCmd = "${ghc}/bin/hsc2hs";

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
  derivationName = "haskell-mobile-ios-deps";
  perPackageFlags = { direct-sqlite = "-systemlib"; };
}
