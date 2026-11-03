# Android APK entry point.
#
# `nix-build nix/apk.nix` produces hatter.apk on any host:
#   - Linux: build the cross-compiled APK natively (apk-linux.nix).
#   - macOS: the Android cross-compile does not work on a Darwin build host
#     (see docs/android-apk-on-macos.md), so build it inside a Linux VM that is
#     spun up automatically by the derivation (apk-darwin-vm.nix).  No remote
#     builder configuration is required -- a plain `nix-build nix/apk.nix` works.
#
# The Darwin wrapper copies this repo into the VM and runs `nix-build
# nix/apk.nix` there; inside the VM the host is Linux, so it takes the native
# branch -- there is no recursion.
{ sources ? import ../npins }:
# Decided without the project's nixpkgs, which no longer evaluates on Intel
# Macs.
if builtins.match ".*-darwin" builtins.currentSystem != null
then import ./apk-darwin-vm.nix { inherit sources; }
else import ./apk-linux.nix { inherit sources; }
