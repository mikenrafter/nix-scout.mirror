#!/usr/bin/env bash
# Sync a scout module's committed flake.lock structure with its flake.nix-
# declared inputs, while keeping every node's content fully dummy.
#
# A scout module's own committed flake.lock is never actually used to resolve
# anything for real: nix-scout switch/rebuild always threads the parent
# flake's own already-resolved inputs (materialize-module.sh stamps the
# parent's flake.lock over the module's before building), and flakelet's own
# path: evaluation of a module only ever draws on the host's own nixpkgs. So
# nothing in a module's own flake.lock is ever actually fetched by its
# recorded rev/narHash — the file exists purely so `nix flake`-family tooling
# (and flakelet's own lock bookkeeping) sees a structurally complete graph and
# doesn't attempt to add a node itself (which is what caused the original
# bug: flakelet's eval_user has no write access to the module tree — see
# lib/flakelet-access.sh — so an add-on-the-fly attempt fails outright).
#
# `nix flake lock` is used internally only to *discover* that structure (which
# nodes exist, their `original`/`inputs` follows) for any input flake.nix
# declares that isn't already in the lock — real network resolution happens
# here to learn the graph shape, then every node's `locked` block is
# overwritten with the same dummy sentinel lib/new-module.sh already uses for
# nix-scout/nixpkgs, so nothing in the committed file ever looks like a real
# pin that needs maintaining.
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
# that gets scrubbed to dummy content a few lines down anyway.
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

# Scrub every node's `locked` block (the only part that ever records real
# fetched content) to the same dummy sentinel lib/new-module.sh writes.
# `original` and `inputs` (follows relationships) are real structural
# metadata — never fetched, always worth keeping accurate — and are left
# untouched.
tmp="$(mktemp "${MODULE_DIR}/.flake.lock.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
jq \
  --arg nar "sha256-0000000000000000000000000000000000000000000=" \
  --arg sentinel "nix-scout_not-real-lockfile" \
  --arg rev "0000000000000000000000000000000000000000" \
  '
  .nodes |= with_entries(
    if .key == "root" then .
    else
      .value.locked |= (
        .lastModified = 0
        | .narHash = $nar
        | (if has("owner") then .owner = $sentinel else . end)
        | (if has("repo") then .repo = $sentinel else . end)
        | (if has("rev") then .rev = $rev else . end)
      )
    end
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
