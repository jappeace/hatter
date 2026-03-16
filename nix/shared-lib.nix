{ sources ? import ../npins }:
let
  android = import ./android.nix { inherit sources; };
  inherit (android) androidFFI crossLib;

  # Use project's own nixpkgs for additional tools
  pkgs = import sources.nixpkgs {
    config.allowUnfree = true;
    config.android_sdk.accept_license = true;
  };

  # The GHC cross-compiler package containing boot libraries
  ghcCross = crossLib.project.pkg-set.config.ghc.package;
  ghcLibDir = "${ghcCross}/lib/aarch64-android-ghc-9.6.3";
  rtsInclude = "${ghcLibDir}/rts-1.0.2/include";

  # The NDK toolchain for compiling the JNI bridge C code
  androidComposition = pkgs.androidenv.composeAndroidPackages {
    includeNDK = true;
  };
  ndk = "${androidComposition.ndk-bundle}/libexec/android-sdk/ndk/${androidComposition.ndk-bundle.version}";
  ndkCc = "${ndk}/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang";
  sysroot = "${ndk}/toolchains/llvm/prebuilt/linux-x86_64/sysroot";

  # Pre-compile the JNI bridge to an object file with NDK clang
  jniBridgeObj = pkgs.stdenv.mkDerivation {
    name = "jni-bridge-obj";
    phases = [ "buildPhase" "installPhase" ];
    buildPhase = ''
      ${ndkCc} -c -fPIC \
        -I${sysroot}/usr/include \
        -I${rtsInclude} \
        -o jni_bridge.o \
        ${../cbits/jni_bridge.c}
    '';
    installPhase = ''
      mkdir -p $out
      cp jni_bridge.o $out/
    '';
  };

  # Build the Haskell shared library using GHC's -shared
  # Same approach as simplex-chat: override the component to produce a .so
  # The JNI bridge object is passed as a linker input so everything
  # ends up in a single .so file
  haskellSo = crossLib.override (p: {
    # -shared but NOT -dynamic
    enableShared = false;
    # include all deps (static linking of deps into the .so)
    enableStatic = true;

    setupBuildFlags = p.component.setupBuildFlags
      ++ map (x: "--ghc-option=${x}") [
        "-shared" "-o" "libhaskellmobile.so"
        "-optl-lffi"
        "-optl-Wl,-z,max-page-size=16384"
        # Link the JNI bridge object into the .so
        "-optl${jniBridgeObj}/jni_bridge.o"
      ]
      # Force foreign export symbols to stay (LLD strips them otherwise)
      ++ map (sym: "--ghc-option=-optl-Wl,-u,${sym}") [
        "haskellInit"
        "haskellGreet"
      ];

    postInstall = ''
      mkdir -p $out/lib/arm64-v8a
      cp libhaskellmobile.so $out/lib/arm64-v8a/
    '';
  });

in haskellSo
