# pkgs.darwin.linux-builder: a small NixOS VM that runs on a macOS host and
# registers as a remote builder for *-linux derivations.  We use it to build
# the Android APK (a Linux-host cross-compile) from a macOS CI runner with a
# single `nix build`, since native Android cross-compilation does not work on
# a Darwin host (see docs/android-apk-on-macos.md).
#
# On an x86_64-darwin host this yields an x86_64-linux builder.  We keep the
# config at its default so the VM closure substitutes from cache.nixos.org
# instead of having to be built (which would itself need a Linux builder).
#
# It is pinned to a *stable* nixpkgs (nixpkgs-linux-builder, nixos-25.05), not
# the project's unstable pin: the default darwin.linux-builder closure for the
# unstable pin is not on cache.nixos.org, so building it would require the very
# Linux builder we are trying to create.  A stable release is fully cached and
# substitutes cleanly.  The builder's nixpkgs is independent of the APK build
# (the APK derivation still comes from the project's pin, evaluated client-side
# and offloaded to the VM).
#
# Decision: drive the Android APK build from macOS via the darwin.linux-builder
# VM (a single `nix build` that offloads *-linux derivations to a local NixOS
# guest, with the jappie cache feeding it).
# Chosen because it gives one self-contained `nix build` on the macOS runner
# and reuses the already-working Linux APK derivation verbatim.
# Alternatives considered:
#   - Native Darwin Android cross-compile: rejected; nixpkgs' androidndk
#     toolchain (autoPatchelfHook) and our lib.nix (hardcoded linux-x86_64 NDK
#     paths) assume a Linux host, so it needs deep nixpkgs+repo patching with
#     uncertain payoff (see docs/android-apk-on-macos.md, Q1).
#   - External Linux remote builder over SSH: reliable, but needs separate
#     persistent infrastructure and a secret; kept as the fallback if the VM
#     cannot boot on GitHub's macOS runners.
# Full analysis and sources: docs/android-apk-on-macos.md.
{ sources ? import ../npins }:
(import sources.nixpkgs-linux-builder { }).darwin.linux-builder
