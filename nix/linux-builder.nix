# pkgs.darwin.linux-builder: a small NixOS VM that runs on a macOS host and
# registers as a remote builder for *-linux derivations.  We use it to build
# the Android APK (a Linux-host cross-compile) from a macOS CI runner with a
# single `nix build`, since native Android cross-compilation does not work on
# a Darwin host (see docs/android-apk-on-macos.md).
#
# nixpkgs' default.nix picks the guest arch by mirroring the host
# (`nixpkgs.hostPlatform = toGuest stdenv.hostPlatform.system`, e.g.
# aarch64-darwin -> aarch64-linux).  We force x86_64-linux regardless of host
# arch (mirroring nixpkgs' own `darwin.linux-builder-x86_64`) because the
# Android NDK only ships linux-x86_64/darwin-x86_64 prebuilt toolchains --
# nixpkgs' androidndk-pkgs.nix throws "Android NDK doesn't support building on
# aarch64-unknown-linux-gnu" for an aarch64-linux build host (see
# nix/lib.nix's hardcoded ".../prebuilt/linux-x86_64/..." NDK paths).  On an
# aarch64-darwin host this means the VM runs under full TCG CPU emulation
# (aarch64 -> x86_64), which is slower to boot/build than a native-arch VM but
# still substitutes from cache.nixos.org since x86_64-linux is the most
# widely cached target.
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
# diskSize/memorySize are host-side qemu parameters (the guest root fs
# auto-resizes to fill the image), so overriding them only rebuilds the small
# Darwin run-script, not the cached x86_64-linux guest closure -- no bootstrap
# loop.  The default 20 GB disk is too small: streaming the cross-GHC + NDK
# closure onto it drops free space below the VM's 1 GB min-free threshold, so
# its garbage collector fires mid-build and deletes in-flight inputs
# ("some dependencies are missing").  Give it room.
(import sources.nixpkgs-linux-builder { }).darwin.linux-builder.override {
  modules = [
    {
      # Conservative, not tuned: 60 GB is comfortably above the ~15 GB APK
      # closure plus guest and slack (safe because the qcow2 is sparse, so it
      # only consumes what is written); 6 GB RAM is a modest bump from the 3 GB
      # default for GHC.  The APK build completes within these on macos-15-intel.
      virtualisation.darwin-builder.diskSize = 60 * 1024;  # MB
      virtualisation.darwin-builder.memorySize = 6 * 1024; # MB

      # See comment above: pin the guest to x86_64-linux (nixpkgs sets this
      # with mkDefault, so a plain assignment here wins) instead of letting it
      # mirror an aarch64-darwin host.
      nixpkgs.hostPlatform = "x86_64-linux";
    }
  ];
}
