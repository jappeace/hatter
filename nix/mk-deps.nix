# Shared builder for cross-compiling Hackage packages.
#
# Both cross-deps.nix (Android) and ios-deps.nix (macOS/iOS) call this with
# their respective toolchain parameters.  The output contains:
#   $out/lib/*.a       — static archives
#   $out/hi/           — interface files (.hi)
#   $out/pkgdb/        — GHC package database (.conf + cache)
#
# packages: list of { pname, version, src } to build
{ sources
, pkgs
, ghc
, ghcCmd
, ghcPkgCmd
, hsc2hsCmd
, extraNativeBuildInputs ? []
, extraBuildInputs ? []
, extraCabalBuildFlags ? []
, derivationName ? "haskell-mobile-cross-deps"
, packages                                      # [ { pname, version, src } ]
, perPackageFlags ? {}                           # e.g. { direct-sqlite = "-systemlib"; }
}:
let
  wrapperProject = ./deps-wrapper;
  cabalConfig = ./cabal-config;

  # Fetch source tarballs for each package from Hackage.
  # If src is already a path/derivation, use it directly.
  packageSources = map (pkg: {
    inherit (pkg) pname version;
    src = pkg.src;
    dir = "${pkg.pname}-${pkg.version}";
  }) packages;

  # Generate the build-depends line for deps-wrapper.cabal
  buildDependsLine = builtins.concatStringsSep ", "
    (["base"] ++ map (pkg: pkg.pname) packages);

  # Generate cabal.project package lines
  packageDirLines = builtins.concatStringsSep "\n"
    (map (pkg: "          $TMPDIR/deps/${pkg.dir}/") packageSources);

  # Generate cabal.project per-package flag stanzas
  packageFlagStanzas = builtins.concatStringsSep "\n"
    (builtins.attrValues (builtins.mapAttrs (name: flags:
      "package ${name}\n  flags: ${flags}"
    ) perPackageFlags));

