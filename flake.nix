{
  description = "nix-scout — frontrunner profile + scout module switcher";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flakelet = {
      url = "github:Mic92/flakelet";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
  };

  outputs = { self, nixpkgs, home-manager, flakelet, ... }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    scoutModuleLib = import ./lib/scout-module.nix;
  in {
    lib = scoutModuleLib;

    overlays.default = final: prev: {
      nix-scout = self.packages.${prev.system}.nix-scout;
    };

    # parent: live filesystem path to the host flake root.
    # modulesRel: directory under parent that contains <name>/flake.nix drop-ins.
    # hostInputs: the host (parent) flake's own full, already-resolved `inputs`
    # attrset — threaded through to scout-module eval-time calls so a module's
    # declared inputs (nixpkgs, nix-scout, or anything else the host also
    # declares at top level) resolve identically to what a real `nix build`
    # against the parent-lock-derived flake.lock would give at switch time.
    nixosModule = parent: modulesRel: hostInputs: {
      _file = toString ./nixos-module.nix;
      imports = [
        (import ./nixos-module.nix {
          nixScout = self;
          inherit parent modulesRel flakelet;
          inputs = hostInputs;
        })
      ];
    };

    packages.${system}.nix-scout = pkgs.stdenv.mkDerivation {
      pname = "nix-scout";
      version = "0.6.0";
      src = ./.;
      dontBuild = true;
      installPhase = ''
        runHook preInstall
        install -Dm755 $src/bin/nix-scout                $out/bin/nix-scout
        install -Dm755 $src/lib/materialize-module.sh  $out/lib/materialize-module.sh
        install -Dm644 $src/lib/scout-lib.sh           $out/lib/scout-lib.sh
        install -Dm755 $src/lib/new-module.sh          $out/lib/new-module.sh
        install -Dm755 $src/lib/update-module.sh       $out/lib/update-module.sh
        install -Dm755 $src/lib/apply-hm.sh            $out/lib/apply-hm.sh
        install -Dm755 $src/lib/apply-env.sh           $out/lib/apply-env.sh
        install -Dm755 $src/lib/apply-flakelet.sh      $out/lib/apply-flakelet.sh
        install -Dm755 $src/lib/flakelet-access.sh     $out/lib/flakelet-access.sh
        install -Dm755 $src/lib/hm-activate-files.sh   $out/lib/hm-activate-files.sh
        install -Dm644 $src/share/man/man1/nix-scout.1 \
          $out/share/man/man1/nix-scout.1
        mkdir -p $out/share/fish/vendor_completions.d
        bash $out/bin/nix-scout completions fish \
          > $out/share/fish/vendor_completions.d/nix-scout.fish
        mkdir -p $out/share/bash-completion/completions
        bash $out/bin/nix-scout completions bash \
          > $out/share/bash-completion/completions/nix-scout
        # nixpkgs zsh adds $out/share/zsh/site-functions to fpath (see pkgs.zsh).
        mkdir -p $out/share/zsh/site-functions
        bash $out/bin/nix-scout completions zsh \
          > $out/share/zsh/site-functions/_nix-scout
        runHook postInstall
      '';
      meta = {
        description = "nix-scout — scout module switcher";
        license = pkgs.lib.licenses.mit;
        mainProgram = "nix-scout";
      };
    };

    # Run static (grep-only) contract checks without building the package.
    # Integration suites (cli, hm-activate-files, materialize, profile-gcroots)
    # require the binary and are run manually via tests/run.sh or ns-test.
    # Static (grep-only) contract checks — no binary build required.
    # Integration suites need the built binary; run those via tests/run.sh or ns-test.
    checks.${system}.static-contracts = pkgs.runCommand "nix-scout-static-contracts"
      { buildInputs = [ pkgs.bash pkgs.gnugrep pkgs.coreutils pkgs.findutils pkgs.diffutils ]; }
      ''
        export NIX_SCOUT_ROOT=${./.}
        # Run from the whole-repo store path (not per-file store refs) so each
        # suite's `source .../_lib.sh` sibling-lookup resolves.
        bash "$NIX_SCOUT_ROOT/tests/module-mode.sh"
        bash "$NIX_SCOUT_ROOT/tests/path-session.sh"
        bash "$NIX_SCOUT_ROOT/tests/activation-clear.sh"
        bash "$NIX_SCOUT_ROOT/tests/activation-home-files.sh"
        bash "$NIX_SCOUT_ROOT/tests/flakelet.sh"
        bash "$NIX_SCOUT_ROOT/tests/new-module.sh"
        bash "$NIX_SCOUT_ROOT/tests/baseline.sh"
        bash "$NIX_SCOUT_ROOT/tests/completions.sh"
        touch $out
      '';

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
