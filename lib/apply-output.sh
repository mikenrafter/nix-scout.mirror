#!/usr/bin/env bash
# Orchestrate scout output facets for a given store path.
# Pins a gc-root, then calls apply-hm.sh for home-files/ and apply-env.sh for bin/.
# Both run even if one fails; non-zero exit if any facet failed.
set -euo pipefail

STORE="${1:?scout store path required}"
NAME="${2:-scout}"
GCROOTS="${NIX_SCOUT_GCROOTS:-/nix/var/nix/gcroots/per-user/${USER}/nix-scout}"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_can_write() {
  local check="$1"
  while [[ "$check" != "/" && ! -e "$check" ]]; do
    check="$(dirname "$check")"
  done
  [[ -w "$check" ]]
}

_priv_mkdir() {
  local dir="$1"
  if _can_write "$dir"; then
    mkdir -p "$dir"
  else
    echo "nix-scout: need elevated permissions to create $dir" >&2
    sudo mkdir -p "$dir"
  fi
}

_priv_ln_sfn() {
  local target="$1" link="$2"
  if [[ -w "$(dirname "$link")" ]]; then
    ln -sfn "$target" "$link"
  else
    echo "nix-scout: need elevated permissions to link $link" >&2
    sudo ln -sfn "$target" "$link"
  fi
}

_priv_mkdir "$GCROOTS"
_priv_ln_sfn "$STORE" "$GCROOTS/$NAME"

rc=0
applied=false

if [[ -d "$STORE/home-files" ]]; then
  applied=true
  HOME="${HOME:-}" \
  USER="${USER:?USER is required}" \
  XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-}" \
  bash "$LIB_DIR/apply-hm.sh" "$STORE" "$NAME" \
    || { rc=$?; echo "nix-scout: apply-hm.sh failed for $NAME (exit $rc)" >&2; }
fi

if [[ -d "$STORE/bin" ]]; then
  applied=true
  HOME="${HOME:-}" \
  USER="${USER:?USER is required}" \
  XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-}" \
  NIX_SCOUT_PROFILE="${NIX_SCOUT_PROFILE:-/nix/var/nix/profiles/per-user/${USER}/nix-scout}" \
  bash "$LIB_DIR/apply-env.sh" "$STORE" "$NAME" \
    || { rc=$?; echo "nix-scout: apply-env.sh failed for $NAME (exit $rc)" >&2; }
fi

if [[ "$applied" != "true" ]]; then
  echo "nix-scout: unknown scout output layout at $STORE (expected bin/ or home-files/)" >&2
  exit 1
fi

exit $rc
