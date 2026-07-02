# Native Android APK build (Linux build host).
# Builds a multi-arch APK containing both arm64-v8a and armeabi-v7a.
# This is the real cross-compile; it requires a Linux build host.  On macOS it
# is invoked indirectly through apk-darwin-vm.nix (inside a Linux VM), so this
# file is only ever evaluated with an x86_64-linux build platform.
{ sources ? import ../npins }:
let
  lib = import ./lib.nix { inherit sources; };
  sharedLibAarch64 = import ./android.nix { inherit sources; androidArch = "aarch64"; };
  sharedLibArmv7a  = import ./android.nix { inherit sources; androidArch = "armv7a"; };
in
lib.mkApk {
  sharedLibs = [
    { lib = sharedLibAarch64; abiDir = "arm64-v8a"; }
    { lib = sharedLibArmv7a;  abiDir = "armeabi-v7a"; }
  ];
  androidSrc = ../android;
  apkName = "hatter.apk";
  name = "hatter-apk";
}
