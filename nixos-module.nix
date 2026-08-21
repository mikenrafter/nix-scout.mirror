{ nixScout, nixpkgs, parent, modulesRel, flakelet }:

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

  # Inputs nix-scout provides to every scout-module outputs function at nixos-rebuild time.
  # Flakelet does not thread the parent flake's locked inputs through to path: evaluations,
  # so external inputs (e.g. llm-agents) are unavailable here even if declared in the
  # module's flake.nix inputs block.
  #
  # Upstream flakelet enhancement opportunity: flakelet could accept an `extraInputs` attr
  # in the service definition and forward them to the path: flake evaluation, allowing
  # scout modules to receive parent-pinned inputs at both rebuild and runtime.
  providedOutputsArgs = {
    nixpkgs = true; nix-scout = true; systemRebuild = true;
  };

  # Evaluate each scout-module's flake outputs (systemRebuild=true context).
  scoutOutputs = lib.mapAttrs (name: _:
    let
      m = import (evalModulesDir + "/${name}/flake.nix");
      # Detect required args (non-defaulted) that nix-scout cannot supply.
      # functionArgs returns { argName = hasDefault; }; false = required.
      requiredArgs     = lib.filterAttrs (_: hasDefault: !hasDefault) (builtins.functionArgs m.outputs);
      unsatisfied      = lib.filterAttrs (k: _: !(providedOutputsArgs ? ${k})) requiredArgs;
      unsatisfiedNames = lib.attrNames unsatisfied;
    in
    if unsatisfied != {} then throw ''
      nix-scout: scout-module '${name}' requires flake inputs that nix-scout cannot
      provide at nixos-rebuild eval time: ${lib.concatStringsSep ", " unsatisfiedNames}

      nix-scout passes only: ${lib.concatStringsSep ", " (lib.attrNames providedOutputsArgs)}

      Flakelet does not forward the parent flake's locked inputs to path: evaluations,
      so external inputs are unavailable during systemRebuild. To make an input optional,
      use @inputs and guard with `inputs ? <name>`:

        outputs = { nixpkgs, ... }@inputs:
        let pkgs = nixpkgs.legacyPackages.x86_64-linux; in {
          packages.x86_64-linux.scout =
            if inputs ? ${lib.head unsatisfiedNames}
            then inputs.${lib.head unsatisfiedNames}.packages.x86_64-linux.my-pkg
            else pkgs.runCommand "empty" {} "mkdir $out";
          ...
        }

      When llm-agents (or another input) IS available — e.g. via a top-level `nix build`
      or a future flakelet extraInputs feature — the real package is used; otherwise the
      empty fallback keeps the rebuild green and the real binary comes from systemPackages.
    ''
    else m.outputs {
      inherit nixpkgs;
      nix-scout = nixScout;
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

  scoutBin = name: "/nix/var/nix/profiles/per-user/${name}/nix-scout/bin";
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
