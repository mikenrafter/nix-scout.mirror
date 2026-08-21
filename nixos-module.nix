{ self, nixpkgs, parent, modulesRel, flakelet }:

# nix-scout host framework — PATH, profile, HM copy-activator, clear-on-activation.
# Scout payload modules live under ${parent}/${modulesRel} and are switched at runtime.
#
# Constructor: nixosModule parent modulesRel
# Runtime paths: /var/lib/nix-scout/paths (written on activation).
# Exposes pkgs.nix-scout via nixpkgs.overlays.default for scout-module flakes.
#
# Facets per scout-module:
#   packages.<system>.scout  — optional; installed into systemPackages on rebuild.
#   flakelets.<attr>         — optional; requires settings.nix; registered with flakelet.
# A module may export both facets or only one.
# Missing settings.nix when flakelets is present is a hard eval error.
#
# module-mode: scout modules cannot set system-wide NixOS options (use core config).

{ config, lib, pkgs, ... }:

let
  modulesDir = "${parent}/${modulesRel}";
  scoutPkgs = pkgs.extend self.overlays.default;
  nixScoutPkg = scoutPkgs.nix-scout;

  scoutDirs = lib.filterAttrs (name: v:
    v == "directory" && builtins.pathExists (modulesDir + "/${name}/flake.nix")
  ) (builtins.readDir modulesDir);

  # Evaluate each scout-module's flake outputs (systemRebuild=true context).
  scoutOutputs = lib.mapAttrs (name: _:
    let m = import (modulesDir + "/${name}/flake.nix");
    in m.outputs {
      inherit nixpkgs;
      nix-scout = self;
      systemRebuild = true;
    }
  ) scoutDirs;

  # Prebuild only modules that expose packages.<system>.scout.
  prebuiltModules = lib.mapAttrsToList (_: out: out.packages.${pkgs.system}.scout) (
    lib.filterAttrs (_: out:
      (out ? packages)
      && (out.packages ? ${pkgs.system})
      && (out.packages.${pkgs.system} ? scout)
    ) scoutOutputs
  );

  # Import settings.nix for each module that exports flakelets and build the
  # services.flakelets.services attrset.  Missing settings.nix is a hard error.
  flakeletServices = lib.foldlAttrs (acc: name: out:
    if !(out ? flakelets) then acc
    else
      let
        settingsFile = modulesDir + "/${name}/settings.nix";
        meta = if builtins.pathExists settingsFile
          then import settingsFile { inherit config lib; }
          else throw "nix-scout: scout-module '${name}' exports flakelets but has no settings.nix — add settings.nix with { enable, output?, settings, autoUpdate? }";
      in
      acc // lib.optionalAttrs meta.enable {
        ${name} = {
          flake  = "path:${modulesDir}/${name}";
          output = meta.output or "flakelets.default";
          settings = meta.settings or {};
        } // lib.optionalAttrs (meta ? autoUpdate) {
          autoUpdate = meta.autoUpdate;
        };
      }
  ) {} scoutOutputs;

  normalUserNames = lib.attrNames (lib.filterAttrs (_: u: u.isNormalUser) config.users.users);

  scoutBin = name: "/nix/var/nix/profiles/per-user/${name}/nix-scout/bin";
in
{
  _file = toString ./nixos-module.nix;

  imports = [ flakelet.nixosModules.flakelet ];

  nixpkgs.overlays = [ self.overlays.default ];

  environment.systemPackages = prebuiltModules;

  services.flakelets = {
    enable = true;
    services = flakeletServices;
  };

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

  # Grant the flakelet eval user traversal into the parent repo directory so
  # `flakelet update` (running as the flakelet system user, which is in the
  # `users` group) can reach path: flake entries under ${parent}.
  system.activationScripts.nix-scout-flakelet-access = {
    text = ''
      # Allow the `users` group to traverse into the parent directory.
      # g+x grants traversal only, not directory listing — safe on user homes.
      if [[ -d "${parent}" ]]; then
        chmod g+x "${parent}"
      fi
    '';
    deps = [ "users" "nix-scout-config" ];
  };

  users.users.flakelet.extraGroups = [ "users" ];
}
