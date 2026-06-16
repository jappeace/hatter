# Filtered hatter source tree for the GHC (cross-)builds.
#
# Decision: use lib.fileset.toSource to pin the build inputs to only the
# Haskell-relevant paths. Alternatives considered: passing ../. directly (the
# whole repo, so any Swift, project.yml, nix/, docs or npins change altered the
# source hash and rebuilt the expensive GHC cross-compile from scratch instead
# of pulling it from the community cache, see issue #208), and lib.cleanSource
# (still drags in ios/, watchos/, android/, docs/, makefile, etc.). Keeping the
# fileset explicit means editing a platform or tooling file no longer
# invalidates the cross-compilation cache.
#
# What the (cross-)builds actually read from this tree:
#   src/, include/, cbits/ - library Haskell + C bridge sources (lib.nix)
#   hatter.cabal           - callCabal2nix in cross-deps.nix
#   LICENSE                - the cabal declares license-file: LICENSE, so the
#                            Setup copy phase fails without it; not Haskell, but
#                            required for the build to succeed.
#   nix/mac2ios.nix,       - mkIOSLib / mkWatchOSLib import these from hatterSrc
#   nix/mac2watchos.nix      (lib.nix:560,798) to build the Mach-O platform-tag
#                            patchers. Included as individual files, NOT the
#                            whole nix/ dir, so editing lib.nix or any other nix
#                            file still does not invalidate the cross cache.
#                            mac2watchos.nix compiles cbits/mac2watchos.c (in
#                            the cbits/ tree above); mac2ios.nix builds from
#                            sources.mobile-core-tools. Both are imported with
#                            sources and pkgs supplied, so their ../npins
#                            defaults never resolve against this tree.
# test/ is deliberately excluded: cross-deps.nix strips the executable and
# test-suite stanzas (they cannot link on the target), and the iOS/watchOS
# wrappers pass their entry module through mainModule, not this tree.
{ sources ? import ../npins
,
}:
let
  pkgs = import ./pkgs.nix { inherit sources; };
in
pkgs.lib.fileset.toSource {
  root = ../.;
  fileset = pkgs.lib.fileset.unions [
    ../src
    ../cbits
    ../include
    ../hatter.cabal
    ../LICENSE
    ../nix/mac2ios.nix
    ../nix/mac2watchos.nix
  ];
}
