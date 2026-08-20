{ self, nixpkgs, parent, modulesRel }:

# nix-scout host framework — PATH, profile, HM copy-activator, clear-on-activation.
# Scout payload modules live under ${parent}/${modulesRel} and are switched at runtime.
#
# Constructor: nixosModule parent modulesRel
# Runtime paths: /var/lib/nix-scout/paths (written on activation).
# Exposes pkgs.nix-scout via nixpkgs.overlays.default for scout-module flakes.

{ config, lib, pkgs, ... }:

let
  modulesDir = "${parent}/${modulesRel}";
  scoutPkgs = pkgs.extend self.overlays.default;
  nixScoutPkg = scoutPkgs.nix-scout;

  scoutDirs = lib.filterAttrs (name: v:
    v == "directory" && builtins.pathExists (modulesDir + "/${name}/flake.nix")
  ) (builtins.readDir modulesDir);

  prebuiltModules = lib.mapAttrsToList (name: _:
    let
      m = import (modulesDir + "/${name}/flake.nix");
      out = m.outputs {
        inherit nixpkgs;
        nix-scout = self;
        systemRebuild = true;
      };
    in out.packages.${pkgs.system}.scout
  ) scoutDirs;

  normalUserNames = lib.attrNames (lib.filterAttrs (_: u: u.isNormalUser) config.users.users);

  scoutBin = name: "/nix/var/nix/profiles/per-user/${name}/nix-scout/bin";
in
{
  _file = toString ./nixos-module.nix;

  nixpkgs.overlays = [ self.overlays.default ];

  environment.systemPackages = prebuiltModules;

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

  system.activationScripts.nix-scout-config = {
    text = ''
      install -d -m755 /var/lib/nix-scout
      cat > /var/lib/nix-scout/paths <<EOF
      NIX_SCOUT_PARENT=${parent}
      NIX_SCOUT_MODULES=${modulesDir}
      EOF
      chmod 644 /var/lib/nix-scout/paths
    '';
  };

  system.activationScripts.nix-scout-dirs = {
    text = lib.concatMapStrings (user: ''
      install -d -o "${user}" -g root -m755 \
        "/nix/var/nix/gcroots/per-user/${user}/nix-scout" \
        "/nix/var/nix/profiles/per-user/${user}"
    '') normalUserNames;
    deps = [ "users" "nix-scout-config" ];
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
