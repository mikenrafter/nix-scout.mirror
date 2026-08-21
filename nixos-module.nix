{ nixScout, parent, modulesRel, flakelet, inputs }:

# nix-scout host framework — PATH, profile, HM copy-activator, clear-on-activation.
# Scout payload modules live under ${parent}/${modulesRel} and are switched at runtime.
#
# Constructor: nixosModule parent modulesRel hostInputs
# Runtime paths: /var/lib/nix-scout/paths (written on activation).
# Exposes pkgs.nix-scout via nixpkgs.overlays.default for scout-module flakes.
#
# Facets per scout-module:
#   packages.<system>.scout  — optional; installed into systemPackages on rebuild.
#   flakelets.<attr>         — optional; requires settings.nix; registered with flakelet.
# A module may export both facets or only one.
# Missing settings.nix when flakelets is present is a hard eval error.
#
# Convention (enforced by `nix-scout new`, expected of every module):
#   outputs = ... inputs:
#     lib.optionalAttrs (inputs ? nix-scout) { # scout  # home } // { # flakelet }
# Empty sections keep only the denoting comment. Flakelet-only modules use a
# single-arg `outputs = inputs:` so path: flakelet eval does not imply lockable inputs.
#
# module-mode: scout modules cannot set system-wide NixOS options (use core config).
#
# Pure-eval note: eval-time filesystem access (readDir, pathExists, import) uses
# `self` (the host flake's store path, received via specialArgs) so pure evaluation
# mode is satisfied.  The live WIP path (`parent`) is written to the runtime paths
# file and used for flakelet path: references so the CLI always sees the live tree.

{ config, lib, pkgs, self, ... }:

let
  evalModulesDir    = "${self}/${modulesRel}";
  runtimeModulesDir = "${parent}/${modulesRel}";
  scoutPkgs = pkgs.extend nixScout.overlays.default;
  nixScoutPkg = scoutPkgs.nix-scout;

  scoutDirs = lib.filterAttrs (name: v:
    v == "directory" && builtins.pathExists (evalModulesDir + "/${name}/flake.nix")
  ) (builtins.readDir evalModulesDir);

  # Evaluate each scout-module's flake outputs (systemRebuild=true context).
  #
  # `inputs` is the parent flake's own full, already-resolved `inputs` attrset
  # (threaded through from the nixosModule constructor), merged with
  # `nix-scout`/`systemRebuild` markers. This is deliberately the *same* value
  # a module's own declared inputs would resolve to via a real `nix build`
  # against a parent-lock-derived flake.lock (see materialize-module.sh) —
  # any top-level parent input (nixpkgs, llm-agents, nix-scout, ...) is
  # available here by name with no per-module opt-in, so eval-time
  # (nixos-rebuild) and switch-time (`nix-scout switch`) resolve identically
  # for anything the module actually declares.
  #
  # `inputs ? nix-scout` is what a scout-module's outputs function should use
  # to distinguish this call (or a real `nix build` against a module that
  # declares `inputs.nix-scout`) from flakelet's own runtime evaluation,
  # which never provides `nix-scout` — see the module-authoring convention
  # documented in scout-modules/*/flake.nix.
  scoutOutputs = lib.mapAttrs (name: _:
    let
      m = import (evalModulesDir + "/${name}/flake.nix");
    in
      m.outputs (inputs // { nix-scout = nixScout; systemRebuild = true; })
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
        settingsFile = evalModulesDir + "/${name}/settings.nix";
        meta = if builtins.pathExists settingsFile
          then import settingsFile { inherit config lib; }
          else throw "nix-scout: scout-module '${name}' exports flakelets but has no settings.nix — add settings.nix with { enable, output?, settings, autoUpdate? }";
      in
      acc // lib.optionalAttrs meta.enable {
        ${name} = {
          flake  = "path:${runtimeModulesDir}/${name}";
          output = meta.output or "flakelets.default";
          settings = meta.settings or {};
        } // lib.optionalAttrs (meta ? autoUpdate) {
          autoUpdate = meta.autoUpdate;
        };
      }
  ) {} scoutOutputs;

  normalUserNames = lib.attrNames (lib.filterAttrs (_: u: u.isNormalUser) config.users.users);

  scoutProfile = name: "/nix/var/nix/profiles/per-user/${name}/nix-scout";
  scoutBin = name: "${scoutProfile name}/bin";
  scoutShare = name: "${scoutProfile name}/share";
  scoutMan = name: "${scoutProfile name}/share/man";
in
{
  _file = toString ./nixos-module.nix;

  imports = [ flakelet.nixosModules.flakelet ];

  nixpkgs.overlays = [ nixScout.overlays.default ];

  environment.systemPackages = prebuiltModules;

  services.flakelets = {
    enable = true;
    services = flakeletServices;
  };

  home-manager.sharedModules = lib.mkForce [
    ({ config, lib, ... }: {
      home.sessionPath = [ (scoutBin config.home.username) ];
      home.sessionVariables = {
        # "$VAR" is fine in "..." — Nix only interpolates ${...}. Use \${VAR} for braces.
        XDG_DATA_DIRS = "${scoutShare config.home.username}:$XDG_DATA_DIRS";
        MANPATH = "${scoutMan config.home.username}:$MANPATH";
      };
      programs.fish.interactiveShellInit = lib.mkAfter ''
        fish_add_path -m ${scoutBin config.home.username}
      '';
      programs.bash.initExtra = lib.mkAfter ''
        [[ -f "''${XDG_CONFIG_HOME:-''$HOME/.config}/bash/nix-scout.bash" ]] && \
          source "''${XDG_CONFIG_HOME:-''$HOME/.config}/bash/nix-scout.bash"
      '';
      programs.zsh.initExtra = lib.mkAfter ''
        [[ -f "''${XDG_CONFIG_HOME:-''$HOME/.config}/zsh/nix-scout.zsh" ]] && \
          source "''${XDG_CONFIG_HOME:-''$HOME/.config}/zsh/nix-scout.zsh"
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
      NIX_SCOUT_MODULES=${runtimeModulesDir}
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

  # Flakelet evaluates path: flakes as eval_user via setuid/setgid without
  # initgroups — supplementary groups (e.g. users) are ineffective. Walk the
  # modules tree and grant other-x / other-rx so primary-gid-only credentials
  # can reach every registered flakelet module.
  system.activationScripts.nix-scout-flakelet-access = {
    text = ''
      ${pkgs.bash}/bin/bash ${nixScoutPkg}/lib/flakelet-access.sh grant \
        ${lib.escapeShellArg runtimeModulesDir} \
        ${lib.escapeShellArgs (lib.attrNames flakeletServices)}
    '';
    deps = [ "users" "nix-scout-config" ];
  };
}
