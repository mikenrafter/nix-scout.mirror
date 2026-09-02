{
  # nix-scout — test fixture: config-only home-files module (not production).
  # Named "nix-scout" so it matches tests/profile-gcroots.sh and
  # tests/materialize.sh, which switch/materialize a module literally named
  # "nix-scout" to exercise the "config-only home-files scout gets a
  # gc-root" path (packages.*.scout present, no bin/ — no profile install).
  # flake.lock is kept as a copy of the parent repo's own lock (see
  # sync_lock_from_parent in lib/scout-lib.sh); nix-scout update/switch
  # re-syncs it in place.

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  inputs.nix-scout.url = "github:mikenrafter/nix-scout";
  inputs.nix-scout.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { nixpkgs, ... }@inputs:
  let
    system = "x86_64-linux";
    lib = nixpkgs.lib;
  in
  lib.optionalAttrs (inputs ? nix-scout) (
    let
      pkgs = import nixpkgs { inherit system; };
    in {
      # scout
      # home
      packages.${system}.scout = pkgs.runCommand "scout-nix-scout-home" { } ''
        mkdir -p $out/home-files/.config/nix-scout-fixture
        echo '{}' > $out/home-files/.config/nix-scout-fixture/config.json
      '';
      # baseline
    }
  ) // {
    # flakelet
  };
}