in pkgs.stdenv.mkDerivation {
  name = derivationName;

  dontUnpack = true;

  nativeBuildInputs = [ ghc pkgs.cabal-install ] ++ extraNativeBuildInputs;
  buildInputs = extraBuildInputs;

  buildPhase = ''
    export HOME=$TMPDIR/home
    mkdir -p $HOME

    # --- Pre-create cabal config to prevent network access ---
    mkdir -p $HOME/.config/cabal
    cp ${cabalConfig} $HOME/.config/cabal/config

    # Create an empty package index so cabal doesn't try to download one.
    mkdir -p $HOME/.local/state/cabal/repo/hackage.haskell.org
    tar cf $HOME/.local/state/cabal/repo/hackage.haskell.org/01-index.tar --files-from /dev/null
    cp $HOME/.local/state/cabal/repo/hackage.haskell.org/01-index.tar \
       $HOME/.local/state/cabal/repo/hackage.haskell.org/01-index.tar.idx 2>/dev/null || true

    # --- Unpack package sources ---
    mkdir -p $TMPDIR/deps
    cd $TMPDIR/deps
    ${builtins.concatStringsSep "\n" (map (pkg: ''
    tar xzf ${pkg.src}
    '') packageSources)}

    # --- Patch out build-tool-depends: hsc2hs from ALL packages ---
    # Cabal tries to cross-compile hsc2hs, producing an ARM binary that
    # can't run on the build host.  The cross-GHC's hsc2hs is already
    # available via --with-hsc2hs.
    for CABAL_FILE in $(find $TMPDIR/deps -name '*.cabal'); do
      sed -i 's/^  build-tool-depends:.*hsc2hs.*/  -- &/' "$CABAL_FILE"
    done

    # --- Create a wrapper cabal project ---
    cp -r ${wrapperProject} $TMPDIR/project
    chmod -R u+w $TMPDIR/project
    cd $TMPDIR/project

    # Rewrite deps-wrapper.cabal with all packages in build-depends
    cat > deps-wrapper.cabal << 'CABALEOF'
    cabal-version: 3.0
    name:          deps-wrapper
    version:       0.1
    build-type:    Simple

    library
      default-language: Haskell2010
      build-depends: ${buildDependsLine}
    CABALEOF

    cat > cabal.project << EOF
    packages: .
    ${packageDirLines}

    ${packageFlagStanzas}

    tests: False
    benchmarks: False
    EOF

    # --- Create symlinks so cabal finds cross tools by short name ---
    mkdir -p $TMPDIR/cross-bin
    ln -s ${ghcCmd} $TMPDIR/cross-bin/ghc
    ln -s ${ghcPkgCmd} $TMPDIR/cross-bin/ghc-pkg
    ln -s ${hsc2hsCmd} $TMPDIR/cross-bin/hsc2hs

    # --- Build all packages ---
    PATH="$TMPDIR/cross-bin:$(dirname ${ghcCmd}):$PATH" \
    cabal build --offline \
      --with-compiler=${ghcCmd} \
      --with-hc-pkg=${ghcPkgCmd} \
      --with-hsc2hs=${hsc2hsCmd} \
      ${builtins.concatStringsSep " " extraCabalBuildFlags} \
      ${builtins.concatStringsSep " " (map (pkg: "lib:${pkg.pname}") packages)}
  '';

  installPhase = ''
    mkdir -p $out/lib $out/hi $out/pkgdb

    # --- Generic install: iterate over all built packages ---
    for PKG_DIR in $TMPDIR/project/dist-newstyle/build/*/ghc-*/*-*/; do
      PKG_BASE=$(basename "$PKG_DIR")

      # Derive package name (handles hyphenated names like direct-sqlite)
      PKG_NAME=$(echo "$PKG_BASE" | sed 's/-[0-9][0-9.]*$//')

      # Skip the deps-wrapper package
      [ "$PKG_NAME" = "deps-wrapper" ] && continue

      BUILD="$PKG_DIR/build"
      [ ! -d "$BUILD" ] && continue

      echo "=== Installing $PKG_NAME from $PKG_DIR ==="

      # 1. Copy .a files
      find "$BUILD" -maxdepth 1 -name 'libHS*.a' -exec cp {} $out/lib/ \;

      # 2. Copy .hi files preserving module hierarchy
      find "$BUILD" -name '*.hi' -not -path '*/autogen/*' | while read hiFile; do
        REL=$(realpath --relative-to="$BUILD" "$hiFile")
        mkdir -p "$out/hi/$(dirname "$REL")"
        cp "$hiFile" "$out/hi/$REL"
      done

      # 3. Discover exposed modules from .hi file paths
      MODULES=$(find "$BUILD" -name '*.hi' -not -path '*/autogen/*' \
        -printf '%P\n' | sed 's|/|.|g; s|\.hi$||' | sort | tr '\n' ' ')

      # 4. Get unit ID from .a filename
      A_FILE=$(find "$BUILD" -maxdepth 1 -name 'libHS*.a' -printf '%f\n' | head -1)
      [ -z "$A_FILE" ] && continue
      UNIT_ID=''${A_FILE#libHS}
      UNIT_ID=''${UNIT_ID%.a}

      # 5. Get version from directory name (handles hyphenated names like direct-sqlite)
      PKG_VERSION=$(echo "$PKG_BASE" | sed -n 's/.*-\([0-9][0-9.]*\)$/\1/p')

      # 6. Resolve boot dep IDs and generate .conf
      BASE_ID=$(${ghcPkgCmd} field base id --simple-output 2>/dev/null || echo "base")
      BYTESTRING_ID=$(${ghcPkgCmd} field bytestring id --simple-output 2>/dev/null || echo "bytestring")
      TEXT_ID=$(${ghcPkgCmd} field text id --simple-output 2>/dev/null || echo "text")
      TRANSFORMERS_ID=$(${ghcPkgCmd} field transformers id --simple-output 2>/dev/null || echo "transformers")
      CONTAINERS_ID=$(${ghcPkgCmd} field containers id --simple-output 2>/dev/null || echo "containers")

      # Build a depends list from cross-compiled sibling packages (use unit IDs
      # we've already installed) plus boot packages.
      # For simplicity, list common boot deps — GHC ignores unknown ones.
      DEPENDS="$BASE_ID $BYTESTRING_ID $TEXT_ID $TRANSFORMERS_ID $CONTAINERS_ID"

      # Add cross-compiled sibling deps: scan for matching .a files
      for SIBLING_A in $out/lib/libHS*.a; do
        SIBLING_FILE=$(basename "$SIBLING_A")
        SIBLING_ID=''${SIBLING_FILE#libHS}
        SIBLING_ID=''${SIBLING_ID%.a}
        DEPENDS="$DEPENDS $SIBLING_ID"
      done

      HS_LIB=''${A_FILE#lib}
      HS_LIB=''${HS_LIB%.a}

      cat > $out/pkgdb/$PKG_NAME.conf << CONF
name: $PKG_NAME
version: $PKG_VERSION
id: $UNIT_ID
key: $UNIT_ID
exposed: True
exposed-modules: $MODULES
import-dirs: $out/hi
library-dirs: $out/lib
hs-libraries: $HS_LIB
depends:
    $DEPENDS
CONF
    done

    ${ghcPkgCmd} --package-db=$out/pkgdb recache

    echo "=== Package database ==="
    ${ghcPkgCmd} --package-db=$out/pkgdb list

    echo "=== Libraries ==="
    ls -lh $out/lib/

    echo "=== Interface files ==="
    find $out/hi -name '*.hi' | head -20
  '';
}
