{ hpkgs ? import ./nix/hpkgs.nix {}
,
}:
hpkgs.template-project
