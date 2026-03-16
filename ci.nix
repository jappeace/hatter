{
  native = import ./default.nix {};
  android = (import ./nix/android.nix {}).lib;
  apk = import ./nix/apk.nix {};
}
