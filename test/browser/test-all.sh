#!/usr/bin/env bash
# Browser test: builds the demo page and drives it in headless Chromium
# (test.mjs). From browser/shell.nix, which sets CHROME:
#
#   nix-shell -I nixpkgs=nix/pkgs.nix browser/shell.nix --run test/browser/test-all.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
page=$(mktemp -d)
trap 'rm -rf "$page"' EXIT

# Hatter's dependencies that GHC doesn't come with are Hackage's.
(cd "$here/../../browser" && wasm32-wasi-cabal update)
"$here/../../browser/build.sh" hatter-browser-demo "$page"
(cd "$here" && npm ci --no-audit --no-fund)
node "$here/test.mjs" "$CHROME" "$page"
