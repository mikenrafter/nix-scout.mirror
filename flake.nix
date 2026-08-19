{
  description = "nix-scout — frontrunner profile + scout module switcher";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, ... }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    # Wrap the base nix-scout package with scoutModules/scoutParent baked in.
    # Used by both the NixOS module and scout-module consumers.
    lib.mkScoutPkg = { pkgs, scoutModules, scoutParent }:
      let base = self.packages.${pkgs.system}.nix-scout;
      in pkgs.stdenv.mkDerivation {
        pname = "nix-scout";
        version = base.version or "0.3.0";
        src = base;
        dontBuild = true;
        installPhase = ''
          runHook preInstall
          mkdir -p $out/bin $out/lib
          install -m755 $src/bin/nix-scout             $out/bin/nix-scout
          install -m755 $src/lib/materialize-module.sh $out/lib/materialize-module.sh
          install -m755 $src/lib/apply-output.sh       $out/lib/apply-output.sh
          install -m755 $src/lib/hm-activate-files.sh  $out/lib/hm-activate-files.sh
          substituteInPlace $out/bin/nix-scout \
            --replace-fail '@scoutModules@' '${scoutModules}' \
            --replace-fail '@scoutParent@'  '${scoutParent}'
          cp -r $src/share $out/
          runHook postInstall
        '';
      };

    nixScout.nixosModules.default = {
      _file = toString ./nixos-module.nix;
      imports = [
        (import ./nixos-module.nix { inherit self; })
      ];
    };

    packages.${system}.nix-scout = pkgs.stdenv.mkDerivation {
      pname = "nix-scout";
      version = "0.3.0";
      src = ./.;
      dontBuild = true;
      installPhase = ''
        runHook preInstall
        install -Dm755 $src/bin/nix-scout             $out/bin/nix-scout
        install -Dm755 $src/lib/materialize-module.sh $out/lib/materialize-module.sh
        install -Dm755 $src/lib/apply-output.sh       $out/lib/apply-output.sh
        install -Dm755 $src/lib/hm-activate-files.sh  $out/lib/hm-activate-files.sh
        install -Dm644 $src/share/man/man1/nix-scout.1 \
          $out/share/man/man1/nix-scout.1
        mkdir -p $out/share/fish/vendor_completions.d
        bash $out/bin/nix-scout completions fish \
          > $out/share/fish/vendor_completions.d/nix-scout.fish
        runHook postInstall
      '';
      meta = {
        description = "nix-scout — scout module switcher";
        license = pkgs.lib.licenses.mit;
        mainProgram = "nix-scout";
      };
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = with pkgs; [
        nix
        bash
        shellcheck
        jq
        bubblewrap
        coreutils
        diffutils
        findutils
        gnugrep
      ];

      shellHook = ''
        echo "nix-scout dev — commands: ns-test, ns-sandbox"

        ns-test() {
          local suite="''${1:-all}"
          local tests_dir="''${NIX_SCOUT_TESTS:-$(dirname "$(readlink -f "''${BASH_SOURCE[0]:-$0}")")/tests}"
          if [[ "$suite" == "all" ]]; then
            for f in "$tests_dir"/*.sh; do
              [[ -x "$f" ]] || continue
              echo "==> ''${f##*/}"
              bash "$f"
            done
          else
            bash "$tests_dir/$suite.sh"
          fi
        }

        # Run a command inside a nix-scout sandbox: tmpfs replaces the per-user
        # nix profile and gcroots directories so operations are fully isolated.
        ns-sandbox() {
          local _tmp
          _tmp="$(mktemp -d)"
          mkdir -p \
            "$_tmp/profiles/per-user/$USER" \
            "$_tmp/gcroots/per-user/$USER"
          bwrap \
            --dev-bind / / \
            --tmpfs /tmp \
            --bind "$_tmp/profiles" /nix/var/nix/profiles/per-user \
            --bind "$_tmp/gcroots"  /nix/var/nix/gcroots/per-user \
            --die-with-parent \
            -- "''${@:-$SHELL}"
          rm -rf "$_tmp"
        }
      '';
    };
  };
}
