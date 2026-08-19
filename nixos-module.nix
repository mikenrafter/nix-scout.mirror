{ self, ... }:

# nix-scout host framework — PATH, profile, HM copy-activator, clear-on-activation.
# Scout payload modules live under $NIX_SCOUT_MODULES and are switched at runtime.
#
# module-mode: nix-scout cannot set NixOS options like programs.steam.enable.
# System-wide options belong in the core flake / nfb, not scout modules.

{ config, lib, pkgs, ... }:

let
  cfg = config.v0id.scout;

  scoutUser = cfg.user;
  scoutProfile = "/nix/var/nix/profiles/per-user/${scoutUser}/nix-scout";
  scoutProfileBin = "${scoutProfile}/bin";

  scoutRoot = cfg.root;
  scoutModules = cfg.modules;
  scoutParent = cfg.parent;

  baseNixScoutPkg = self.packages.${pkgs.system}.nix-scout;

  # Wrap the base package with paths baked in via substituteInPlace so the
  # system binary works without env vars (including under sudo).
  nixScoutPkg = pkgs.stdenv.mkDerivation {
    pname = "nix-scout";
    version = baseNixScoutPkg.version or "0.2.0";
    src = baseNixScoutPkg;
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin $out/lib
      install -m755 $src/bin/nix-scout          $out/bin/nix-scout
      install -m755 $src/lib/materialize-module.sh $out/lib/materialize-module.sh
      install -m755 $src/lib/apply-output.sh    $out/lib/apply-output.sh
      install -m755 $src/lib/hm-activate-files.sh $out/lib/hm-activate-files.sh
      substituteInPlace $out/bin/nix-scout \
        --replace-fail '@scoutRoot@'    '${scoutRoot}'    \
        --replace-fail '@scoutModules@' '${scoutModules}' \
        --replace-fail '@scoutParent@'  '${scoutParent}'
      runHook postInstall
    '';
  };
in
{
  _file = toString ./nixos-module.nix;

  options.v0id.scout = {
    enable = lib.mkEnableOption "nix-scout dedicated profile + PATH injection" // { default = true; };
    user = lib.mkOption {
      type = lib.types.str;
      default = "v0id";
      description = "User owning the scout profile (profiles/per-user/<user>/nix-scout).";
    };
    root = lib.mkOption {
      type = lib.types.str;
      description = "Filesystem path to the nix-scout installation root (bin/ and lib/ live here).";
    };
    modules = lib.mkOption {
      type = lib.types.str;
      description = "Filesystem path to the scout modules directory (contains <name>/flake.nix drop-ins).";
    };
    parent = lib.mkOption {
      type = lib.types.str;
      description = "Filesystem path to the parent flake root (for lock merge).";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ nixScoutPkg ];

    environment.profiles = lib.mkBefore [ scoutProfile ];

    home-manager.users.${scoutUser} = { lib, ... }: {
      home.sessionPath = [ scoutProfileBin ];
      programs.fish.interactiveShellInit = lib.mkAfter ''
        fish_add_path -m ${scoutProfileBin}
      '';

      home.activation.checkLinkTargets = lib.mkForce (
        lib.hm.dag.entryBefore [ "writeBoundary" ] ''
          :
        ''
      );

      home.activation.linkGeneration = lib.mkForce (
        lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          newGenPath="$newGenPath" oldGenPath="''${oldGenPath:-}" ${lib.getExe pkgs.bash} ${nixScoutPkg}/lib/hm-activate-files.sh
        ''
      );
    };

    system.activationScripts.nix-scout-clear = {
      text = ''
        scout_user="${scoutUser}"
        scout_profile="/nix/var/nix/profiles/per-user/${scoutUser}/nix-scout"
        scout_gcroots="/nix/var/nix/gcroots/per-user/${scoutUser}/nix-scout"

        if [[ -e "$scout_profile" ]]; then
          ${pkgs.nix}/bin/nix-env -p "$scout_profile" --uninstall '.*' 2>/dev/null || true
          rm -f "$scout_profile" "$scout_profile-"* 2>/dev/null || true
        fi

        if [[ -d "$scout_gcroots" ]]; then
          find "$scout_gcroots" -mindepth 1 -delete 2>/dev/null || true
        fi
      '';
      deps = [ "users" ];
    };
  };
}
