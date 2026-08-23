#!/usr/bin/env bash
# Sync a scout module's committed flake.lock with the host's own flake.lock.
#
# A scout module's own committed lock doesn't get independently resolved
# anymore — it's just kept as a mirror of the host's (see
# sync_lock_from_parent in scout-lib.sh, and materialize-module.sh, which
# already does the same copy for tmpdir builds at switch time). This avoids
# any divergence between "what the module's own lock resolves to" and "what
# the host actually has" (nix-scout vs. mainline nix flake drift), and gives
# flakelet's own bare evaluation of a registered module — which reads the
# module's own lock directly, with no override beyond its own injected pkgs
# — real, fetchable content for every node, always. There is no
# dummy/placeholder scheme anymore; a module's lock is either in sync with
# the host's, or `nix-scout update` fixes that by copying again.
#
# Usage: update-module.sh <module-dir>
# Requires NIX_SCOUT_PARENT (a directory with a flake.lock) in the environment.
set -euo pipefail

# shellcheck source=./scout-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scout-lib.sh"

MODULE_DIR="${1:?module directory required}"

if [[ ! -f "$MODULE_DIR/flake.nix" ]]; then
  echo "nix-scout update: missing flake.nix in $MODULE_DIR" >&2
  exit 1
fi

sync_lock_from_parent "$MODULE_DIR"
