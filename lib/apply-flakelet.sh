#!/usr/bin/env bash
# Apply scout flakelet facet: hot-reload via flakelet update.
set -euo pipefail

NAME="${1:?module name required}"

echo "nix-scout: flakelet update $NAME" >&2
if ! sudo flakelet update "$NAME"; then
  echo "nix-scout: 'sudo flakelet update $NAME' failed." >&2
  echo "nix-scout: If $NAME is not yet registered, run nixos-rebuild first to populate /etc/flakelet.json, then retry." >&2
  exit 1
fi
