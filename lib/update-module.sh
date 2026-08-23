#!/usr/bin/env bash
# Sync a scout module's committed flake.lock structure with its flake.nix-
# declared inputs, while keeping the nix-scout framework node dummy.
#
# nix-scout is the only input whose committed content is never actually used
# for real: nix-scout switch/rebuild always threads the parent flake's own
# already-resolved inputs instead (materialize-module.sh stamps the parent's
# flake.lock over the module's before building), and a module's own
# flake.nix never dereferences it beyond an `inputs ? nix-scout` existence
# check (see scout-modules/*/flake.nix convention) — confirmed empirically:
# `nix build path:<module>#scout --show-trace` never touches nix-scout's
# content. So keeping it as the dummy sentinel lib/new-module.sh writes is
# always safe, on any evaluation path.
#
# nixpkgs is NOT in the same category, despite scaffolding alongside
# nix-scout as a "framework" input — every scout module's `outputs` does
# `lib = nixpkgs.lib;` at the very top, unconditionally forced the instant
# anything calls `outputs` for real, before any facet gate is even reached.
# `nix build path:<module>#scout --show-trace` confirms this directly: the
# forced fetch chain is `outputs -> nixpkgs.result -> import -> fetchFinalTree`.
# nixpkgs must always resolve to real, fetchable content.
#
# Every OTHER declared input (e.g. a module pulling its own CLI straight from
# an upstream flake) must likewise stay real: flakelet evaluates a registered
# module's flake directly via `builtins.getFlake` and actually calls its
# `impl`, forcing whatever that input resolves to via the module's own
# committed flake.lock — there is no override mechanism for it (flakelet's
# `input_overrides` only supports the key "nixpkgs", which is a separate
# `pkgs`-*argument* substitution flakelet injects itself, structurally
# unrelated to a flake's own declared inputs; verified against
# flakelet-core's source directly). Handing any of this a dummy, unfetchable
# sentinel does not fail closed quietly — it 404s flakelet's real build.
#
# `nix flake lock` is used to discover the graph structure (which nodes
# exist, their `original`/`inputs` follows) for any input flake.nix declares
# that isn't already in the lock. Because it never re-resolves a node that's
# already present, a pre-existing dummy nixpkgs (e.g. from the `nix-scout
# new` scaffold, or the bootstrap pre-seed below) needs an explicit
# `--update-input nixpkgs` to force it to real content — plain `nix flake
# lock` alone would leave it dummy forever. Only the nix-scout node — found
# via root.inputs, not by literal key name, since a colliding transitive
# input can rename it — gets its `locked` block scrubbed back to the dummy
# sentinel afterward.
#
# Usage: update-module.sh <module-dir>
set -euo pipefail

# shellcheck source=./scout-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scout-lib.sh"

MODULE_DIR="${1:?module directory required}"

if [[ ! -f "$MODULE_DIR/flake.nix" ]]; then
  echo "nix-scout update: missing flake.nix in $MODULE_DIR" >&2
  exit 1
fi

if [[ -f "$MODULE_DIR/flake.lock" && ! -w "$MODULE_DIR/flake.lock" ]]; then
  echo "nix-scout update: no write access to $MODULE_DIR/flake.lock" >&2
  exit 1
fi
if [[ ! -w "$MODULE_DIR" ]]; then
  echo "nix-scout update: no write access to $MODULE_DIR" >&2
  exit 1
fi

