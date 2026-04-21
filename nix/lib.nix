# Reusable builder functions for hatter based projects.
#
# Returns an attrset of 6 builder functions:
#   mkAndroidLib       — cross-compile Haskell to .so for Android (aarch64 or armv7a)
#   mkApk              — package .so + Java + resources into signed APK
#   mkIOSLib           — compile Haskell to .a for iOS (device or simulator)
#   mkSimulatorApp     — stage iOS sources + pre-built library for xcodebuild
#   mkWatchOSLib       — compile Haskell to .a for watchOS (device or simulator)
#   mkWatchOSSimulatorApp — stage watchOS sources + pre-built library for xcodebuild
#
# Usage:
#   let lib = import ./lib.nix { sources = import ../npins; };
#   in lib.mkAndroidLib { hatterSrc = ../.; mainModule = ../test/ScrollDemoMain.hs; }
{ sources, androidArch ? "aarch64" }:
let
  archConfig = {
    aarch64 = {
      crossAttr = "aarch64-android-prebuilt";
      ndkTarget = "aarch64-linux-android26";
      ghcPkgArch = "aarch64-linux";
      abiDir = "arm64-v8a";
    };
    armv7a = {
      crossAttr = "armv7a-android-prebuilt";
      ndkTarget = "armv7a-linux-androideabi26";
      ghcPkgArch = "armv7-linux";
      abiDir = "armeabi-v7a";
    };
  }.${androidArch};

  # armv7a: compiler-rt's cmake doesn't include "armv7a" in its ARM32 arch
  # list, so builtin targets are empty and the build produces no output.
  # We patch the nixpkgs source to fix this (see patch-compiler-rt.py).
  nixpkgsSrc = import ./patched-nixpkgs.nix {
    nixpkgsSrc = sources.nixpkgs;
    inherit androidArch;
  };

  pkgs = import nixpkgsSrc {
    config.allowUnfree = true;
    config.android_sdk.accept_license = true;
  };

  # --- Android cross-compilation infrastructure ---
  androidPkgs = pkgs.pkgsCross.${archConfig.crossAttr};
  # armv7a uses the LLVM backend (no NCG for 32-bit ARM).  Building profiled
  # libraries with the LLVM ARM backend triggers an llc crash in
  # ARMAsmPrinter::emitXXStructor (LLVM bug).  Disable profiling for armv7a.
  ghc = if androidArch == "armv7a"
    then androidPkgs.haskellPackages.ghc.override { enableProfiledLibs = false; }
    else androidPkgs.haskellPackages.ghc;
  ghcCmd = "${ghc}/bin/${ghc.targetPrefix}ghc";
  ghcPkgDir = "${ghc}/lib/${ghc.targetPrefix}ghc-${ghc.version}/lib/${archConfig.ghcPkgArch}-ghc-${ghc.version}";

  androidComposition = pkgs.androidenv.composeAndroidPackages {
    includeNDK = true;
  };
  ndk = "${androidComposition.ndk-bundle}/libexec/android-sdk/ndk/${androidComposition.ndk-bundle.version}";
  ndkCc = "${ndk}/toolchains/llvm/prebuilt/linux-x86_64/bin/${archConfig.ndkTarget}-clang";
  sysroot = "${ndk}/toolchains/llvm/prebuilt/linux-x86_64/sysroot";

  # --- APK toolchain ---
  apkComposition = pkgs.androidenv.composeAndroidPackages {
    buildToolsVersions = [ "34.0.0" ];
    platformVersions = [ "34" ];
    includeNDK = false;
  };
  androidSdk = apkComposition.androidsdk;
  buildTools = "${androidSdk}/libexec/android-sdk/build-tools/34.0.0";
  platform = "${androidSdk}/libexec/android-sdk/platforms/android-34";

  # --- Apple (iOS/watchOS) shared infrastructure ---
  applePkgs = import sources.nixpkgs {};
  appleGhc = applePkgs.haskellPackages.ghc;
  gmpStatic = applePkgs.gmp.overrideAttrs (old: {
    dontDisableStatic = true;
  });
  # Apple's libffi (v40) only ships .dylib — no static archive.
  # Build GNU libffi from source with --enable-static for bundling
  # into the iOS fat archive (mac2ios patches the platform tag).
  libffiStatic = applePkgs.stdenv.mkDerivation {
    pname = "libffi-static";
    version = "3.5.2";
    src = applePkgs.fetchurl {
      url = "https://github.com/libffi/libffi/releases/download/v3.5.2/libffi-3.5.2.tar.gz";
      hash = "sha256-86MIKiOzfCk6T80QUxR7Nx8v+R+n6hsqUuM1Z2usgtw=";
    };
    configureFlags = [ "--enable-static" "--disable-shared" ];
  };

  # -------------------------------------------------------------------------
  # Shared data lists — single source of truth for modules, sources, headers
  # -------------------------------------------------------------------------

  # Haskell source modules copied for Apple static builds
  hatterModules = [
    "Types" "Lifecycle" "Widget" "UIBridge" "Render" "Locale" "I18n"
    "Permission" "SecureStorage" "Ble" "Dialog" "Location" "AuthSession"
    "PlatformSignIn" "Camera" "BottomSheet" "Http" "NetworkStatus"
    "AppContext" "Animation" "FilesDir" "DeviceInfo"
  ];

  # C source files for Apple static builds
  appleCbitsSources = [
    "platform_log" "ui_bridge" "run_main" "locale"
    "permission_bridge" "secure_storage_bridge" "ble_bridge"
    "dialog_bridge" "location_bridge" "auth_session_bridge"
    "platform_sign_in_bridge" "camera_bridge" "bottom_sheet_bridge"
    "http_bridge" "network_status_bridge" "animation_bridge"
    "redraw_bridge" "files_dir" "device_info"
  ];

  # Bridge headers shipped in output include/
  bridgeHeaders = [
    "Hatter.h" "UIBridge.h" "PermissionBridge.h" "SecureStorageBridge.h"
    "BleBridge.h" "DialogBridge.h" "LocationBridge.h" "AuthSessionBridge.h"
    "PlatformSignInBridge.h" "CameraBridge.h" "BottomSheetBridge.h"
    "HttpBridge.h" "NetworkStatusBridge.h" "AnimationBridge.h" "RedrawBridge.h"
  ];

  # Android C files with identical NDK compile pattern (JNI_PACKAGE=me_jappie_hatter)
  androidJniBridgeFiles = [
    "jni_bridge" "permission_bridge_android" "secure_storage_android"
    "ble_bridge_android" "dialog_bridge_android" "location_bridge_android"
    "auth_session_android" "platform_sign_in_android" "camera_bridge_android"
    "bottom_sheet_android" "http_bridge_android" "network_status_android"
    "animation_bridge_android" "redraw_bridge_android"
  ];

  # Haskell symbols kept alive via -u linker flags.
  # Android uses bare names; Apple prefixes with _.
  commonExportedSymbols = [
    "haskellRunMain" "haskellOnLifecycle" "haskellRenderUI" "haskellOnUIEvent"
    "haskellOnPermissionResult" "haskellOnSecureStorageResult"
    "haskellOnBleScanResult" "haskellOnDialogResult" "haskellOnLocationUpdate"
    "haskellOnAuthSessionResult" "haskellOnPlatformSignInResult"
    "haskellOnCameraResult" "haskellOnVideoFrame" "haskellOnAudioChunk"
    "haskellOnBottomSheetResult" "haskellOnHttpResult"
    "haskellOnNetworkStatusChange" "haskellLogLocale"
  ];
  androidOnlySymbols = [ "haskellOnUITextChange" ];
  appleOnlySymbols = [ "haskellLogDeviceInfo" ];

  # -------------------------------------------------------------------------
  # Helper functions — generate repetitive shell/nix fragments
  # -------------------------------------------------------------------------

  # NDK compile one C file with JNI_PACKAGE and standard includes
  ndkCompileJni = hatterSrc: cName:
    ''
      ${ndkCc} -c -fPIC \
        -DJNI_PACKAGE=me_jappie_hatter \
        -I${sysroot}/usr/include \
        -I$RTS_INCLUDE \
        -I${hatterSrc}/include \
        -o ${cName}.o \
        ${hatterSrc}/cbits/${cName}.c
    '';

  # Generate -optl-Wl,-u,<prefix><sym> flags
  undefinedSymbolFlags = prefix: symbols:
    builtins.concatStringsSep " \\\n          "
      (map (s: "-optl-Wl,-u,${prefix}${s}") symbols);

  # Generate header copy commands: cp <src>/<h> <dst>/<h>
  copyBridgeHeaders = src: dst:
    builtins.concatStringsSep "\n"
      (map (h: "cp ${src}/${h} ${dst}/${h}") bridgeHeaders);

  # Copy Hatter/*.hs modules from source tree
  copyHatterModules = hatterSrc:
    builtins.concatStringsSep "\n"
      (map (m: "cp ${hatterSrc}/src/Hatter/${m}.hs Hatter/") hatterModules);

  # Copy C source files to writable build dir
  copyCbitsSources = hatterSrc:
    builtins.concatStringsSep "\n"
      (map (f: "cp ${hatterSrc}/cbits/${f}.c cbits/") appleCbitsSources);

  # Generate cbits/*.c arguments for ghc -staticlib
  cbitsSourceArgs =
    builtins.concatStringsSep " \\\n          "
      (map (f: "cbits/${f}.c") appleCbitsSources);

  # -------------------------------------------------------------------------
  # Internal: mkAppleStaticLib — shared implementation for iOS and watchOS
  # -------------------------------------------------------------------------
  mkAppleStaticLib =
    { hatterSrc
    , mainModule
    , platform      # "ios" or "watchos"
    , simulator ? false
    , pname ? "hatter-${platform}"
    , extraModuleCopy ? ""
    , crossDeps ? null          # output of ios-deps.nix (lib/, pkgdb/)
    }:
    let
      mac2tool = import (hatterSrc + "/nix/mac2${platform}.nix") {
        inherit sources; pkgs = applePkgs;
      };
      toolBin = "mac2${platform}";
    in
    applePkgs.stdenv.mkDerivation {
      inherit pname;
      version = "0.1.0.0";

      src = hatterSrc + "/src";

      nativeBuildInputs = [ appleGhc applePkgs.cctools ];
      buildInputs = [ libffiStatic gmpStatic ];

      buildPhase = ''
        ${if crossDeps != null then ''
        # Hatter is pre-built in crossDeps — only compile per-app files.
        cp ${mainModule} Main.hs

        # run_main.c is not in cabal c-sources (references per-app ZCMain_main_closure)
        mkdir -p cbits
        cp ${hatterSrc}/cbits/run_main.c cbits/

        # Extra module copies (consumer overrides)
        ${extraModuleCopy}

        ghc -staticlib \
          -O2 \
          -o libHatter.a \
          -I${hatterSrc}/include \
          -package-db ${crossDeps}/pkgdb \
          -optl-lffi \
          ${undefinedSymbolFlags "_" (commonExportedSymbols ++ appleOnlySymbols)} \
          cbits/run_main.c \
          Main.hs
        '' else ''
        # Standalone build — compile hatter from source.
        mkdir -p Hatter
        ${copyHatterModules hatterSrc}
        cp ${hatterSrc}/src/Hatter.hs .

        # Extra module copies
        ${extraModuleCopy}

        cp ${mainModule} Main.hs

        # Copy C sources into writable build dir (GHC writes .o next to them)
        mkdir -p cbits
        ${copyCbitsSources hatterSrc}

        ghc -staticlib \
          -O2 \
          -o libHatter.a \
          -I${hatterSrc}/include \
          -optl-lffi \
          ${undefinedSymbolFlags "_" (commonExportedSymbols ++ appleOnlySymbols)} \
          ${cbitsSourceArgs} \
          Main.hs \
          Hatter.hs
        ''}
      '';

      installPhase = ''
        mkdir -p $out/lib $out/include

        echo "Merging static archives into libHatter.a"
        libtool -static -o libCombined.a libHatter.a \
          ${gmpStatic}/lib/libgmp.a \
          ${libffiStatic}/lib/libffi.a \
          ${if crossDeps != null then "${crossDeps}/lib/*.a" else ""}
        mv libCombined.a libHatter.a

        ${mac2tool}/bin/${toolBin} ${if simulator then "-s" else ""} libHatter.a
        cp libHatter.a $out/lib/
        ${copyBridgeHeaders "${hatterSrc}/include" "$out/include"}
      '';
    };

  # -------------------------------------------------------------------------
  # Internal: mkAppleSimulatorApp — shared implementation for simulator staging
  # -------------------------------------------------------------------------
  mkAppleSimulatorApp =
    { platformLib      # pre-built .a library derivation
    , platformSrc      # path to ios/ or watchos/ source directory
    , platformName     # "ios" or "watchos"
    , name
    , maxNodes ? 256
    , dynamicNodePool ? false
    }:
    let
      nodePoolCFlags =
        if dynamicNodePool then ["-DDYNAMIC_NODE_POOL"]
        else if maxNodes != 256 then ["-DMAX_NODES=${toString maxNodes}"]
        else [];
      # Inject OTHER_CFLAGS into project.yml when non-default pool settings used.
      # Uses single-quoted -c and argv to avoid shell quoting issues.
      flagYaml = ''[${builtins.concatStringsSep ", " (map (f: ''"${f}"'') nodePoolCFlags)}]'';
      patchProjectYml =
        if nodePoolCFlags == [] then ""
        else ''
          ${pkgs.python3}/bin/python3 -c '
