# `nix-shell --run 'cabal run hatter-desktop-demo'` builds and runs the demo.
let
  sources = import ../npins;
  pkgs = import sources.nixpkgs { };
  inherit (pkgs.haskell.lib) dontCheck dontHaddock;
  # Hatter without this directory, so changing it doesn't rebuild Hatter.
  hatterSrc = pkgs.lib.cleanSourceWith {
    src = ../.;
    filter = path: _: !(pkgs.lib.hasPrefix (toString ./.) path) && baseNameOf path != ".git";
  };
  host = pkgs.callPackage ./host.nix { include = ../include; };
  hpkgs = (import ../nix/hpkgs.nix { inherit pkgs; }).extend (self: super: {
    hatter = dontHaddock (dontCheck (self.callCabal2nix "hatter" hatterSrc { }));
    hatter-desktop = self.callCabal2nix "hatter-desktop" ./. { hatter-qt-host = host; };
  });
  qt = pkgs.qt6;
in
hpkgs.shellFor {
  packages = ps: [ ps.hatter-desktop ];
  nativeBuildInputs = [
    pkgs.cabal-install
    pkgs.pkg-config
    # A display to run it on and look at it.
    pkgs.xorg-server
    pkgs.xdotool
    pkgs.imagemagick
  ];
  QT_PLUGIN_PATH = "${qt.qtbase}/${qt.qtbase.qtPluginPrefix}:${qt.qtmultimedia}/${qt.qtbase.qtPluginPrefix}";
  QML_IMPORT_PATH = "${qt.qtdeclarative}/${qt.qtbase.qtQmlPrefix}:${qt.qtmultimedia}/${qt.qtbase.qtQmlPrefix}";
  FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts pkgs.noto-fonts-color-emoji ]; };
  # Cabal keeps what pkg-config said when it configured hatter-desktop, so it's
  # configured again when the host is another build.
  shellHook = ''
    if [ "$(cat dist-newstyle/hatter-qt-host 2>/dev/null)" != ${host} ]; then
      rm -rf dist-newstyle/build/*/*/hatter-desktop-*
      mkdir -p dist-newstyle && echo ${host} > dist-newstyle/hatter-qt-host
    fi
  '';
}
