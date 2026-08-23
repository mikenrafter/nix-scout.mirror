#!/usr/bin/env bash
# Sync a scout module's committed flake.lock structure with its flake.nix-
# declared inputs.
#
# Whether ANY node in the committed lock can safely be a dummy placeholder
# depends entirely on whether the module has a flakelet facet
# (`flakelets.*` in its flake.nix):
#
# * No flakelet facet: nothing ever really touches this module's own
#   committed lock. `nix-scout switch`/rebuild always threads the parent
#   flake's own already-resolved inputs instead (materialize-module.sh
#   stamps the parent's flake.lock over the module's before building; the
#   nixosModule threads inputs directly, bypassing the module's own lock
#   entirely). So EVERY node here — nix-scout, nixpkgs, everything — can
#   stay the dummy sentinel lib/new-module.sh writes.
#
# * Has a flakelet facet: flakelet evaluates the module's flake directly via
#   `builtins.getFlake` against the module's OWN committed lock, with no
#   override for anything but its own injected `pkgs` argument
#   (`input_overrides` is hard-restricted to the key "nixpkgs" — verified
#   directly against flakelet-core's source). Worse: after every successful
#   build, `flakelet update` unconditionally runs `nix flake archive --json`
#   to gc-root "the flake source + inputs" for offline re-evaluation
#   (flakelet-core/src/manager.rs, `flake_roots`) — this eagerly fetches
#   EVERY node in the lock graph regardless of whether anything actually
#   dereferences its content. Confirmed directly: a dummy nix-scout node,
#   despite never being dereferenced by any evaluated expression, still
#   404s `nix flake archive` fetching its fake repo. So NOTHING can be
#   dummy here — not even nix-scout.
#
# `nix flake lock` is used to discover/complete the graph structure (add any
# input node flake.nix declares but flake.lock lacks). Because it never
# re-resolves a node that's already present, a pre-existing dummy node (from
# a `nix-scout new` scaffold, or this script's own no-flakelet-facet branch)
# needs an explicit `--update-input <name>` to force it to real content —
# plain `nix flake lock` alone would leave it dummy forever.
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

# Same facet-detection convention as bin/nix-scout's own _switch_module /
# _facet_tags — a flake.nix text grep, not a Nix eval.
has_flakelet=false
grep -q 'flakelets\.' "$MODULE_DIR/flake.nix" 2>/dev/null && has_flakelet=true

# Canonicalize for comparison (sorted keys, compact) so reformatting alone
# (nix's writer vs jq's) never reads as a change.
_canon_hash() {
  [[ -f "$1" ]] || return 0
  jq -S -c . "$1" 2>/dev/null | sha256sum
}

# Force $1 (a declared top-level input name) to real content if it's
# currently the dummy sentinel (or missing a node entirely — `nix flake
# lock` already added it above, so this only ever needs to *promote*, never
# add). No-ops if the input isn't declared at all.
_force_real() {
  local input="$1"
  jq -e --arg i "$input" '.nodes.root.inputs | has($i)' "$MODULE_DIR/flake.lock" >/dev/null 2>&1 || return 0
  local owner
  owner="$(jq -r --arg i "$input" '.nodes[.nodes.root.inputs[$i]].locked.owner // ""' "$MODULE_DIR/flake.lock")"
  if [[ "$owner" == "nix-scout_not-real-lockfile" ]]; then
    (cd "$MODULE_DIR" && nix flake lock --update-input "$input")
  fi
}

if [[ "$has_flakelet" == "true" ]]; then
  before="$(_canon_hash "$MODULE_DIR/flake.lock")"
  (cd "$MODULE_DIR" && nix flake lock)
  # A module with zero declared inputs (the flakelet-only convention — see
  # scout-modules/*/flake.nix comments: "No flake inputs declared — flakelet
  # path: eval must not require a writable lockfile") gets no flake.lock at
  # all from `nix flake lock` above — nothing to force real, nothing to do.
  if [[ -f "$MODULE_DIR/flake.lock" ]]; then
    _force_real nix-scout
    _force_real nixpkgs
  fi
  # Nothing is scrubbed: every node must stay real for a flakelet-registered
  # module (see header comment).
  after="$(_canon_hash "$MODULE_DIR/flake.lock")"
  if [[ "$before" != "$after" ]]; then
    echo "nix-scout: updated $MODULE_DIR/flake.lock (flakelet facet: all inputs real)"
  elif [[ ! -f "$MODULE_DIR/flake.lock" ]]; then
    echo "nix-scout: $MODULE_DIR has no declared inputs — nothing to lock"
  else
    echo "nix-scout: $MODULE_DIR/flake.lock already up to date"
  fi
  exit 0
fi

# No flakelet facet below this point: nix-scout AND nixpkgs both stay dummy.

# Pre-seed a module with no committed flake.lock at all (never scaffolded via
# `nix-scout new`, or the lock was lost) with the standard dummy skeleton
# before running `nix flake lock`, purely to avoid an unnecessary real fetch
# of nix-scout's own (sizeable) transitive graph just to learn a shape that
# gets scrubbed to dummy content a few lines down anyway.
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

before="$(_canon_hash "$MODULE_DIR/flake.lock")"

(cd "$MODULE_DIR" && nix flake lock)

# Scrub the nix-scout/nixpkgs node(s) back to the dummy sentinel — looked up
# via root.inputs, not literal key name, since a colliding transitive input
# can rename one of them (e.g. "nixpkgs_2"). Every other node is left
# exactly as resolved: real, fetchable content. `original`/`inputs` (follows
# relationships) are always left untouched; only `locked` is ever scrubbed.
tmp="$(mktemp "${MODULE_DIR}/.flake.lock.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
jq \
  --arg nar "sha256-0000000000000000000000000000000000000000000=" \
  --arg sentinel "nix-scout_not-real-lockfile" \
  --arg rev "0000000000000000000000000000000000000000" \
  '
  (.nodes.root.inputs["nix-scout"] // "") as $nsKey |
  (.nodes.root.inputs["nixpkgs"] // "") as $npKey |
  .nodes |= with_entries(
    if (.key == $nsKey and $nsKey != "") or (.key == $npKey and $npKey != "") then
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
