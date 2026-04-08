# Collect pre-built Haskell package outputs into a single directory.
#
# Takes a list of nixpkgs haskellPackages derivations (already built by
# nixpkgs infrastructure), walks their transitive closure via
# propagatedBuildInputs, and collects .conf / .a files into:
#   $out/lib/*.a       — static archives (only those referenced by hs-libraries)
#   $out/pkgdb/        — GHC package database (.conf + cache)
#
# This replaces mk-deps.nix's manual cabal build + conf generation with
# standard nixpkgs outputs.
{ pkgs
, ghcPkgCmd         # full path to ghc-pkg (or cross ghc-pkg)
, deps              # list of haskellPackages derivations
}:
let
  # GHC boot/wired-in packages — already provided by the cross-GHC, so they
  # must not be collected again.  Also excludes haskell-mobile itself
  # (compiled separately in mkAndroidLib/mkIOSLib).
  bootPackageNames = [
    "base" "ghc-prim" "ghc-bignum" "ghc-internal" "integer-gmp"
    "bytestring" "text" "array" "deepseq" "containers"
    "template-haskell" "transformers" "mtl" "stm" "exceptions"
    "filepath" "directory" "process" "unix" "time" "binary"
    "parsec" "pretty" "ghc-boot-th" "ghc-boot" "ghc-heap"
    "hpc" "Cabal" "Cabal-syntax" "os-string"
    "haskell-mobile"
  ];

  isBootPackage = name: builtins.elem name bootPackageNames;

  # Walk propagatedBuildInputs transitively to collect all Haskell deps.
  collectTransitive = seen: drvs:
    builtins.foldl' (acc: drv:
      let name = drv.pname or "";
      in if name == "" || isBootPackage name || builtins.hasAttr name acc
         then acc
         else
           let subDeps = builtins.filter
                 (d: d ? pname && d ? isHaskellLibrary)
                 (drv.propagatedBuildInputs or []);
           in collectTransitive (acc // { "${name}" = drv; }) subDeps
    ) seen drvs;

  allDeps = builtins.attrValues (collectTransitive {} deps);

  depsList = builtins.concatStringsSep " " (map toString allDeps);

in pkgs.runCommand "haskell-mobile-collected-deps" {
  nativeBuildInputs = [ pkgs.findutils ];
} ''
  mkdir -p $out/lib $out/pkgdb

  for pkg in ${depsList}; do
    echo "Processing: $pkg"

    # Copy .conf files, skipping benchmark/test sub-libraries
    for conf in $(find "$pkg" -name "*.conf" -path "*/package.conf.d/*"); do
      LIB_NAME=$(grep '^lib-name:' "$conf" | sed 's/^lib-name: *//' || true)
      case "$LIB_NAME" in
        *benchmark*|*test*) echo "  skip sub-lib: $LIB_NAME"; continue ;;
      esac
      cp "$conf" $out/pkgdb/

      # Copy only .a files referenced by this .conf's hs-libraries field
      HS_LIBS=$(grep '^hs-libraries:' "$conf" | sed 's/^hs-libraries: *//')
      for lib in $HS_LIBS; do
        aFile=$(find "$pkg" -name "lib$lib.a" ! -name "*_p.a" | head -1)
        if [ -n "$aFile" ]; then
          cp "$aFile" $out/lib/
        fi
      done
    done
  done

  ${ghcPkgCmd} --package-db=$out/pkgdb recache

  echo "=== Package database ==="
  ${ghcPkgCmd} --package-db=$out/pkgdb list

  echo "=== Libraries ==="
  ls -lh $out/lib/
''
