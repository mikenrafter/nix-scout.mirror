#!/usr/bin/env bash
# Apply scout home-files facet: copy $STORE/home-files tree into $HOME.
set -euo pipefail

STORE="${1:?scout store path required}"
NAME="${2:-scout}"
HOME="${HOME:?HOME is required}"

# shellcheck source=scout-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scout-lib.sh"

[[ -d "$STORE/home-files" ]] || exit 0

_home_dest() {
  local rel="$1"
  if [[ "$rel" == .config/* ]]; then
    printf '%s/%s' "${XDG_CONFIG_HOME:-$HOME/.config}" "${rel#.config/}"
  else
    printf '%s/%s' "$HOME" "$rel"
  fi
}

src="" rel="" dest=""
while IFS= read -r -d '' src; do
  rel="${src#"$STORE/home-files"/}"
  dest="$(_home_dest "$rel")"
  _priv_mkdir "$(dirname "$dest")"

  if [[ -f "$dest" ]]; then
    if ! cmp -s "$src" "$dest" 2>/dev/null; then
      diff -u \
        --label "previous" \
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
