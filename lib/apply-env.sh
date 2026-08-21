#!/usr/bin/env bash
# Apply scout profile/bin facet: install $STORE into per-user nix-env profile.
set -euo pipefail

STORE="${1:?scout store path required}"
NAME="${2:-scout}"

# shellcheck source=scout-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scout-lib.sh"

[[ -d "$STORE/bin" ]] || exit 0

PROFILE="${NIX_SCOUT_PROFILE:-/nix/var/nix/profiles/per-user/${USER}/nix-scout}"
_priv_mkdir "$(dirname "$PROFILE")"
_priv_nix_env "$PROFILE" "$STORE"
echo "nix-scout: installed profile scout $NAME from $STORE"

XDG_CFG="${XDG_CONFIG_HOME:-${HOME:-~}/.config}"
SCOUT_SHARE="${PROFILE}/share"

_install_conf() {
  local path="$1"
  shift
  mkdir -p "$(dirname "$path")"
  if [[ "$(id -u)" -eq 0 ]]; then
    printf '%s\n' "$@" | install -m644 -o "$USER" /dev/stdin "$path"
  else
    printf '%s\n' "$@" > "$path"
  fi
}

# Fish: conf.d is auto-sourced; prepend vendor_completions.d so profile completions
# win over a stale /run/current-system/sw copy.
FISH_CONF="${XDG_CFG}/fish/conf.d/nix-scout.fish"
_install_conf "$FISH_CONF" \
  '# managed by nix-scout switch — do not edit manually' \
  "fish_add_path -m ${PROFILE}/bin" \
  "set -g fish_complete_path ${SCOUT_SHARE}/fish/vendor_completions.d \$fish_complete_path" \
  'set -q XDG_DATA_DIRS; or set -gx XDG_DATA_DIRS /usr/local/share:/usr/share' \
  "set -gx XDG_DATA_DIRS ${SCOUT_SHARE}:\$XDG_DATA_DIRS" \
  'set -q MANPATH; or set -gx MANPATH ""' \
  "set -gx MANPATH ${SCOUT_SHARE}/man:\$MANPATH"

# Bash: bash-completion v2 scans XDG_DATA_DIRS for bash-completion/completions/.
# Prepend profile share at source time so scout wins without replacing USER_DIR.
BASH_CONF="${XDG_CFG}/bash/nix-scout.bash"
_install_conf "$BASH_CONF" \
  '# managed by nix-scout switch — do not edit manually' \
  "scout_share=${SCOUT_SHARE@Q}" \
  'if [[ -n "${XDG_DATA_DIRS:-}" ]]; then' \
  '  export XDG_DATA_DIRS="${scout_share}:${XDG_DATA_DIRS}"' \
  'else' \
  '  export XDG_DATA_DIRS="${scout_share}:/usr/local/share:/usr/share"' \
  'fi' \
  'if [[ -n "${MANPATH:-}" ]]; then' \
  '  export MANPATH="${scout_share}/man:${MANPATH}"' \
  'else' \
  '  export MANPATH="${scout_share}/man:"' \
  'fi'

# Zsh: nixpkgs zsh puts package completions in share/zsh/site-functions on fpath.
ZSH_CONF="${XDG_CFG}/zsh/nix-scout.zsh"
_install_conf "$ZSH_CONF" \
  '# managed by nix-scout switch — do not edit manually' \
  "fpath=(${SCOUT_SHARE}/zsh/site-functions \$fpath)" \
  'if [[ -n "${XDG_DATA_DIRS:-}" ]]; then' \
  "  export XDG_DATA_DIRS=${SCOUT_SHARE}:\"\$XDG_DATA_DIRS\"" \
  'else' \
  "  export XDG_DATA_DIRS=${SCOUT_SHARE}:/usr/local/share:/usr/share" \
  'fi' \
  'if [[ -n "${MANPATH:-}" ]]; then' \
  "  export MANPATH=${SCOUT_SHARE}/man:\"\$MANPATH\"" \
  'else' \
  "  export MANPATH=${SCOUT_SHARE}/man:" \
  'fi'

echo "nix-scout: wrote shell snippets (fish, bash, zsh) — open a new terminal or re-source your shell"
