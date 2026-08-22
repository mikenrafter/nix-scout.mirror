# nix-scout

Frontrunner profile + scout module switcher for NixOS flakes.

`nix-scout` lets optional features/tools live as small, self-contained
flakes ("scout modules") dropped into a directory inside your NixOS
config repo (the "host flake"), and lets you build and apply any one of
them on demand — install a package into a dedicated profile, drop files
into `$HOME`, or (de)register a systemd service — without running a full
`nixos-rebuild`.

## Concepts

- **Host flake** — your normal NixOS config repo. It wires in
  `nix-scout`'s `nixosModule` and points it at a modules directory.
- **Scout module** — a directory under that modules directory containing
  its own `flake.nix` (`<modules-dir>/<name>/flake.nix`). Modules carry no
  committed `flake.lock` — the host flake's lock is stamped onto them at
  switch time, so a module's inputs resolve to the same revisions your
  host already uses.
- **Facets** — what a module's `flake.nix` can export, independently:
  - `scout` — `packages.<system>.scout`, installed into a dedicated
    per-user Nix profile (`bin/` subdirectory).
  - `home` — also part of `packages.<system>.scout`, via a `home-files/`
    subdirectory copied verbatim into `$HOME`.
  - `flakelet` — `flakelets.<attr>`, a [flakelet](https://github.com/Mic92/flakelet)
    systemd unit, applied on `nixos-rebuild` and refreshed on switch.
  - `baseline` — a real NixOS module (function or attrset), imported directly
    into the host's module list at `nixos-rebuild` eval time. Because it's a
    genuine module import rather than something routed through a switch
    script, it can set **any** system-wide option — `nix.settings`, `boot.*`,
    arbitrary `services.*`, and so on — and it can read the host's own
    `config`/`lib` like any ordinary module. `nix-scout switch` never builds
    or applies `baseline` at all; it only takes effect on the next rebuild.

Every scout module's `flake.nix` follows the same boilerplate to keep the
scout/home/baseline facets and the flakelet facet definitionally separate:

```nix
lib.optionalAttrs (inputs ? nix-scout) {
  # scout
  # home
  # baseline
} // {
  # flakelet
}
```

`inputs ? nix-scout` is true when `nix-scout` (CLI switch, or the NixOS
module's rebuild-time prebuild) is evaluating the module, and false when
flakelet evaluates the module's `path:` flake on its own — so `baseline`
(along with `scout`/`home`) never builds in flakelet's own evaluation
context, same as `scout`/`home`.

## Install

Add it as a flake input and wire in the NixOS module from your host flake:

```nix
inputs.nix-scout.url = "github:mikenrafter/nix-scout";

# In your NixOS system config:
imports = [
  (inputs.nix-scout.nixosModule
    (toString ./.)          # parent: live path to your host flake root
    "scout-modules"         # modulesRel: dir under parent with <name>/flake.nix drop-ins
    inputs)                 # hostInputs: your flake's own resolved `inputs`
];
```

On activation this writes `/var/lib/nix-scout/paths` (`NIX_SCOUT_PARENT`,
`NIX_SCOUT_MODULES`), which the `nix-scout` CLI reads at runtime — without
it, every subcommand exits with a pointer back to this step. It also wires
`environment.systemPackages` to prebuild any module exporting `scout`,
registers `flakelet` facets into `services.flakelets`, and (via a forced
Home Manager shared module) puts the scout profile's `bin/`, `share`, and
man path ahead of the stale system copies for fish/bash/zsh.

## Day-to-day usage

```bash
nix-scout list                     # modules + detected facets
nix-scout new my-tool scout home   # scaffold scout-modules/my-tool/flake.nix (+ stub impls)
nix-scout switch my-tool           # materialize, build .#scout, install/apply it
nix-scout switch my-tool --show-trace   # NIX-FLAGS forward straight to `nix build`
nix-scout switch /nix/store/...    # or ref#attr — install a path directly, no module needed
nix-scout status                   # active profile, gc-roots, flakelet status
nix-scout clear                    # uninstall everything from the scout profile
nix-scout doctor                   # check + repair flakelet path-access issues
nix-scout completions fish         # also: bash, zsh
```

`switch` fans out per facet and no-ops on whichever one a module doesn't
export: package facet gets `nix build .#scout`, gc-root pinned, `bin/`
installed into the profile via `nix-env`, `home-files/` copied into
`$HOME`; flakelet facet runs `sudo flakelet update <name>` against the
entry already registered in `/etc/flakelet.json` by a prior
`nixos-rebuild` (if it's not there yet, rebuild once, then switch again).

`sudo nix-scout ...` is supported — it resolves the real invoking user's
`$HOME`/profile paths from `SUDO_USER`/`/etc/passwd` rather than acting as
root. Running it directly as root with no `SUDO_USER` is rejected.

### Authoring a module

`nix-scout new` scaffolds the facet-separation boilerplate above with stub
implementations for whichever facets you ask for:

```bash
nix-scout new my-tool scout            # packages.${system}.scout (buildEnv, bin/ only)
nix-scout new my-tool scout home       # same, plus a home-files/ subdirectory
nix-scout new my-tool flakelet         # flakelets.default + settings.nix stub
nix-scout new my-tool baseline         # a NixOS-module stub, imported on rebuild only
```

It also drops a placeholder `flake.lock` (nixpkgs `narHash` of zeros;
other locked identity fields are the literal sentinel string
`nix-scout_not-real-lockfile`) so the module evaluates standalone before
its first real switch stamps the host's actual lock over it. **Never run
`nix flake lock` inside a scout module directory** — that sentinel is
intentional, not a stale lock to fix.

A `flakelet` facet also needs `settings.nix` next to `flake.nix`, returning
`{ enable, output ? "flakelets.default", settings, autoUpdate ? {...} }`
— `nix-scout new ... flakelet` writes a working stub for this too. Missing
`settings.nix` on a module that exports `flakelets` is a hard eval error
at rebuild time.

Modules can tell rebuild-time prebuilds apart from `nix-scout switch` via
`systemRebuild` (`true` during a NixOS rebuild's prebuild pass, `false`
during `switch`, which writes a `scout-context.nix` next to the
materialized flake) — see `lib/scout-module.nix`'s `readSystemRebuild` for
the read pattern. Useful for shipping a lightweight stub in
`environment.systemPackages` while reserving a heavier payload for
explicit `switch`.

The `scout`, `home`, and `flakelet` facets cannot set system-wide NixOS
options — that's what your core host config is for, or, from inside a scout
module, the `baseline` facet: `baseline = { config, lib, ... }: { ... };`
is imported directly into the host's module list on `nixos-rebuild` and can
set anything an ordinary NixOS module could. It is never touched by
`nix-scout switch` — only a rebuild picks it up.

## Troubleshooting

`nix-scout doctor` checks (and where possible repairs) the usual failure
mode: flakelet evaluates modules as a dedicated `eval_user` via
setuid/setgid *without* `initgroups`, so supplementary group membership
(e.g. being in `users`) doesn't help it reach your modules directory. It
checks primary-gid-only path access, grants `o+x`/`o+rx` where needed,
confirms `/var/lib/flakelet` is readable, and reports any flakelet
services in an error or held state via `flakelet status --json`.

## Testing

Static, grep-only contract suites need no build and run in CI via
`checks.${system}.static-contracts`:

```
nix flake check
```

covers `module-mode`, `path-session`, `activation-clear`, `flakelet`,
`new-module`, `baseline`, and `completions`. Suites that need the built binary
(`cli`, `hm-activate-files`, `materialize`, `profile-gcroots`) are run
manually:

```
nix develop
ns-test              # all suites in tests/ (or: ns-test cli, ns-test materialize, ...)
tests/run.sh          # same, outside the devshell
```

`ns-sandbox` (also from the devshell) runs a command inside a bubblewrap
sandbox with tmpfs standing in for the per-user Nix profile and gc-roots
directories, so you can exercise `switch`/`clear` without touching your
real system profile:

```
ns-sandbox nix-scout switch my-tool
```

## Reference

- `nix-scout --help` / `man nix-scout` (`share/man/man1/nix-scout.1`) — full
  command reference, environment variables, files written, exit codes.
- `bin/nix-scout` — the CLI itself; `usage()` is the source of truth if
  this README and the man page ever drift.
- `lib/*.sh` — one script per concern (`materialize-module.sh`,
  `apply-hm.sh`, `apply-env.sh`, `apply-flakelet.sh`, `new-module.sh`,
  `flakelet-access.sh`, `hm-activate-files.sh`).
- `nixos-module.nix` — the actual NixOS module logic behind
  `self.nixosModule`.

Version 0.5.0. Bash implementation, no compiled binary. Depends on
`nixpkgs`, `nixpkgs-unstable`, `home-manager`, and `github:Mic92/flakelet`.
MIT licensed.
