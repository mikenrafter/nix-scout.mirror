#!/usr/bin/env bash
# Apply scout profile/bin facet: install $STORE into per-user nix-env profile.
set -euo pipefail

STORE="${1:?scout store path required}"
NAME="${2:-scout}"

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

_priv_nix_env() {
  local profile="$1" store="$2"
  if _can_write "$profile"; then
    nix-env -p "$profile" -i "$store"
  else
    echo "nix-scout: need elevated permissions for nix-env profile $profile" >&2
    sudo nix-env -p "$profile" -i "$store"
  fi
}

if [[ ! -d "$STORE/bin" ]]; then
  echo "nix-scout: apply-env: no bin/ in $STORE" >&2
  exit 1
fi

PROFILE="${NIX_SCOUT_PROFILE:-/nix/var/nix/profiles/per-user/${USER}/nix-scout}"
_priv_mkdir "$(dirname "$PROFILE")"
_priv_nix_env "$PROFILE" "$STORE"
echo "nix-scout: installed profile scout $NAME from $STORE"

FISH_CONF="${XDG_CONFIG_HOME:-${HOME:-~}/.config}/fish/conf.d/nix-scout.fish"
mkdir -p "$(dirname "$FISH_CONF")"
_fish_content="$(printf '# managed by nix-scout switch — do not edit manually\nfish_add_path -m %s/bin\n' "$PROFILE")"
if [[ "$(id -u)" -eq 0 ]]; then
  printf '%s\n' "$_fish_content" | install -m644 -o "$USER" /dev/stdin "$FISH_CONF"
else
  printf '%s\n' "$_fish_content" > "$FISH_CONF"
fi
echo "nix-scout: wrote $FISH_CONF — open a new terminal or run: fish_add_path -m $PROFILE/bin"
