{ self, nixpkgs, parent, modulesRel }:

# nix-scout host framework — PATH, profile, HM copy-activator, clear-on-activation.
# Scout payload modules live under ${parent}/${modulesRel} and are switched at runtime.
#
# Constructor: nixosModule parent modulesRel
# module-mode: nix-scout cannot set NixOS options like programs.steam.enable.
# System-wide options belong in the core flake / nfb, not scout modules.

{ config, lib, pkgs, ... }:

let
  modulesDir = "${parent}/${modulesRel}";

  nixScoutPkg = self.lib.mkScoutPkg {
    inherit pkgs;
    paths = {
      scoutParent = parent;
      scoutModules = modulesDir;
    };
  };

  # Live tree has no scout-paths.nix; the constructor already installs the baked
  # CLI. `nix-scout switch nix-scout` materializes first, then mkScoutPkg reads
  # the seeded file.
  scoutDirs = lib.filterAttrs (name: v: v == "directory" && name != "nix-scout")
    (builtins.readDir modulesDir);

  prebuiltModules = lib.mapAttrsToList (name: _:
    let
      m = import (modulesDir + "/${name}/flake.nix");
      out = m.outputs {
        inherit nixpkgs;
        nix-scout = self;
      };
    in out.packages.${pkgs.system}.scout
  ) scoutDirs;

  normalUserNames = lib.attrNames (lib.filterAttrs (_: u: u.isNormalUser) config.users.users);

  scoutBin = name: "/nix/var/nix/profiles/per-user/${name}/nix-scout/bin";
in
{
  _file = toString ./nixos-module.nix;

  environment.systemPackages = [ nixScoutPkg ] ++ prebuiltModules;

  # sharedModules + mkForce concatenates with the host's mkForce [] (niri strip)
  # without reading home-manager.users / users.users in a cycle.
  home-manager.sharedModules = lib.mkForce [
    ({ config, lib, ... }: {
      home.sessionPath = [ (scoutBin config.home.username) ];
      programs.fish.interactiveShellInit = lib.mkAfter ''
        fish_add_path -m ${scoutBin config.home.username}
      '';

      home.activation.checkLinkTargets = lib.mkForce (
        lib.hm.dag.entryBefore [ "writeBoundary" ] ''
          :
        ''
      );

      home.activation.linkGeneration = lib.mkForce (
        lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          ${pkgs.coreutils}/bin/env "newGenPath=$newGenPath" "oldGenPath=''${oldGenPath:-}" ${lib.getExe pkgs.bash} ${nixScoutPkg}/lib/hm-activate-files.sh
        ''
      );
    })
  ];

  system.activationScripts.nix-scout-dirs = {
    text = lib.concatMapStrings (user: ''
      install -d -o "${user}" -g root -m755 \
        "/nix/var/nix/gcroots/per-user/${user}/nix-scout" \
        "/nix/var/nix/profiles/per-user/${user}"
    '') normalUserNames;
    deps = [ "users" ];
  };

  system.activationScripts.nix-scout-clear = {
    text = lib.concatMapStrings (user: ''
      scout_profile="/nix/var/nix/profiles/per-user/${user}/nix-scout"
      scout_gcroots="/nix/var/nix/gcroots/per-user/${user}/nix-scout"

      if [[ -e "$scout_profile" ]]; then
        ${pkgs.nix}/bin/nix-env -p "$scout_profile" --uninstall '.*' 2>/dev/null || true
        rm -f "$scout_profile" "$scout_profile-"* 2>/dev/null || true
      fi

      if [[ -d "$scout_gcroots" ]]; then
        find "$scout_gcroots" -mindepth 1 -delete 2>/dev/null || true
      fi
    '') normalUserNames;
    deps = [ "users" "nix-scout-dirs" ];
  };
}
