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

    # Issue #216: On Apple Silicon, clang targeting M1+ CPUs emits
    # ARMv8.4+ instructions (UDOT/SDOT) that crash on pre-A13 iOS
    # devices (A12/A12X).  This test proves the vulnerability exists
    # by compiling a canary with -mcpu=apple-m1 (what happens when
    # code targets Apple Silicon) and verifying UDOT appears in the
    # output.  It also verifies -mcpu=apple-a12 suppresses UDOT,
    # confirming that flag is the correct fix.
    #
    # The nix CC wrapper uses a generic aarch64 target, so we must
    # explicitly pass -mcpu to demonstrate the issue.
    ios-sigill-check = pkgs.runCommand "ios-sigill-check" {
      nativeBuildInputs = [ pkgs.stdenv.cc pkgs.cctools ];
    } (
      if isAppleSilicon then ''
        echo "=== Compile targeting Apple M1 (simulates host-CPU targeting) ==="
        cc -c -O2 -mcpu=apple-m1 -o canary_m1.o ${canary}
        otool -tv canary_m1.o > disasm_m1.txt
        cat disasm_m1.txt

        echo ""
        echo "=== Compile targeting Apple A12 (minimum for iOS 17+) ==="
        cc -c -O2 -mcpu=apple-a12 -o canary_a12.o ${canary}
        otool -tv canary_a12.o > disasm_a12.txt
        cat disasm_a12.txt

        echo ""
        echo "=== Results ==="

        # Detect UDOT/SDOT: either as a mnemonic or as a raw .long
        # encoding (otool prints .long when it doesn't know the opcode).
        # UDOT vector: 0x6E8x94xx, SDOT vector: 0x0E8x94xx
        has_dotprod() {
          grep -qi 'udot\|sdot' "$1" && return 0
          grep -qE '\.long\s+0x[06]e8[0-9a-f]94' "$1" && return 0
          return 1
        }

        M1_HAS_UDOT=false
        A12_HAS_UDOT=false
        if has_dotprod disasm_m1.txt; then M1_HAS_UDOT=true; fi
        if has_dotprod disasm_a12.txt; then A12_HAS_UDOT=true; fi

        echo "M1 target produces UDOT/SDOT: $M1_HAS_UDOT"
        echo "A12 target produces UDOT/SDOT: $A12_HAS_UDOT"

        if [ "$M1_HAS_UDOT" = "true" ] && [ "$A12_HAS_UDOT" = "false" ]; then
          echo ""
          echo "REPRODUCED: -mcpu=apple-m1 emits UDOT (crashes on A12),"
          echo "            -mcpu=apple-a12 does not (safe for A12)."
          echo "Any C code compiled targeting Apple Silicon without -mcpu"
          echo "constraint will SIGILL on pre-A13 iOS devices."
          echo "See https://github.com/jappeace/hatter/issues/216"
          exit 1
        elif [ "$M1_HAS_UDOT" = "false" ]; then
          echo ""
          echo "INCONCLUSIVE: M1 target did not produce UDOT."
          echo "Canary may need updating for this clang version."
          touch $out
        else
          echo ""
          echo "UNEXPECTED: A12 target also produces UDOT — bug in test or clang."
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
