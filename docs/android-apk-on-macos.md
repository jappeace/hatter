# Building the Android APK on macOS

Status: implemented (2026-06-29). Tracks issue #228 ("Build android on
macOS"). The Linux CI already builds the APK; this document is about making
the same APK reachable from a macOS host.

## TL;DR

Native Android cross-compilation on a Darwin *build host* is not supported by
our nixpkgs pin without patching nixpkgs internals (and this repo). Instead
`nix-build nix/apk.nix` is self-contained: on Linux it builds natively, and on
macOS the derivation **boots a Linux VM (`pkgs.darwin.linux-builder`), builds
the APK inside it, and copies it out** -- no remote-builder or nix-darwin setup
required.  A local Mac user and CI run the exact same command.

## Outcome (implemented)

`nix/apk.nix` dispatches on the build host:

- **Linux** -> `nix/apk-linux.nix`, the real cross-compile.
- **macOS** -> `nix/apk-darwin-vm.nix`, a `__noChroot` derivation that boots
  the VM, copies the repo in, runs `nix-build nix/apk.nix` inside (where the
  host is Linux, so it takes the native branch -- no recursion), and copies the
  resulting `hatter.apk` back to `$out`.  The in-VM build pulls the cross
  toolchain from `nix-cache.jappie.me`.

The CI `macos-apk` job is therefore just `nix-build nix/apk.nix` on a
`macos-15-intel` runner -- all the VM logic is in nix, not CI steps.

Getting the VM to work on a GitHub-hosted runner needed four fixes, each peeled
off by a failing CI run:

1. **Pin the VM to stable nixpkgs** (`nixpkgs-linux-builder`, nixos-25.05).
   For the project's unstable pin the VM's guest closure is not on
   cache.nixos.org, so realizing it on the Mac would need the very Linux
   builder we are creating (bootstrap loop).  A stable release is cached.
2. **Reload the nix daemon before launching the VM**, not after.  Restarting
   it afterwards races `create-builder`'s `nix-store --add` (which shares the
   SSH key dir into the store) and leaves the VM key share empty, so the VM
   never boots.
3. **`QEMU_KERNEL_PARAMS=noapic`.**  GitHub runners have no nested virt, so
   QEMU falls back to TCG software emulation, under which the guest kernel
   panics at boot with "IO-APIC + timer doesn't work!".  noapic (the kernel's
   own suggested workaround) is appended to the guest cmdline at runtime, so
   no VM rebuild is needed.
4. **Enlarge the VM disk** (`diskSize = 60 GB`).  The default 20 GB fills as
   the cross-GHC + NDK closure streams in, dropping below the VM's 1 GB
   min-free threshold; its garbage collector then runs mid-build and deletes
   in-flight inputs ("some dependencies are missing").  diskSize/memorySize
   are host-side qemu params, so overriding them only rebuilds the small
   Darwin run-script, not the cached guest closure.

Caveat: the build runs under TCG software emulation, so it is slow (~1.5 h)
and the job timeout is 120 min.  It is substitution-heavy (cached deps come
from the jappie cache via the client); only hatter, hatter-android and the
APK assembly actually compile on the VM.

## What works today, and the runner constraint

- The APK builds fine on Linux (the `android` / `nix-build` CI jobs).
- `macos-latest` / `macos-14` are Apple Silicon (`aarch64-darwin`). The Android
  NDK refuses to evaluate there:
  `Android NDK doesn't support building on arm64-apple-darwin`. nixpkgs'
  `androidndk-pkgs.nix` only maps `x86_64-apple-darwin` and
  `x86_64-unknown-linux-gnu` as NDK build hosts. So any macOS APK attempt must
  use an **Intel** runner (`macos-15-intel`; `macos-13` was retired
  2025-12-04 and its jobs queue forever instead of failing).

## Q1 - Does nixpkgs support native Android cross-compilation on Darwin?

In practice, no. Multiple Linux-host assumptions block it, two of them inside
nixpkgs itself. Each was hit in order on a real `x86_64-darwin` CI run:

1. **`qemu-user` for Template Haskell (Linux-only).** The cross build runs the
   target `iserv-proxy-interpreter` under `qemu-user` so GHC can evaluate TH.
   `qemu-user` is Linux-only and nixpkgs refuses to evaluate it on Darwin.
   Worked around in `nix/cross-deps.nix` + `nix/lib.nix` by gating the qemu /
   `-fexternal-interpreter` machinery on a Linux build host. This is safe only
   because hatter's APK closure contains no real TH splices (the lone
   interpreter start in the Linux build comes from the unconditional flag, not
   a splice). A consumer that genuinely uses TH while cross-compiling on macOS
   would hit the loud-failing stub.

