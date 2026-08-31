#!/usr/bin/env bash
# Replace Home Manager linkGeneration (ln -Tsf) with DMS-style copies.
# Invoked as an executable with HOME, newGenPath (required), oldGenPath (optional).
set -euo pipefail

: "${HOME:?HOME is required}"
: "${newGenPath:?newGenPath is required}"

# shellcheck source=scout-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scout-lib.sh"

_scout_diff_run_prepare "home-manager" \
  "context: home-manager activation" \
  "newGenPath: $newGenPath" \
  "oldGenPath: ${oldGenPath:-}"

copy_new_gen() {
  local files="$newGenPath/home-files"
  [[ -d "$files" ]] || return 0
  # home-files is a symlink to the real store directory; find(1) does not
  # descend through a symlink given as its root argument, so resolve it
  # first or every call below sees only the symlink itself.
  files="$(readlink -f "$files")"

  local src rel dest
  while IFS= read -r -d '' src; do
    rel="${src#"$files"/}"
    dest="$HOME/$rel"
    mkdir -p "$(dirname "$dest")"

    # systemd unit files (and .wants/.requires dropins) must stay real
    # symlinks: systemd refuses to honor a Wants= dropin that isn't one
    # ("is not a symlink, ignoring"), which silently drops the unit from
    # graphical-session.target. Nothing under here needs in-place edits
    # the way DMS's settings.json does, so plain linkGeneration is fine.
    if [[ "$rel" == .config/systemd/user/* ]]; then
      link_unit "$src" "$dest"
      continue
    fi

    if [[ -e "$dest" || -L "$dest" ]]; then
      if ! cmp -s "$src" "$dest" 2>/dev/null; then
        _scout_emit_diff "$dest" "$src" \
          "previous" \
          "home-manager generation"
      fi
    fi

    # Dest must be a regular file, not a store symlink we would write through.
    if [[ -L "$dest" ]]; then
      rm -f "$dest"
    fi
    # Follow source if the home-files entry is a symlink into the store.
    cp --force "$src" "$dest"
    chmod u+w "$dest"
  done < <(find -L "$files" -type f -print0)
}

link_unit() {
  local src="$1" dest="$2"
  local target
  target="$(readlink -f "$src")"
  if [[ -L "$dest" && "$(readlink "$dest")" == "$target" ]]; then
    return 0
  fi
  rm -f "$dest"
  ln -s "$target" "$dest"
}

cleanup_vanished() {
  local old="${oldGenPath:-}"
  local old_files="$old/home-files"
  local new_files="$newGenPath/home-files"
  [[ -n "$old" && -d "$old_files" ]] || return 0
  old_files="$(readlink -f "$old_files")"

  local src rel dest
  while IFS= read -r -d '' src; do
    rel="${src#"$old_files"/}"
    dest="$HOME/$rel"
    if [[ -e "$new_files/$rel" || -L "$new_files/$rel" ]]; then
      continue
    fi
    # Remove even when $HOME/$P is a regular copy, not a *-home-manager-files/* symlink.
    rm -f "$dest"
  done < <(find -L "$old_files" -type f -print0)
}

copy_new_gen
cleanup_vanished
_scout_diff_run_log_finish
