# Hatter's Qt Quick host (host/), the library a Qt app's program links with.
{ lib, stdenv, cmake, ninja, qt6, include, makeFontsConf, dejavu_fonts, weston, pulseaudio }:
stdenv.mkDerivation {
  pname = "hatter-qt-host";
  version = "0.1.0";
  src = ./host;
  nativeBuildInputs = [ cmake ninja ];
  buildInputs = [ qt6.qtbase qt6.qtdeclarative qt6.qtmultimedia qt6.qtsvg ];
  # A library, not a program.
  dontWrapQtApps = true;
  # Its pkg-config module needs none of Qt's, so programs' builds don't
  # take Qt's (see hpkgs.nix).
  meta.pkgConfigModules = [ "hatter-qt-host" ];
  cmakeFlags = [ "-DHATTER_INCLUDE=${include}" ] ++ lib.optional stdenv.isLinux "-DHATTER_TEST_WAYLAND=ON";
  # Its tests, offscreen, with Qt's QML modules. On Linux also in a Wayland
  # compositor, with a font to measure text, and no GL driver, as a program
  # from Nix finds none on other Linux systems; an audio server with no
  # devices records what it plays, for calls.
  doCheck = true;
  nativeCheckInputs = lib.optionals stdenv.isLinux [ weston pulseaudio ];
  preCheck = ''
    export QML_IMPORT_PATH=${qt6.qtdeclarative}/${qt6.qtbase.qtQmlPrefix}:${qt6.qtmultimedia}/${qt6.qtbase.qtQmlPrefix}
    export QT_PLUGIN_PATH=${qt6.qtbase}/${qt6.qtbase.qtPluginPrefix}:${qt6.qtsvg}/${qt6.qtbase.qtPluginPrefix}:${qt6.qtmultimedia}/${qt6.qtbase.qtPluginPrefix}
    export HOME=$TMPDIR CTEST_OUTPUT_ON_FAILURE=1
  '' + lib.optionalString stdenv.isLinux ''
    export FONTCONFIG_FILE=${makeFontsConf { fontDirectories = [ dejavu_fonts ]; }}
    export HATTER_TEST_NO_GL=1 HATTER_TEST_AUDIO=1
    export XDG_RUNTIME_DIR=$TMPDIR/run WAYLAND_DISPLAY=hatter-test
    mkdir -m 700 $XDG_RUNTIME_DIR
    weston --backend=headless --renderer=pixman --socket=$WAYLAND_DISPLAY \
      > $TMPDIR/weston.log 2>&1 &
    weston=$!
    while [ ! -e $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY ]; do sleep 0.1; done
    pulseaudio -n --daemonize=no --exit-idle-time=-1 --disable-shm=yes \
      --load=module-native-protocol-unix --load="module-null-sink sink_name=call" \
      --load="module-remap-source master=call.monitor source_name=heard" \
      > $TMPDIR/pulseaudio.log 2>&1 &
    pulse=$!
    # Slow to start on a busy machine.
    for _ in $(seq 600); do pactl info > /dev/null 2>&1 && break; sleep 0.1; done
    # Qt takes no monitor for a microphone, so one made from it.
    pactl set-default-source heard || { cat $TMPDIR/pulseaudio.log; exit 1; }
  '';
  postCheck = lib.optionalString stdenv.isLinux "kill $weston $pulse";
}
