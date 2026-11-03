# A shell for building pages with build.sh: GHC's wasm toolchain, which
# brings the Node.js the Angular host needs too, and Chromium for the tests
# in test/browser.
{ sources ? import ../npins
, pkgs ? import ../nix/pkgs.nix { inherit sources; }
}:
let
  ghcWasm = (builtins.getFlake "gitlab:haskell-wasm/ghc-wasm-meta/8079eb96bbc63823d99ad8acaff0765532625474?host=gitlab.haskell.org").packages.${pkgs.stdenv.hostPlatform.system};
in
pkgs.mkShell {
  packages = [ ghcWasm.all_9_14 pkgs.chromium ];
  CHROME = pkgs.lib.getExe pkgs.chromium;
}
