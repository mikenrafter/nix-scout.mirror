# Helpers for scout-module flakes (packages.<system>.scout).
#
# Scout modules learn the build mode from:
#   systemRebuild = true  — NixOS rebuild prebuild (environment.systemPackages)
#   systemRebuild = false — `nix-scout switch` (ephemeral profile; cleared on boot/clear)
#
# In flake.nix (moduleRoot is usually ./.):
#   outputs = args: let
#     systemRebuild = (import <nix-scout/lib/scout-module.nix>).readSystemRebuild ./. args;
#   in { ... };

{
  readSystemRebuild = moduleRoot: args:
    args.systemRebuild or (
      let
        contextFile = moduleRoot + "/scout-context.nix";
      in
        if builtins.pathExists contextFile
        then (import contextFile).systemRebuild
        else false
    );
}
