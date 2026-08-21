#!/usr/bin/env bash
# Replace Home Manager linkGeneration (ln -Tsf) with DMS-style copies.
# Invoked as an executable with HOME, newGenPath (required), oldGenPath (optional).
set -euo pipefail

: "${HOME:?HOME is required}"
: "${newGenPath:?newGenPath is required}"

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

    if [[ -e "$dest" || -L "$dest" ]]; then
      if ! cmp -s "$src" "$dest" 2>/dev/null; then
        diff -u "$dest" "$src" || true
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
