#!/bin/sh
# Builds a page running one of this package's apps (see page.sh). From a
# shell with wasm32-wasi-cabal and node (shell.nix).
set -eu

exe=$1
out=$2
here=$(cd "$(dirname "$0")" && pwd)

(cd "$here" && wasm32-wasi-cabal build "exe:$exe")
"$here/page.sh" "$(cd "$here" && wasm32-wasi-cabal list-bin "exe:$exe")" "$out"
