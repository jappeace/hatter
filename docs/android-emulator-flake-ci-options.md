# Android Emulator Flakiness: Free-Tier CI Options

Issue: [#208](https://github.com/jappeace/hatter/issues/208)
Date: 2026-06-17

Investigation of how to make the android emulator CI job reliable on free
tiers, given that the app must keep shipping arm (arm64-v8a / armeabi-v7a)
native code.

## Problem

The android emulator job intermittently fails with `SIGSEGV`. The crash
backtrace shows the fault is not in hatter: all 101 crashes in one failing run
are inside `ndk_translation_HandleNoExec` (`libndk_translation.so`), with no
hatter frame.

```
#01 libndk_translation.so (ndk_translation_HandleNoExec+208)
#02 libndk_translation.so (ndk_translation::ExecuteGuest+224)
```

The CI emulator is **x86_64**, but the app ships **arm64-v8a / armeabi-v7a**
native code, so every native call runs under the emulator's ARM to x86 binary
translation layer. That layer intermittently faults (`SEGV_ACCERR`) managing
its JIT code cache. The identical APK passes on a re-run, so the crash is a
transient emulator flake, not a hatter bug.

The shipped mitigation (see `test/android/retryable-crash.sh`, wired into
`run_with_retry` in `nix/emulator-all.nix`) retries the transient crash instead
of failing the job on first hit. That makes CI resilient but does not remove the
crash. Removing it means executing arm code on an arm CPU (option 1) or on a
real device (option 2). hatter is a **public** repo, which is decisive for what
is free.

## Verdict at a glance

| Path | Free? | Eliminates flake? | Viable? |
|---|---|---|---|
| macOS arm64 runner (`macos-latest`, Apple Silicon) | Yes, free and unlimited on public repos | Yes, native arm via Hypervisor.Framework, no translation | Yes, best free option |
| Firebase Test Lab (Spark free tier) | Yes, 5 physical + 10 virtual runs/day | Yes, on physical (real arm) devices | Quota-limited, needs test restructuring |
| Linux arm64 runner (`ubuntu-24.04-arm`) | Yes, free | Yes, in principle | No: lacks KVM, so unaccelerated and too slow |
| AWS Device Farm | No: 1000 free *trial* minutes once, then paid | Yes, real devices | No sustainable free tier |

## Details

### 1. macOS arm64 runner: the strongest free option

`macos-latest` is Apple Silicon (arm64) and is free and unlimited on public
repositories. hatter already runs the iOS and watchOS jobs on `macos-latest`,
so the infrastructure and billing are proven for this repo. On Apple Silicon,
the android emulator runs an `arm64-v8a` system image natively via
Hypervisor.Framework, so `libndk_translation` is never in the path and the
`HandleNoExec` fault is structurally impossible. The `android-emulator-runner`
action supports macOS with Hypervisor.Framework, and `hannesa2/action-android-arm64`
exists specifically for Apple Silicon arm64 android.

Cost is engineering, not money. The android job is a bespoke nix harness
(`nix/emulator-all.nix`) tightly coupled to Linux. Two sub-paths:

- **(a) Faithful port:** run the android build and emulator under nix on
  `aarch64-darwin`. Keeps nix reproducibility, but is uncertain: nixpkgs'
  android emulator on Darwin is less travelled.
- **(b) Pragmatic swap:** for the android job only, drop the nix harness and use
  `reactivecircus/android-emulator-runner` on `macos-latest` with an
  `arm64-v8a` image. Well-trodden and fast to stand up, but loses nix
  reproducibility for that one job.

Caveat: `arm64-v8a` system images are limited to fewer API levels (around API
30 or 31).

### 2. Firebase Test Lab: free, real arm hardware, but quota-bound

The Spark (free) plan gives 5 physical-device plus 10 virtual-device test runs
per day. Physical devices are real arm hardware, so no translation and no flake.
No evidence was found of a blanket physical-device shutdown; individual models
age out of the catalog over time.

Cost is restructuring plus limits. The test would be converted to Firebase Test
Lab's instrumentation or Robo model (upload APK plus test, not the bespoke
logcat harness), accept the 5-per-day physical cap, and take on an external
dependency plus a service-account secret. Fine for an occasionally-pushed repo,
tight if CI runs often.

### 3. Linux arm64 free runners: no KVM (non-starter)

Free Linux arm64 runners (`ubuntu-22.04-arm`, `ubuntu-24.04-arm`) do not expose
`/dev/kvm`. GitHub staff, verbatim in community discussion #148648: "nested virt
is not supported for this sku" (Azure DPDSv6 series), and "as soon as azure
supports it, we can support it, but just blocked until then." Without KVM the
emulator runs in software (TCG), which is glacial and would likely re-create the
original 6h timeout. Dead end while acceleration is required.

### 4. AWS Device Farm: not a sustainable free tier

A one-time 1000-minute free trial, then $0.17 per device-minute. Not suitable
for recurring CI.

## Recommendation

Move the android emulator job to `macos-latest`. It is the only path that is
genuinely free for this repo (public, already in use), keeps arm64 as the tested
target, and eliminates the flake rather than retrying around it. Start with
sub-path (b) (the `reactivecircus` action on `macos-latest` with an `arm64-v8a`
image) to prove the flake disappears quickly; if it does, decide whether to
invest in the faithful nix-on-Darwin port. Keep the retry classifier as a cheap
safety net regardless.

If macOS runner contention or the `arm64-v8a` API-level limit becomes a problem,
Firebase Test Lab Spark is the fallback (real arm devices, 5 per day free).

## Sources

- [arm64 hosted runners GA for public repos (GitHub Changelog)](https://github.blog/changelog/2025-08-07-arm64-hosted-runners-for-public-repositories-are-now-generally-available/)
- [Linux arm64 runners lack nested virtualization (community discussion #148648)](https://github.com/orgs/community/discussions/148648)
- [GitHub-hosted runners reference: macOS standard runners free and unlimited on public repos; `macos-latest` is arm64](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [android-emulator-runner (macOS Hypervisor.Framework support)](https://github.com/ReactiveCircus/android-emulator-runner)
- [hannesa2/action-android-arm64 (Apple Silicon arm64 android)](https://github.com/hannesa2/action-android-arm64)
- [Firebase Test Lab usage, quotas and pricing (Spark: 5 physical, 10 virtual per day)](https://firebase.google.com/docs/test-lab/usage-quotas-pricing)
- [AWS Device Farm FAQs (1000 free trial minutes, then $0.17 per device-minute)](https://aws.amazon.com/device-farm/faqs/)
