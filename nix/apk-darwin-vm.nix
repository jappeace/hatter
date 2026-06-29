# Build the Android APK on a macOS (Darwin) host by spinning up a Linux VM
# inside the derivation and building there.  This is what makes
# `nix-build nix/apk.nix` work on a Mac with no remote-builder configuration:
# the cross-compile only works on a Linux build host (see
# docs/android-apk-on-macos.md), so we boot pkgs.darwin.linux-builder, copy the
# repo in, run `nix-build nix/apk.nix` inside (where the host is Linux, so it
# takes the native branch), and copy the resulting APK back out.
#
# Decision: build inside an in-derivation VM rather than via a configured nix
# remote builder.  Chosen so a plain `nix-build nix/apk.nix` is self-contained
# for local Mac users (no nix-darwin / nix.conf setup).  Trade-off: the build
# is impure (__noChroot: it runs qemu and needs the network), and slow under
# TCG software emulation.  Alternatives (remote builder declared in nix; native
# Darwin cross-compile) are discussed in docs/android-apk-on-macos.md.
{ sources ? import ../npins }:
let
  pkgs = import sources.nixpkgs { };
  lib = pkgs.lib;

  # The VM (a NixOS guest that runs on the Darwin host).  Its run-script is a
  # Darwin derivation; the x86_64-linux guest closure substitutes from cache.
  builder = import ./linux-builder.nix { inherit sources; };
  vmExe = lib.getExe builder.nixosConfig.system.build.vm;

  # The repo, copied into the VM and built there.  Exclude VCS noise and build
  # artifacts (including any qcow2 disk images this build itself produces).
  src = lib.cleanSourceWith {
    name = "hatter-src";
    src = ../.;
    filter =
      path: type:
      let
        base = baseNameOf path;
      in
      !(
        base == ".git"
        || base == "dist-newstyle"
        || base == "result"
        || lib.hasPrefix "result-" base
        || lib.hasSuffix ".qcow2" base
      );
  };

  # Substituter the in-VM build pulls the cross toolchain from (the VM only
  # knows cache.nixos.org by default).  builder is a trusted user in the VM,
  # so passing these via --option is honoured.
  jappieKey = "nix-cache.jappie.me:WjkKcvFtHih2i+n7bdsrJ3HuGboJiU2hA2CZbf9I9oc=";
in
pkgs.stdenv.mkDerivation {
  name = "hatter-apk";

  # Boots a qemu VM and drives a build inside it over SSH: needs the network
  # and cannot run in the nix sandbox.
  __noChroot = true;

  nativeBuildInputs = [
    pkgs.openssh
    pkgs.gnutar
    pkgs.coreutils
  ];

  buildCommand = ''
    export HOME="$PWD"
    keydir="$PWD/keys"
    mkdir -p "$keydir"
    ssh-keygen -q -t ed25519 -N "" -C builder@localhost -f "$keydir/builder_ed25519"

    echo "Booting the linux-builder VM (TCG software emulation, noapic)..."
    KEYS="$keydir" \
    QEMU_KERNEL_PARAMS="noapic" \
    NIX_DISK_IMAGE="$PWD/builder.qcow2" \
      ${vmExe} > "$PWD/vm.log" 2>&1 &
    vmpid=$!
    trap 'kill "$vmpid" 2>/dev/null || true' EXIT

    ssh_opts="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$PWD/known_hosts -o ConnectTimeout=5 -i $keydir/builder_ed25519 -p 31022"

    echo "Waiting for the VM to accept SSH..."
    up=
    for i in $(seq 1 240); do
      if ssh $ssh_opts builder@localhost true 2>/dev/null; then
        up=1; echo "VM reachable after ~$((i * 5))s"; break
      fi
      sleep 5
    done
    if [ -z "$up" ]; then
      echo "FATAL: the VM never accepted SSH"; tail -n 100 "$PWD/vm.log" || true; exit 1
    fi

    echo "Copying the source tree into the VM..."
    ssh $ssh_opts builder@localhost 'rm -rf /tmp/src && mkdir -p /tmp/src'
    tar -C ${src} -cf - . | ssh $ssh_opts builder@localhost 'tar -C /tmp/src -xf -'

    echo "Building the APK inside the VM (this is the real cross-compile)..."
    ssh $ssh_opts builder@localhost \
      "nix-build /tmp/src/nix/apk.nix --option extra-substituters https://nix-cache.jappie.me --option extra-trusted-public-keys '${jappieKey}' -o /tmp/apk-result"

    echo "Copying the APK out of the VM..."
    mkdir -p "$out"
    ssh $ssh_opts builder@localhost 'tar -C "$(readlink -f /tmp/apk-result)" -cf - .' \
      | tar --no-same-owner -C "$out" -xf -

    echo "APK built inside the VM and copied to $out"
  '';

  meta.platforms = lib.platforms.darwin;
}
