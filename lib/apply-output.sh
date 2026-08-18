#!/usr/bin/env bash
# Apply a built scout store path (home-files tree or profile package).
set -euo pipefail

STORE="${1:?scout store path required}"
NAME="${2:-scout}"
GCROOTS="${NIX_SCOUT_GCROOTS:-/nix/var/nix/gcroots/per-user/${USER}/nix-scout}"
HOME="${HOME:?HOME is required}"

_home_dest() {
  local rel="$1"
  if [[ "$rel" == .config/* ]]; then
    printf '%s/%s' "${XDG_CONFIG_HOME:-$HOME/.config}" "${rel#.config/}"
  else
    printf '%s/%s' "$HOME" "$rel"
  fi
}

# Returns true if the current user can write to path (walks up to first existing ancestor).
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

_priv_nix_env() {
  local profile="$1" store="$2"
  if _can_write "$profile"; then
    nix-env -p "$profile" -i "$store"
  else
    echo "nix-scout: need elevated permissions for nix-env profile $profile" >&2
    sudo nix-env -p "$profile" -i "$store"
  fi
}

_priv_mkdir "$GCROOTS"
_priv_ln_sfn "$STORE" "$GCROOTS/$NAME"

if [[ -d "$STORE/home-files" ]]; then
  src="" rel="" dest=""
  while IFS= read -r -d '' src; do
    rel="${src#"$STORE/home-files"/}"
    dest="$(_home_dest "$rel")"
    mkdir -p "$(dirname "$dest")"

    if [[ -f "$dest" ]]; then
      if ! cmp -s "$src" "$dest" 2>/dev/null; then
        diff -u \
          --label "previous settings.json" \
          --label "Nix baseline (scout module)" \
          "$dest" "$src" || true
      fi
    fi

    if [[ -L "$dest" ]]; then
      rm -f "$dest"
    fi
    cp --force "$src" "$dest"
    chmod u+w "$dest"
  done < <(find "$STORE/home-files" \( -type f -o -type l \) -print0)
  echo "nix-scout: applied home-files scout $NAME from $STORE"
  exit 0
fi

if [[ -d "$STORE/bin" ]]; then
  PROFILE="${NIX_SCOUT_PROFILE:-/nix/var/nix/profiles/per-user/${USER}/nix-scout}"
  _priv_mkdir "$(dirname "$PROFILE")"
  _priv_nix_env "$PROFILE" "$STORE"
  echo "nix-scout: installed profile scout $NAME from $STORE"

  # Write a Fish conf.d snippet so the profile bin is on PATH in new sessions
  # without requiring a nixos-rebuild. After a rebuild the NixOS module takes over.
  FISH_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/nix-scout.fish"
  mkdir -p "$(dirname "$FISH_CONF")"
  printf '# managed by nix-scout switch — do not edit manually\nfish_add_path -m %s/bin\n' "$PROFILE" \
    > "$FISH_CONF"
  echo "nix-scout: wrote $FISH_CONF — open a new terminal or run: fish_add_path -m $PROFILE/bin"
  exit 0
fi

echo "nix-scout: unknown scout output layout at $STORE" >&2
exit 1