2. **NDK toolchain derivation fails on Darwin (nixpkgs).** With qemu gated off,
   the build reaches `aarch64-unknown-linux-android-ndk-toolchain`, which fails
   with `builder failed with exit code 1`. The derivation's own fixup runs
   `autoPatchelfHook`; on the Darwin runner that produced 26x
   `patchelf: command not found` and then an uncaught Python traceback from
   `auto-patchelf` opening the stdenv dynamic linker as the `--interpreter`
   (`elf_assert(magic == b'\x7fELF', 'Magic number does not match')`).
   Note: scanning the Mach-O *output* files is itself a no-op (they raise
   `ELFError` and are skipped); the failure is `patchelf` being absent on the
   builder plus the unguarded `open_elf(interpreter_path)` crash. Either way
   the derivation does not build on a Darwin host.

3. **Hardcoded NDK host dir (this repo).** `nix/lib.nix` hardcodes
   `${ndk}/toolchains/llvm/prebuilt/linux-x86_64/...` (and `llvm-strip`). A
   Darwin NDK uses `darwin-x86_64`; every such path would need to be
   host-conditional.

A "pure native" Darwin port therefore means patching nixpkgs (gate
`autoPatchelfHook`, wire up the `darwin-x86_64` NDK) plus this repo, across
several layers with no upstream support behind it. High effort, uncertain it
terminates, and untestable without a Mac.

## Q2 - Can a Linux VM build it "Linux style" on Darwin, as one `nix build`?

Yes. nixpkgs ships `pkgs.darwin.linux-builder` (the
`nixos/modules/profiles/macos-builder.nix` profile, present in our pin - no
pin bump needed). It boots a small NixOS VM that registers as a **remote
builder** for `*-linux`. With it configured
(`builders = ssh-ng://builder@linux-builder x86_64-linux ...`,
`builders-use-substitutes = true`), a single `nix build nix/ci.nix -A apk` on
the Mac transparently offloads the Linux-host APK derivation to the VM.

Why this is cheap: with `builders-use-substitutes = true`, the VM pulls the
whole APK closure straight from `nix-cache.jappie.me` (which already holds the
`x86_64-linux` paths the Linux CI built), so it mostly *downloads* rather than
recompiling. The heavy cross-GHC / NDK work never reruns. It reuses the
existing, working Linux derivation verbatim.

## Q3 - The catch: running the VM on a GitHub-hosted macOS runner

This is the one real unknown - it is about virtualization availability:

- **Apple Silicon runners** (`macos-14/15`): nested virtualization has been
  disabled (Hypervisor.framework unavailable); Docker/colima fail with
  `HV_UNSUPPORTED`. No hardware acceleration there.
- **Intel runners** (`macos-15-intel`): QEMU runs in software (TCG). Slow to
  boot, but since the build is substitution-bound (cache-complete) rather than
  CPU-bound, a slow VM may still be acceptable.
- **Trend (2026):** macOS 15 added nested virtualization (EL2 /
  `hv_vm_config_set_el2_enabled`), and GitHub's runner-images project is
  moving toward enabling Hypervisor.framework. Improving, not guaranteed today.

## Options

| | Approach | Effort | Reliability | Single `nix build` on macOS |
|---|---|---|---|---|
| A | `darwin.linux-builder` VM in CI | low-medium | hinges on runner virtualization | yes |
| B | External Linux remote builder over SSH | low | high (no VM) | yes (offloaded) |
| C | Deep native Darwin port (patch nixpkgs + repo) | high | uncertain it terminates | yes (truly native) |

## Decision

Implemented **A** as the *self-contained* variant: the VM is spun up by the
derivation itself (`apk-darwin-vm.nix`), so `nix-build nix/apk.nix` works on a
Mac with zero configuration -- no nix-darwin module, no nix.conf remote-builder
entry. Chosen so the build is reproducible and identical for local users and
CI, rather than living in GitHub Actions steps. Trade-off: the APK build is
impure (`__noChroot`, runs qemu, needs the network).

If this ever regresses (e.g. a runner image drops software virtualisation),
the fallbacks remain: a Linux builder declared via nix-darwin / `nix.conf`
(still a single `nix-build`), or a native Darwin port (most work, last resort).

## Sources

- nixpkgs androidndk-pkgs.nix: <https://github.com/NixOS/nixpkgs/blob/master/pkgs/development/androidndk-pkgs/androidndk-pkgs.nix>
- "treewide: autoPatchelfHook only on Linux": <https://git.sr.ht/~andir/nixpkgs/commit/d2f268745a44dfd0ff23b5a00a75c1e13279bc3d>
- nixpkgs darwin-builder.section.md: <https://github.com/NixOS/nixpkgs/blob/master/doc/packages/darwin-builder.section.md>
- NixOS Wiki - NixOS VMs on macOS: <https://wiki.nixos.org/wiki/NixOS_virtual_machines_on_macOS>
- Nixcademy - Build & deploy Linux from macOS: <https://nixcademy.com/posts/macos-linux-builder/>
- GitHub runner-images - nested virtualization discussion: <https://github.com/actions/runner-images/discussions/7191>
- colima HV_UNSUPPORTED on macos-14: <https://github.com/abiosoft/colima/issues/970>
- runner-images #13505 - support Hypervisor.framework on Apple silicon: <https://github.com/actions/runner-images/issues/13505>