import sys
yml = open(sys.argv[1]).read()
yml = yml.replace(
    "OTHER_LDFLAGS:",
    "OTHER_CFLAGS: " + sys.argv[2] + "\n        OTHER_LDFLAGS:"
)
open(sys.argv[1], "w").write(yml)
' "$out/share/${platformName}/project.yml" '${flagYaml}'
        '';
    in
    pkgs.stdenv.mkDerivation {
      inherit name;

      dontUnpack = true;

      buildPhase = ''
        mkdir -p $out/share/${platformName}/lib $out/share/${platformName}/include

        cp -r ${platformSrc}/Hatter $out/share/${platformName}/
        cp -r ${platformSrc}/HatterUITests $out/share/${platformName}/
        cp ${platformSrc}/project.yml $out/share/${platformName}/project.yml
        ${if nodePoolCFlags != [] then ''chmod u+w $out/share/${platformName}/project.yml'' else ""}

        cp ${platformLib}/lib/libHatter.a $out/share/${platformName}/lib/
        ${copyBridgeHeaders "${platformLib}/include" "$out/share/${platformName}/include"}
        ${patchProjectYml}
      '';

      installPhase = "true";
    };

in {

  # ---------------------------------------------------------------------------
  # mkAndroidLib: Cross-compile Haskell to shared .so for Android (aarch64/armv7a)
  # ---------------------------------------------------------------------------
  mkAndroidLib =
    { hatterSrc
    , mainModule
    , pname ? "hatter-android"
    , javaPackageName ? "me.jappie.hatter"
    , extraJniBridge ? []
    , extraNdkCompile ? (_: _: "")
    , extraModuleCopy ? ""
    , extraLinkObjects ? []
    , extraGhcIncludeDirs ? []
    , crossDeps ? null          # output of cross-deps.nix (lib/, lib-main/, pkgdb/)
    , extraGhcFlags ? []        # additional flags passed to cross-GHC
    , maxNodes ? 256            # static pool size (ignored when dynamicNodePool=true)
    , dynamicNodePool ? false   # use malloc/realloc instead of fixed array
    , soMaxSizeMB ? 200         # fail build if .so exceeds this (MB), catches whole-archive bloat
    }:
    let
      # Must match HatterActivity.java's System.loadLibrary("hatter").
      # Not configurable — any other name guarantees UnsatisfiedLinkError.
      soName = "libhatter.so";

      jniPackageMacro = builtins.replaceStrings ["."] ["_"] javaPackageName;

      # Template Haskell support for consumer code: when crossDeps includes
      # the iserv wrapper, add -fexternal-interpreter so GHC delegates TH
      # splices to the QEMU-emulated iserv-proxy-interpreter.
      thFlags = if crossDeps != null
        then "-fexternal-interpreter -pgmi ${crossDeps}/bin/iserv-proxy-wrapper"
        else "";
    in
    pkgs.stdenv.mkDerivation {
      inherit pname;
      version = "0.1.0.0";

      src = hatterSrc + "/src";

      nativeBuildInputs = [ ghc ];
      buildInputs = [ androidPkgs.libffi androidPkgs.gmp ];

      buildPhase = ''
        # Clean stale build artifacts from the source tree.
        # Local cabal builds may leave .hi/.o files in src/ which confuse
        # the cross-GHC (wrong profile tag "dyn" vs "").
        find . -name '*.hi' -o -name '*.o' -o -name '*.dyn_hi' -o -name '*.dyn_o' | xargs rm -f

        # Discover RTS include path for HsFFI.h
        GHC_LIBDIR=$(${ghcCmd} --print-libdir)
        RTS_INCLUDE=$(dirname $(find $GHC_LIBDIR -name "HsFFI.h" | head -1))

        echo "GHC: ${ghcCmd}"
        echo "GHC libdir: $GHC_LIBDIR"
        echo "RTS include: $RTS_INCLUDE"

        # Step 1: Compile JNI bridge and Android UI bridge with NDK clang
        # Core library C files always use me_jappie_hatter because
        # native methods are declared on HatterActivity (the library's
        # own class), not the consumer's subclass.
        ${builtins.concatStringsSep "\n" (map (ndkCompileJni hatterSrc) androidJniBridgeFiles)}

        ${ndkCc} -c -fPIC \
          ${if dynamicNodePool then "-DDYNAMIC_NODE_POOL"
            else if maxNodes != 256 then "-DMAX_NODES=${toString maxNodes}"
            else ""} \
          -I${sysroot}/usr/include \
          -I$RTS_INCLUDE \
          -I${hatterSrc}/include \
          -o ui_bridge_android.o \
          ${hatterSrc}/cbits/ui_bridge_android.c

        # Compile extra JNI bridge sources (consumer-specific JNI methods)
        ${builtins.concatStringsSep "\n" (builtins.genList (i:
          let src = builtins.elemAt extraJniBridge i;
              base = builtins.replaceStrings ["/"] ["_"] (builtins.baseNameOf src);
              oName = "extra_jni_${toString i}.o";
          in ''
        ${ndkCc} -c -fPIC \
          -DJNI_PACKAGE=${jniPackageMacro} \
          -I${sysroot}/usr/include \
          -I$RTS_INCLUDE \
          -I${hatterSrc}/include \
          -o ${oName} \
          ${src}
          '') (builtins.length extraJniBridge))}

        # Extra NDK compilation (e.g. SQLite, storage helpers)
        ${extraNdkCompile ndkCc sysroot}

        # Copy user entry point (plain main :: IO (), no foreign export needed)
        cp ${mainModule} Main.hs

        # Extra module copies (consumer overrides, additional modules)
        ${extraModuleCopy}

        # Step 2: Compile platform-specific C files not in the cabal c-sources.
        # numa_stubs.c: Android lacks libnuma; provides stubs for GHC's RTS.
        # run_main.c:   Calls ZCMain_main_closure via RTS API (per-app symbol).
        echo "=== Compiling platform C files ==="
        ${ghcCmd} -c -I${hatterSrc}/include -o numa_stubs.o ${hatterSrc}/cbits/numa_stubs.c
        ${ghcCmd} -c -I${hatterSrc}/include -o run_main.o ${hatterSrc}/cbits/run_main.c

        # Step 3: Link shared library.
        # Discover boot library paths dynamically — hash suffixes vary.
        GHC_PKG_DIR="${ghcPkgDir}"

        find_lib() {
          local result
          # Exclude debug (_debug), profiling (_p), threaded (_thr) variants
          # and GHC shared library stubs (*-ghc*).
          result=$(find "$GHC_PKG_DIR" -name "libHS$1-*.a" \
            ! -name '*_debug*' ! -name '*_p.a' ! -name '*_thr*' \
            ! -name '*-ghc*' | head -1)
          if [ -z "$result" ]; then
            echo "ERROR: Could not find library: $1" >&2
            exit 1
          fi
          echo "$result"
        }

        RTS_LIB=$(find_lib "rts")
        GHC_PRIM_LIB=$(find_lib "ghc-prim")
        GHC_BIGNUM_LIB=$(find_lib "ghc-bignum")
        GHC_INTERNAL_LIB=$(find_lib "ghc-internal")
        BASE_LIB=$(find_lib "base")
        INTEGER_GMP_LIB=$(find_lib "integer-gmp")
        TEXT_LIB=$(find_lib "text")
        ARRAY_LIB=$(find_lib "array")
        DEEPSEQ_LIB=$(find_lib "deepseq")
        CONTAINERS_LIB=$(find_lib "containers")
        TRANSFORMERS_LIB=$(find_lib "transformers")
        TIME_LIB=$(find_lib "time")

        echo "Libraries discovered:"
        echo "  rts: $RTS_LIB"
        echo "  ghc-prim: $GHC_PRIM_LIB"
        echo "  base: $BASE_LIB"
        echo "  containers: $CONTAINERS_LIB"

        # Step 3b: Compile Main.hs against the cross-compiled package DB.
        echo "=== Compiling Main.hs ==="
        ${ghcCmd} -c -O2 -split-sections \
          -I${hatterSrc}/include \
          ${builtins.concatStringsSep " " (map (d: "-I${d}") extraGhcIncludeDirs)} \
          ${if crossDeps != null then "-package-db ${crossDeps}/pkgdb" else ""} \
          ${thFlags} \
          ${builtins.concatStringsSep " " extraGhcFlags} \
          -i -i. \
          Main.hs

        # -no-auto-link-packages: all libraries are explicitly provided via
        # -optl below.  Without this, GHC would auto-link packages from the
        # package DB, causing hatter (and others) to be linked twice — once
        # by GHC and once by the explicit --whole-archive / lib/ sections.
        echo "=== Linking shared library ==="
        ${ghcCmd} -shared \
          -no-auto-link-packages \
          -o ${soName} \
          ${if crossDeps != null then "-package-db ${crossDeps}/pkgdb" else ""} \
          Main.o \
          numa_stubs.o \
          run_main.o \
          -optl-L${androidPkgs.gmp}/lib \
          -optl-L${androidPkgs.libffi}/lib \
          -optl-lffi \
          -optl-lgmp \
          -optl-llog \
          -optl-Wl,-z,max-page-size=16384 \
          -optl-Wl,--gc-sections \
          ${builtins.concatStringsSep " \\\n          "
            (map (f: "-optl$(pwd)/${f}.o") androidJniBridgeFiles)} \
          -optl$(pwd)/ui_bridge_android.o \
          ${builtins.concatStringsSep " " (builtins.genList (i: "-optl$(pwd)/extra_jni_${toString i}.o") (builtins.length extraJniBridge))} \
          ${builtins.concatStringsSep " " (map (o: "-optl${o}") extraLinkObjects)} \
          ${undefinedSymbolFlags "" (commonExportedSymbols ++ androidOnlySymbols)} \
          -optl-Wl,--wrap=registerForeignExports \
          -optl-Wl,--no-undefined \
          -optl-Wl,--whole-archive \
          -optl$RTS_LIB \
          -optl$GHC_PRIM_LIB \
          -optl$GHC_BIGNUM_LIB \
          -optl$GHC_INTERNAL_LIB \
          -optl$BASE_LIB \
          -optl$INTEGER_GMP_LIB \
          -optl$TEXT_LIB \
          -optl$ARRAY_LIB \
          -optl$DEEPSEQ_LIB \
          -optl$CONTAINERS_LIB \
          -optl$TRANSFORMERS_LIB \
          -optl$TIME_LIB \
          ${if crossDeps != null then "$(find ${crossDeps}/lib-main -name '*.a' -exec printf '-optl%s ' {} +)" else ""} \
          -optl-Wl,--no-whole-archive \
          ${if crossDeps != null then "$(find ${crossDeps}/lib -name '*.a' -exec printf '-optl%s ' {} +)" else ""} \
          ${if crossDeps != null then "$(find ${crossDeps}/lib-boot -name '*.a' -exec printf '-optl%s ' {} +)" else ""}
      '';

      installPhase = ''
        # Warn if .so is suspiciously large (see docs/ci-ram-regression-110.md).
        SO_SIZE_BYTES=$(stat -c %s ${soName})
        SO_SIZE_MB=$((SO_SIZE_BYTES / 1048576))
        echo ".so size: ''${SO_SIZE_MB} MB (warn threshold: ${toString soMaxSizeMB} MB)"
        if [ "$SO_SIZE_MB" -gt "${toString soMaxSizeMB}" ]; then
          echo "WARNING: ${soName} is ''${SO_SIZE_MB} MB, exceeds ${toString soMaxSizeMB} MB."
          echo "This usually means boot package .a files ended up in the --whole-archive link group."
          echo "Check that crossDeps .a files are in the correct directory (lib/ vs lib-boot/)."
        fi

        mkdir -p $out/lib/${archConfig.abiDir}
        cp ${soName} $out/lib/${archConfig.abiDir}/

        # Strip debug symbols to reduce .so size and runtime memory usage.
        # GHC embeds large debug/unwind sections; stripping typically cuts
        # the .so by 60-80%, which also prevents OOM kills on emulators.
        echo "Stripping debug symbols from ${soName}..."
        SO_BEFORE=$(stat -c %s $out/lib/${archConfig.abiDir}/${soName})
        ${ndk}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip \
          --strip-debug $out/lib/${archConfig.abiDir}/${soName}
        SO_AFTER=$(stat -c %s $out/lib/${archConfig.abiDir}/${soName})
        echo "Stripped: $((SO_BEFORE / 1048576)) MB -> $((SO_AFTER / 1048576)) MB"

        # Bundle runtime dependencies (not provided by Android)
        cp ${androidPkgs.gmp}/lib/libgmp.so $out/lib/${archConfig.abiDir}/
        cp ${androidPkgs.libffi}/lib/libffi.so $out/lib/${archConfig.abiDir}/
      '';
    };

  # ---------------------------------------------------------------------------
  # mkApk: Package shared library + Java + resources into a signed APK
  # ---------------------------------------------------------------------------
  mkApk =
    { sharedLibs ? null       # list of { lib = <drv>; abiDir = "arm64-v8a"; }
    , sharedLib ? null        # backward compat: single lib drv (assumes arm64-v8a)
    , androidSrc
    , baseJavaSrc ? null      # path to hatter's android/java/ for consumer APKs
    , apkName ? "app.apk"
    , name ? "app-apk"
    }:
    let
      resolvedLibs =
        if sharedLibs != null then sharedLibs
        else if sharedLib != null then [{ lib = sharedLib; abiDir = "arm64-v8a"; }]
        else builtins.throw "mkApk: either sharedLibs or sharedLib must be provided";
    in
    pkgs.stdenv.mkDerivation {
      inherit name;

      src = androidSrc;

      nativeBuildInputs = with pkgs; [
        jdk17_headless
        zip
        unzip
      ];

      buildPhase = ''
        export HOME=$TMPDIR

        echo "=== Step 1: Compile resources with aapt2 ==="
        mkdir -p compiled_res
        ${buildTools}/aapt2 compile \
          --dir res \
          -o compiled_res/

        echo "=== Step 2: Link resources with aapt2 ==="
        mkdir -p gen
        ${buildTools}/aapt2 link \
          -I ${platform}/android.jar \
          --manifest AndroidManifest.xml \
          --java gen \
          -o base.apk \
          compiled_res/*.flat

        echo "=== Step 3: Compile Java sources ==="
        mkdir -p classes
        find gen -name "*.java" -print

        javac \
          -source 11 -target 11 \
          -classpath ${platform}/android.jar \
          -d classes \
          $(find gen -name '*.java') \
          $(find java -name '*.java') \
          ${if baseJavaSrc != null then "$(find ${baseJavaSrc} -name '*.java')" else ""}

        echo "=== Step 4: Convert to DEX ==="
        mkdir -p dex_out
        ${buildTools}/d8 \
          --min-api 26 \
          --output dex_out \
          $(find classes -name "*.class")

        echo "=== Step 5: Build APK ==="
        cp base.apk unsigned.apk
        cd dex_out
        zip -j ../unsigned.apk classes.dex
        cd ..
        ${builtins.concatStringsSep "\n" (map (sl: ''
        mkdir -p lib/${sl.abiDir}
        cp ${sl.lib}/lib/${sl.abiDir}/*.so lib/${sl.abiDir}/
        '') resolvedLibs)}
        zip -r unsigned.apk lib/

        echo "=== Step 6: Zipalign ==="
        ${buildTools}/zipalign -f 4 unsigned.apk aligned.apk

        echo "=== Step 7: Sign APK ==="
        keytool -genkeypair \
          -keystore debug.keystore \
          -storepass android \
          -keypass android \
          -alias debug \
          -keyalg RSA \
          -keysize 2048 \
          -validity 10000 \
          -dname "CN=Debug, OU=Debug, O=Debug, L=Debug, ST=Debug, C=US"

        ${buildTools}/apksigner sign \
          --ks debug.keystore \
          --ks-pass pass:android \
          --key-pass pass:android \
          --ks-key-alias debug \
          --out ${apkName} \
          aligned.apk
      '';

      installPhase = ''
        mkdir -p $out
        cp ${apkName} $out/
      '';
    };

  # ---------------------------------------------------------------------------
  # mkIOSLib: Compile Haskell to static .a for iOS (device or simulator)
  # ---------------------------------------------------------------------------
  mkIOSLib = args: mkAppleStaticLib (args // { platform = "ios"; });

  # ---------------------------------------------------------------------------
  # mkSimulatorApp: Stage iOS sources + pre-built library for xcodebuild
  # ---------------------------------------------------------------------------
  mkSimulatorApp =
    { iosLib
    , iosSrc
    , name ? "simulator-app"
    , maxNodes ? 256
    , dynamicNodePool ? false
    }:
    mkAppleSimulatorApp {
      platformLib = iosLib;
      platformSrc = iosSrc;
      platformName = "ios";
      inherit name maxNodes dynamicNodePool;
    };

  # ---------------------------------------------------------------------------
  # mkWatchOSLib: Compile Haskell to static .a for watchOS (device or simulator)
  # ---------------------------------------------------------------------------
  mkWatchOSLib = args: mkAppleStaticLib (args // { platform = "watchos"; });

  # ---------------------------------------------------------------------------
  # mkWatchOSSimulatorApp: Stage watchOS sources + pre-built library for xcodebuild
  # ---------------------------------------------------------------------------
  mkWatchOSSimulatorApp =
    { watchosLib
    , watchosSrc
    , name ? "watchos-simulator-app"
    }:
    mkAppleSimulatorApp {
      platformLib = watchosLib;
      platformSrc = watchosSrc;
      platformName = "watchos";
      inherit name;
    };

}
