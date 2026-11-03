# A power cut just after an app made its database key, and then a database
# with it: the key must still be there after, or the database is lost.
{ pkgs ? import ./pkgs.nix { } }:
let
  hpkgs = import ./hpkgs.nix { inherit pkgs; };
  # Makes the key as the terminal platform does, at the path it's given.
  terminalKey = pkgs.runCommand "terminal-key" {
    nativeBuildInputs = [ (hpkgs.ghcWithPackages (p: [ p.hatter-terminal ])) ];
  } ''
    cat > Main.hs <<'EOF'
    import Hatter.Terminal.Platform (readKey)
    import System.Environment (getArgs)

    main :: IO ()
    main = getArgs >>= mapM_ readKey
    EOF
    mkdir -p $out/bin
    ghc -O0 Main.hs -o $out/bin/terminal-key
  '';
  # Makes the key as the desktop platform does, in its data directory.
  qtHost = pkgs.callPackage ../desktop/host.nix { include = ../include; };
  qtKey = pkgs.runCommandCC "qt-key" {
    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [ qtHost ];
  } ''
    cat > main.c <<'EOF'
    #include "hatter_qt.h"

    int main(int argc, char **argv)
    {
        uint8_t key[32];
        hatter_qt_init(&argc, argv);
        return hatter_qt_database_key(key) ? 0 : 1;
    }
    EOF
    mkdir -p $out/bin
    $CC main.c -o $out/bin/qt-key $(pkg-config --cflags --libs hatter-qt-host)
  '';
in
pkgs.testers.runNixOSTest {
  name = "database-key-crash";
  nodes.machine = {
    environment.systemPackages = [ terminalKey qtKey pkgs.sqlite ];
    environment.variables = {
      QT_QPA_PLATFORM = "offscreen";
      QT_PLUGIN_PATH = "${pkgs.qt6.qtbase}/${pkgs.qt6.qtbase.qtPluginPrefix}";
    };
    # The app's files on a disk of their own, ext4 as most Linux desktops.
    virtualisation.emptyDiskImages = [ 256 ];
    virtualisation.fileSystems."/data" = {
      device = "/dev/vdb";
      fsType = "ext4";
      autoFormat = true;
    };
  };
  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.succeed("mkdir -p /data/app")
    machine.succeed("terminal-key /data/app/database.key")
    # The desktop platform keeps it in Qt's data directory for the program.
    machine.succeed("XDG_DATA_HOME=/data qt-key")
    # Something kept with the keys, on the disk when SQLite says so: EXTRA
    # syncs even the end of its journal.
    machine.succeed("sqlite3 /data/app/app.db 'PRAGMA synchronous = EXTRA; CREATE TABLE chats (x); INSERT INTO chats VALUES (1)'")
    machine.crash()
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("sqlite3 /data/app/app.db 'SELECT x FROM chats' | grep -x 1")
    keys = "/data/app/database.key /data/qt-key/database.key"
    print(machine.succeed(f"stat -c '%n: %s bytes' {keys}"))
    machine.succeed(f"for key in {keys}; do test $(stat -c %s $key) -eq 32; done")
  '';
}