# Pre-seed a module with no committed flake.lock at all (never scaffolded via
# `nix-scout new`, or the lock was lost) with the standard dummy skeleton
# before running `nix flake lock` below, purely to avoid an unnecessary real
# fetch of nix-scout's own (sizeable) transitive graph just to learn a shape
# that gets scrubbed to dummy content a few lines down anyway. nixpkgs gets
# forced to real content regardless a few steps later.
if [[ ! -f "$MODULE_DIR/flake.lock" ]]; then
  # `import "<string>"` requires an absolute path under --impure; a relative
  # MODULE_DIR would silently fail to eval (nix path literals, not strings,
  # are the ones that resolve relative to cwd).
  abs_module_dir="$(cd "$MODULE_DIR" && pwd)"
  declared_json="$(nix eval --impure --json --expr \
    "builtins.attrNames ((import \"$abs_module_dir/flake.nix\").inputs or {})")"
  if [[ "$declared_json" == *'"nix-scout"'* && "$declared_json" == *'"nixpkgs"'* ]]; then
    echo "nix-scout update: no flake.lock in $MODULE_DIR — bootstrapping dummy sentinel (nix-scout new convention)" >&2
    write_sentinel_lock "$MODULE_DIR/flake.lock"
  fi
fi

# Canonicalize for comparison (sorted keys, compact) so reformatting alone
# (nix's writer vs jq's) never reads as a change.
_canon_hash() {
  [[ -f "$1" ]] || return 0
  jq -S -c . "$1" 2>/dev/null | sha256sum
}

before="$(_canon_hash "$MODULE_DIR/flake.lock")"

(cd "$MODULE_DIR" && nix flake lock)

# Force nixpkgs to real content if it's declared but still the dummy
# sentinel (scaffold-fresh, or bootstrapped above) — see header comment for
# why plain `nix flake lock` above never touches an already-present node.
if jq -e '.nodes.root.inputs | has("nixpkgs")' "$MODULE_DIR/flake.lock" >/dev/null 2>&1; then
  np_owner="$(jq -r '.nodes[.nodes.root.inputs.nixpkgs].locked.owner // ""' "$MODULE_DIR/flake.lock")"
  if [[ "$np_owner" == "nix-scout_not-real-lockfile" ]]; then
    (cd "$MODULE_DIR" && nix flake lock --update-input nixpkgs)
  fi
fi

# Scrub only the node root.inputs["nix-scout"] actually points to back to the
# dummy sentinel — looked up by the root-input mapping, not by literal node
# key, since a colliding transitive input can rename it. Every other node is
# left exactly as resolved: real, fetchable content. `original`/`inputs`
# (follows relationships) are always left untouched; only `locked` (fetched
# content) is ever scrubbed.
tmp="$(mktemp "${MODULE_DIR}/.flake.lock.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
jq \
  --arg nar "sha256-0000000000000000000000000000000000000000000=" \
  --arg sentinel "nix-scout_not-real-lockfile" \
  --arg rev "0000000000000000000000000000000000000000" \
  '
  (.nodes.root.inputs["nix-scout"] // "") as $nsKey |
  .nodes |= with_entries(
    if (.key == $nsKey and $nsKey != "") then
      .value.locked |= (
        .lastModified = 0
        | .narHash = $nar
        | (if has("owner") then .owner = $sentinel else . end)
        | (if has("repo") then .repo = $sentinel else . end)
        | (if has("rev") then .rev = $rev else . end)
      )
    else . end
  )
  ' "$MODULE_DIR/flake.lock" > "$tmp"

after="$(_canon_hash "$tmp")"

# mktemp creates $tmp mode 0600 (owner-only) regardless of the original
# file's mode; `mv` onto the same filesystem keeps the source inode's
# permissions rather than the destination's, so without this the committed
# flake.lock would silently lose its group/other-read bits on every write —
# breaking flakelet's (unprivileged eval_user, read-only) access to it.
chmod --reference="$MODULE_DIR/flake.lock" "$tmp" 2>/dev/null || chmod 644 "$tmp"

# Only touch the committed file (bytes, mtime) when something actually
# changed — a no-op run of `nix-scout switch` shouldn't dirty git status.
if [[ "$before" != "$after" ]]; then
  mv "$tmp" "$MODULE_DIR/flake.lock"
  echo "nix-scout: updated $MODULE_DIR/flake.lock"
else
  echo "nix-scout: $MODULE_DIR/flake.lock already up to date"
fi
