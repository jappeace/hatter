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
    canary = ../test/ios/sigill_canary.c;
  in {
    ios-lib = iosLib;
    watchos-lib = watchosLib;

    # Issue #216: On Apple Silicon, GHC invokes clang without -mcpu,
    # so clang targets the host CPU (M1/M2/M3) and emits ARMv8.4+
    # instructions like UDOT that crash on pre-A13 iOS devices.
    #
    # This test compiles a canary C function (uint8 dot-product that
    # auto-vectorizes into UDOT at -O2) using the same toolchain as
    # the iOS build, then checks the disassembly for UDOT/SDOT.
    #
    # Expected: FAILS on Apple Silicon (proving the vulnerability),
    # SKIPS on Intel Macs (x86_64 doesn't emit ARM instructions).
    ios-sigill-check = pkgs.runCommand "ios-sigill-check" {} (
      if isAppleSilicon then ''
        # Compile canary with default -O2 (no -mcpu), same as GHC does.
        cc -c -O2 -o canary.o ${canary}
        otool -tv canary.o > disasm.txt

        echo "=== Disassembly ==="
        cat disasm.txt

        if grep -qi 'udot\|sdot' disasm.txt; then
          echo ""
          echo "REPRODUCED: clang emitted UDOT/SDOT (ARMv8.4+) without -mcpu."
          echo "These instructions cause SIGILL on pre-A13 iOS devices (A12/A12X)."
          echo "See https://github.com/jappeace/hatter/issues/216"
          exit 1
        else
          echo "No UDOT/SDOT found — host clang did not auto-vectorize the canary."
          echo "The canary may need updating, or the compiler version changed."
          touch $out
        fi
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

in
  buildTargets // testRunners // knownFailing // {
    # Meta-target: builds every compilation/link-test target.
    # Excludes emulator/simulator runners (they have dedicated CI jobs).
    # Adding a new attr to buildTargets automatically includes it here.
    all-builds = pkgs.runCommand "ci-all-builds" {} ''
      mkdir -p $out
      ${builtins.concatStringsSep "\n" (
        builtins.map (name: "ln -s ${buildTargets.${name}} $out/${name}")
          (builtins.attrNames buildTargets)
      )}
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
