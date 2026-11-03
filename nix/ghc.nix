# The GHC that Hatter and its apps build with, on the host and on every
# phone and watch. The browser's wasm GHC and the ghcup jobs in CI use the
# same version. 9.14 is the first whose RTS gives up on a heap reservation
# below 8 GB instead of asking for the same one forever, which hung hTox at
# start on a Pixel 9.
pkgs:
let
  hpkgs = pkgs.haskell.packages.ghc914;

  # GHC 9.14 rebuilds its target triple from the architecture and OS, and
  # has no Android OS, so a GHC for Android says its target is
  # aarch64-unknown-linux. Cabal takes the OS from that, so os(android)
  # conditions in cabal files are false (direct-sqlite then asks for a
  # libpthread that Android doesn't have). Put back the full triple, as 9.10
  # gave it.
  android = hpkgs.ghc.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      sed -i 's|("target platform string","[^"]*")|("target platform string","${pkgs.stdenv.hostPlatform.config}")|' \
        "$out/lib/${hpkgs.ghc.targetPrefix}ghc-${hpkgs.ghc.version}/lib/settings"
    '';
  });
in
if pkgs.stdenv.hostPlatform.isAndroid then hpkgs.override { ghc = android; } else hpkgs
