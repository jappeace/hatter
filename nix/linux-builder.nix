# pkgs.darwin.linux-builder: a small NixOS VM that runs on a macOS host and
# registers as a remote builder for *-linux derivations.  We use it to build
# the Android APK (a Linux-host cross-compile) from a macOS CI runner with a
# single `nix build`, since native Android cross-compilation does not work on
# a Darwin host (see docs/android-apk-on-macos.md).
#
# On an x86_64-darwin host this yields an x86_64-linux builder.  We keep the
# config at its default so the VM closure substitutes from cache.nixos.org
# instead of having to be built (which would itself need a Linux builder).
{ sources ? import ../npins }:
(import sources.nixpkgs { }).darwin.linux-builder
