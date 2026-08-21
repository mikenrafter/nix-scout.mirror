{
  description = "nix-scout test fixture: tiny program payload (not production)";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  outputs = { self, nixpkgs }: let
    pkgs = nixpkgs.legacyPackages.x86_64-linux;
  in {
    packages.x86_64-linux.default = pkgs.stdenv.mkDerivation {
      name = "scout-probe";
      src = null;
      dontUnpack = true;
      installPhase = ''
        mkdir -p $out/bin
        printf '%s\n' '#!/bin/sh' 'echo scout-probe-ok' > $out/bin/scout-probe
        chmod +x $out/bin/scout-probe
      '';
    };
  };
}
