# `nix-shell --run 'cabal test'` builds and tests the terminal backend.
let
  sources = import ../npins;
  pkgs = import sources.nixpkgs { };
  inherit (pkgs.haskell.lib) dontCheck dontHaddock;
  # Hatter without this directory, so changing it doesn't rebuild Hatter.
  hatterSrc = pkgs.lib.cleanSourceWith {
    src = ../.;
    filter = path: _: !(pkgs.lib.hasPrefix (toString ./.) path) && baseNameOf path != ".git";
  };
  hpkgs = (import ../nix/hpkgs.nix { inherit pkgs; }).extend (self: super: {
    hatter = dontHaddock (dontCheck (self.callCabal2nix "hatter" hatterSrc { }));
    hatter-terminal = self.callCabal2nix "hatter-terminal" ./. { };
  });
in
hpkgs.shellFor {
  packages = ps: [ ps.hatter-terminal ];
  nativeBuildInputs = [ pkgs.cabal-install ];
}
