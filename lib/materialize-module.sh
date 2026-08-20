#!/usr/bin/env bash
# Copy a scout module flake to /tmp and stamp it with the parent flake.lock.
# Modules carry no committed flake.lock; the parent lock is the authoritative pin.
# Prints the materialized directory path on stdout.
set -euo pipefail

MODULE_DIR="${1:?module directory required}"
NIX_SCOUT_PARENT="${NIX_SCOUT_PARENT:-}"

if [[ ! -f "$MODULE_DIR/flake.nix" ]]; then
  echo "materialize-module: missing flake.nix in $MODULE_DIR" >&2
  exit 1
fi

tmp="$(mktemp -d /tmp/nix-scout-XXXXXX)"
cp -a "$MODULE_DIR/." "$tmp/"
chmod -R u+w "$tmp"

parent_lock="${NIX_SCOUT_PARENT}/flake.lock"
if [[ -f "$parent_lock" ]]; then
  cp "$parent_lock" "$tmp/flake.lock"
  echo "nix-scout: materialize copied parent flake.lock into $tmp" >&2
elif [[ ! -f "$tmp/flake.lock" ]]; then
  (cd "$tmp" && (nix flake lock --no-write-lock-file 2>/dev/null || nix flake lock) >/dev/null)
fi

cat > "$tmp/scout-context.nix" <<'EOF'
{ systemRebuild = false; }
EOF

export NIX_SCOUT_MATERIALIZED="$tmp"
printf '%s\n' "$tmp"
