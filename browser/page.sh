#!/bin/sh
# Builds a page running a Hatter app's wasm: the Angular host, the app as
# app.wasm and the JavaScript GHC makes for it. From a shell with
# wasm32-wasi-ghc and node (shell.nix).
set -eu

wasm=$1
out=$2
here=$(cd "$(dirname "$0")" && pwd)

# The JavaScript Sass, as the native one npm brings doesn't run on NixOS.
(cd "$here/host" && npm ci --no-audit --no-fund && NG_BUILD_SASS_EMBEDDED=0 npx ng build)

mkdir -p "$out"
cp -r "$here/host/dist/." "$out/"
"$(wasm32-wasi-ghc --print-libdir)/post-link.mjs" -i "$wasm" -o "$out/ghc_wasm_jsffi.js"
cp "$wasm" "$out/app.wasm"
