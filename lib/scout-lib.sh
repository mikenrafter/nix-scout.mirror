#!/usr/bin/env bash
# Shared primitives for nix-scout lib scripts.

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

pin_gcroot() {
  local store="$1" name="$2"
  local gcroots="${NIX_SCOUT_GCROOTS:-/nix/var/nix/gcroots/per-user/${USER}/nix-scout}"
  _priv_mkdir "$gcroots"
  _priv_ln_sfn "$store" "$gcroots/$name"
}

# Sync a scout module's committed flake.lock from the parent (host) flake's
# own already-resolved lock — nixpkgs, nix-scout, and anything else
# (llm-agents, etc.) the host itself declares at top level. This is the same
# starting point materialize-module.sh already uses for tmpdir builds at
# switch time; `nix-scout new` (initial scaffold) and `nix-scout update`
# (ongoing sync) do it for the *committed* module directory too.
#
# The host's lock is a strict superset of what any given module actually
# declares, so it can't just be copied verbatim: `nix flake metadata` (and
# `archive`, `build`, ...) evaluate a flake for real and PRUNE any node the
# flake.nix doesn't actually reference, rewriting the lock file in place —
# confirmed directly, and true with or without `--refresh`. flakelet's own
# calls never pass `--no-write-lock-file`, so an unpruned copy would make
# its supposedly read-only evaluation of a registered module itself try (and
# fail — flakelet's eval_user has no write access to the module tree, see
# flakelet-access.sh) to write a trimmed copy — the exact same class of
# failure as a missing node, just from the opposite direction. So this
# copies the host's lock into a scratch copy of the module first, lets
# `nix flake metadata` prune it there (as this process's own user, who does
# have write access), and only then compares/writes the *pruned* result into
# the committed file — already in the minimal, stable form flakelet's
# read-only eval expects.
#
# Requires NIX_SCOUT_PARENT to be set and point at a directory with a
# flake.lock. Only writes when the pruned content actually differs from
# what's currently committed (a no-op run of `nix-scout switch` shouldn't
# dirty git status); preserves the target's existing file mode across the
# write. Prints "created"/"updated"/"already up to date" as appropriate.
# Returns 1 with a clear message if the parent lock can't be found, pruning
# fails, or the target isn't writable.
sync_lock_from_parent() {
  local module_dir="$1"
  local parent="${NIX_SCOUT_PARENT:-}"

  if [[ -z "$parent" ]]; then
    echo "nix-scout: NIX_SCOUT_PARENT not set — cannot sync $module_dir/flake.lock from the host" >&2
    return 1
  fi
  local parent_lock="$parent/flake.lock"
  if [[ ! -f "$parent_lock" ]]; then
    echo "nix-scout: host flake.lock missing at $parent_lock — cannot sync $module_dir/flake.lock" >&2
    return 1
  fi
  if [[ -f "$module_dir/flake.lock" && ! -w "$module_dir/flake.lock" ]]; then
    echo "nix-scout: no write access to $module_dir/flake.lock" >&2
    return 1
  fi
  if [[ ! -w "$module_dir" ]]; then
    echo "nix-scout: no write access to $module_dir" >&2
    return 1
  fi

  local before=""
  # Hash content only (`sha256sum < file`, not `sha256sum file`) so it's
  # comparable against the scratch copy's hash below despite the differing
  # paths.
  [[ -f "$module_dir/flake.lock" ]] && before="$(sha256sum < "$module_dir/flake.lock")"

  local scratch
  scratch="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$scratch'" RETURN
  cp "$module_dir/flake.nix" "$scratch/flake.nix"
  cp "$parent_lock" "$scratch/flake.lock"
  if ! nix flake metadata --json "$scratch" >/dev/null 2>&1; then
    echo "nix-scout: failed to resolve $module_dir against the host's flake.lock — run \`nix flake metadata $scratch\` to see why" >&2
    return 1
  fi

  local after
  after="$(sha256sum < "$scratch/flake.lock")"

  if [[ "$before" == "$after" ]]; then
    echo "nix-scout: $module_dir/flake.lock already up to date"
    return 0
  fi

  # mktemp'ing $scratch already gave it mode 0700 -> the copied flake.lock
  # inside it is 0600; `cp`/`mv` into place keeps the source's permissions,
  # not the destination's, so without an explicit chmod the committed
  # flake.lock would silently lose its group/other-read bits on every sync —
  # breaking flakelet's (unprivileged eval_user, read-only) access to it.
  if [[ -f "$module_dir/flake.lock" ]]; then
    chmod --reference="$module_dir/flake.lock" "$scratch/flake.lock" 2>/dev/null || chmod 644 "$scratch/flake.lock"
    cp "$scratch/flake.lock" "$module_dir/flake.lock"
    echo "nix-scout: updated $module_dir/flake.lock from host flake.lock"
  else
    chmod 644 "$scratch/flake.lock"
    cp "$scratch/flake.lock" "$module_dir/flake.lock"
    echo "nix-scout: created $module_dir/flake.lock from host flake.lock"
  fi
}
