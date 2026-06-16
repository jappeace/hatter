{ sources ? import ../npins }:
let
  isDarwin = builtins.currentSystem == "aarch64-darwin"
          || builtins.currentSystem == "x86_64-darwin";
  pkgs = import sources.nixpkgs {};

  # Compilation and link-test targets.
  # New targets added here are automatically picked up by `all-builds`.
  buildTargets = {
    native = import ../default.nix {};
    android-aarch64 = import ./android.nix { inherit sources; };
    android-armv7a = import ./android.nix { inherit sources; androidArch = "armv7a"; };
    apk = import ./apk.nix { inherit sources; };
    consumer-link-test = import ./test-link-consumer.nix { inherit sources; };
    consumer-deps-test = import ./test-consumer-deps.nix { inherit sources; };
    th-test = import ./test-th.nix { inherit sources; };
    readme-example = import ./test-readme-example.nix { inherit sources; };
    th-direct-test = import ./test-th-direct.nix { inherit sources; };
    # async package cross-compilation regression test (issue #163).
    # Without --wrap=registerForeignExports dedup, a duplicate .init_array
    # entry causes infinite getStablePtr loop → OOM during hs_init.
    async-oom-test = import ./android.nix {
      inherit sources;
      mainModule = ../test/AsyncOomDemoMain.hs;
      consumerCabal2Nix =
        { mkDerivation, base, lib, async, text }:
        mkDerivation {
          pname = "async-oom-test";
          version = "0.1.0.0";
          libraryHaskellDepends = [ base async text ];
          license = lib.licenses.mit;
        };
    };
  } // (if isDarwin then let
    isAppleSilicon = builtins.currentSystem == "aarch64-darwin";
    iosLib = import ./ios.nix { inherit sources; };
    watchosLib = import ./watchos.nix { inherit sources; };
    lib = import ./lib.nix { inherit sources; };
    # lib with deviceCpu set — only used by ios-sigill-check to prove the fix works
    libWithCpuFlag = import ./lib.nix { inherit sources; deviceCpu = "apple-a12"; };
    canary = ../test/ios/sigill_canary.c;
  in {
    ios-lib = iosLib;
    watchos-lib = watchosLib;

    # Issue #216: Verify iOS device C compilation doesn't emit ARMv8.4+
    # instructions (UDOT/SDOT) that crash on pre-A13 devices (A12/A12X).
    # Compiles a canary through the same GHC + flags as mkAppleStaticLib.
    ios-sigill-check = pkgs.runCommand "ios-sigill-check" {} (
      if isAppleSilicon then ''
        echo "=== Disassembly of canary compiled for iOS device (with deviceCpu=apple-a12) ==="
        cat ${libWithCpuFlag.compileIOSDeviceC canary}

        # Detect UDOT/SDOT: either as a mnemonic or as a raw .long
        # encoding (otool prints .long when it doesn't know the opcode).
        # UDOT vector: 0x6E8x94xx, SDOT vector: 0x0E8x94xx
        has_dotprod() {
          grep -qi 'udot\|sdot' "$1" && return 0
          grep -qE '\.long\s+0x[06]e8[0-9a-f]94' "$1" && return 0
          return 1
        }

        if has_dotprod ${libWithCpuFlag.compileIOSDeviceC canary}; then
          echo ""
          echo "FAIL: iOS device C compilation emits UDOT/SDOT even with deviceCpu=apple-a12."
          echo "These crash on pre-A13 devices (A12/A12X)."
          echo "See https://github.com/jappeace/hatter/issues/216"
          exit 1
        fi

        echo ""
        echo "OK: No UDOT/SDOT detected when deviceCpu=apple-a12 is set."
        touch $out
      '' else ''
        echo "SKIP: not Apple Silicon (${builtins.currentSystem}), UDOT not relevant."
        touch $out
      ''
    );
  } else {});

  # Emulator/simulator test runners — heavy (include system images),
  # need dedicated CI jobs with enough disk space.
  testRunners = {
    emulator-all = import ./emulator-all.nix { inherit sources; };
    emulator-armv7a = import ./emulator-all.nix {
      inherit sources; androidArch = "armv7a";
    };
  } // (if isDarwin then {
    simulator-all = import ./simulator-all.nix { inherit sources; };
    watchos-simulator-all = import ./watchos-simulator-all.nix {
      inherit sources;
    };
  } else {});

  # Known-failing targets: documented upstream issues, not included in
  # all-builds but available for manual testing.
  #
  # th-direct-test-armv7a: Template Haskell on armv7a crashes with SIGSEGV
  # in GHC's RTS linker during GC (heap closure has invalid info pointer).
  # Root cause: GHC's ARM32 RTS linker is broken with per-function ELF
  # sections (LLVM -ffunction-sections) in statically-linked iserv
  # (GHC #14291, haskell.nix #1544).  ARM32 support is effectively
  # abandoned in GHC — GHCup dropped it, haskell.nix closed as wontfix.
  # Regular armv7a cross-compilation (without TH) works fine.
  knownFailing = {
    th-direct-test-armv7a = import ./test-th-direct.nix { inherit sources; androidArch = "armv7a"; };
  };

  testScripts = builtins.path { path = ../test; name = "test-scripts"; };

  # Pure-bash check (no emulator) for the crash retry classifier that decides
  # whether an emulator crash is the transient ndk_translation flake (issue
  # #208, retry) or a deterministic native failure (give up).
  retryClassificationTest = pkgs.runCommand "retry-classification-test" {} ''
    bash ${testScripts}/android/retryable-crash-test.sh
    touch $out
  '';

in
  buildTargets // testRunners // knownFailing // {
    inherit retryClassificationTest;

    # Meta-target: builds every compilation/link-test target.
    # Excludes emulator/simulator runners (they have dedicated CI jobs).
    # Adding a new attr to buildTargets automatically includes it here.
    all-builds = pkgs.runCommand "ci-all-builds" {} ''
      mkdir -p $out
      ${builtins.concatStringsSep "\n" (
        builtins.map (name: "ln -s ${buildTargets.${name}} $out/${name}")
          (builtins.attrNames buildTargets)
      )}
      ln -s ${retryClassificationTest} $out/retry-classification-test
    '';

    # Lint all test shell scripts with shellcheck.
    shellcheck = pkgs.runCommand "ci-shellcheck" {
      nativeBuildInputs = [ pkgs.shellcheck ];
    } ''
      shellcheck -x \
        --source-path=${testScripts}/android \
        ${testScripts}/android/*.sh
      shellcheck -x \
        --source-path=${testScripts}/ios \
        ${testScripts}/ios/*.sh
      shellcheck -x \
        --source-path=${testScripts}/watchos \
        ${testScripts}/watchos/*.sh
      echo "All shell scripts passed shellcheck."
      touch $out
    '';
  }
