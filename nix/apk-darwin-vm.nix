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
  # The Mac's side comes from the same stable nixpkgs as the VM: the
  # project's pin no longer supports Intel Macs. The APK inside the VM still
  # builds with the project's pin.
  pkgs = import sources.nixpkgs-linux-builder { };
  lib = pkgs.lib;

  # The VM (a NixOS guest that runs on the Darwin host).  Its run-script is a
  # Darwin derivation; the x86_64-linux guest closure substitutes from cache.
  builder = import ./linux-builder.nix { inherit sources; };
  runVm = lib.getExe builder.passthru.nixosConfig.system.build.vm;

  # The VM's SSH key, shared into it as /var/keys.  A store path, so it has
  # the ownership sshd's StrictModes wants.  Made as a derivation, not by
  # upstream's run-builder, which adds it to the store from inside this build:
  # the host's Nix daemon dropped that connection on CI (Nix 2.35.5), and the
  # VM then booted with no keys.
  keys = pkgs.runCommand "builder-keys" { nativeBuildInputs = [ pkgs.openssh ]; } ''
    mkdir $out
    ssh-keygen -q -t ed25519 -N "" -C builder@localhost -f $out/builder_ed25519
  '';

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
  toktokKey = "toktok.cachix.org-1:ZijcpD+vG99+1uX65TlXaROvLqP//CGCiFlB5OrIGXY=";

  # The minimal builder VM has no CA bundle, so the in-VM nix-build cannot
  # fetch the nixpkgs tarball or NARs over HTTPS.  Ship one in and point both
  # the evaluator (NIX_SSL_CERT_FILE) and the daemon (--option ssl-cert-file)
  # at it.  PEM certs are platform-independent, so the Darwin cacert is fine.
  caBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
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
    # ssh refuses a private key that others can read, as the store's copy is.
    install -m 600 ${keys}/builder_ed25519 "$PWD/builder_ed25519"

    echo "Booting the linux-builder VM (TCG software emulation, noapic)..."
    KEYS=${keys} \
    QEMU_KERNEL_PARAMS="noapic" \
    NIX_DISK_IMAGE="$PWD/builder.qcow2" \
      ${runVm} > "$PWD/vm.log" 2>&1 &
    vmpid=$!
    trap 'kill "$vmpid" 2>/dev/null || true' EXIT

    # accept-new + a throwaway known_hosts: the VM's host key is fixed and the
    # keydir is per-build, so there is nothing to pre-seed.  127.0.0.1 (not
    # "localhost") avoids ssh trying ::1 first against an IPv4-only forward.
    ssh_opts="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$PWD/known_hosts -o ConnectTimeout=5 -i $PWD/builder_ed25519 -p 31022"
    host="builder@127.0.0.1"

    echo "Waiting for the VM to accept SSH..."
    up=
    for i in $(seq 1 180); do
      if ! kill -0 "$vmpid" 2>/dev/null; then
        echo "FATAL: the qemu process exited before SSH came up"; echo "=== vm.log ==="; cat "$PWD/vm.log" || true; exit 1
      fi
      if ssh $ssh_opts $host true 2>/dev/null; then
        up=1; echo "VM reachable after ~$((i * 5))s"; break
      fi
      if [ $((i % 12)) -eq 0 ]; then
        echo "  ...still waiting ($((i * 5))s); is port 31022 open?"
        (exec 3<>/dev/tcp/127.0.0.1/31022 && echo "  port 31022 OPEN" && exec 3>&- ) 2>/dev/null || echo "  port 31022 not open yet"
        tail -n 5 "$PWD/vm.log" 2>/dev/null || true
      fi
      sleep 5
    done
    if [ -z "$up" ]; then
      echo "FATAL: the VM never accepted SSH"
      echo "=== verbose ssh attempt ==="
      ssh -v $ssh_opts $host true 2>&1 | tail -n 30 || true
      echo "=== full vm.log ==="
      cat "$PWD/vm.log" || true
      exit 1
    fi

    echo "Copying the source tree and CA bundle into the VM..."
    ssh $ssh_opts $host 'rm -rf /tmp/src && mkdir -p /tmp/src'
    tar -C ${src} -cf - . | ssh $ssh_opts $host 'tar -C /tmp/src -xf -'
    ssh $ssh_opts $host 'cat > /tmp/ca.pem' < ${caBundle}

    echo "Building the APK inside the VM (this is the real cross-compile)..."
    ssh $ssh_opts $host \
      "NIX_SSL_CERT_FILE=/tmp/ca.pem nix-build /tmp/src/nix/apk.nix --option ssl-cert-file /tmp/ca.pem --option extra-substituters 'https://nix-cache.jappie.me https://toktok.cachix.org' --option extra-trusted-public-keys '${jappieKey} ${toktokKey}' -o /tmp/apk-result"

    echo "Copying the APK out of the VM..."
    mkdir -p "$out"
    ssh $ssh_opts $host 'tar -C "$(readlink -f /tmp/apk-result)" -cf - .' \
      | tar --no-same-owner -C "$out" -xf -

    echo "APK built inside the VM and copied to $out"
  '';

  meta.platforms = lib.platforms.darwin;
}
