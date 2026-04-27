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
, hatterSrc ? null          # hatter source tree (builds hatter as a normal dep)
, deviceCpu ? "apple-a12"  # minimum CPU target for C compilations (issue #216)
}:
let
  pkgs = import sources.nixpkgs {};

  unwitchOverride = self: super: {
    unwitch = self.callCabal2nix "unwitch" (builtins.fetchTarball {
      url = "https://github.com/jappeace/unwitch/archive/2759bdd153f293e0e6524d0170e861e51302caa4.tar.gz";
      sha256 = "sha256:BGxZ1CQGIYP/gg/J9jua2/wSEH4qq7bW91qooNELUlI=";
    }) {};
  };

  # Build hatter as a regular haskellPackages derivation from local source.
  # Executables and tests are stripped to avoid pulling in test-framework deps.
  hatterOverride = self: super:
    if hatterSrc != null then {
      hatter = pkgs.haskell.lib.overrideCabal
        (self.callCabal2nix "hatter" hatterSrc {})
        (old: {
          postPatch = (old.postPatch or "") + ''
            sed -i '/^executable /,$d' hatter.cabal
            sed -i '/^test-suite /,$d' hatter.cabal
          '';
          doCheck = false;
        });
    } else {};

  # Issue #216: Inject -mcpu into C compilations of Haskell dependencies
  # (e.g. sqlite3.c in direct-sqlite) to avoid ARMv8.4+ instructions.
  deviceCpuOverride = self: super:
    if deviceCpu != null then {
      mkDerivation = args: super.mkDerivation (args // {
        configureFlags = (args.configureFlags or []) ++ [
          "--ghc-option=-optc-mcpu=${deviceCpu}"
        ];
      });
    } else {};

  nativeHaskellPkgs = pkgs.haskellPackages.override {
    overrides = pkgs.lib.composeManyExtensions [
      unwitchOverride
      hatterOverride
      deviceCpuOverride
      hpkgs
    ];
  };

  ghc = nativeHaskellPkgs.ghc;
  ghcPkgCmd = "${ghc}/bin/ghc-pkg";

  resolvedDeps = import ./resolve-deps.nix {
    inherit pkgs consumerCabalFile consumerCabal2Nix;
    haskellPkgs = nativeHaskellPkgs;
  };

  # When hatterSrc is provided, add the hatter package to the collected deps
  # so its .a and .conf are available for linking.
  hatterDep = if hatterSrc != null then [ nativeHaskellPkgs.hatter ] else [];

  # Hatter's own non-boot dependencies — always included so mkIOSLib's
  # raw GHC invocation can find them even without a consumer cabal file.
  hatterOwnDeps = [ nativeHaskellPkgs.unwitch ];

in import ./collect-deps.nix {
  inherit pkgs ghc ghcPkgCmd;
  deps = resolvedDeps ++ hatterDep ++ hatterOwnDeps;
}
