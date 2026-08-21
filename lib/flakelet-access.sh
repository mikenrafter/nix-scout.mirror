#!/usr/bin/env bash
# Grant / check filesystem access for flakelet path: evaluation.
#
# Flakelet drops privileges with setuid/setgid only (no initgroups), so the
# eval user's supplementary groups (e.g. `users`) are NOT effective during
# `nix flake metadata`. Access must work for: uid=eval_user, primary gid only.
#
# Strategy: ensure other-execute on every ancestor directory, and other-rx on
# the modules directory (and named module leaves). That matches primary-gid-only
# credentials without chowning the user's tree onto the flakelet group.
#
# Usage (CLI):
#   flakelet-access.sh grant <modulesDir> [moduleName...]
#   flakelet-access.sh check <modulesDir> <evalUser> [moduleName...]
#
# Or source and call flakelet_access_grant_tree / flakelet_access_check_tree.

_flakelet_chmod() {
  # Prefer an unprivileged chmod when the caller owns the path; fall back to
  # sudo only when that fails (activation runs as root; doctor may elevate).
  if chmod "$@" 2>/dev/null; then
    return 0
  fi
  if [[ "$(id -u)" -eq 0 ]]; then
    return 1
  fi
  sudo chmod "$@"
}

# True if octal permission digit has all bits in mask.
_flakelet_has_bits() {
  local digit="$1" mask="$2"
  (( (digit & mask) == mask ))
}

# Can eval_user reach `path` with only its primary group (no supplementary)?
# need_read=1 also requires read on this component (modules / module leaves).
_flakelet_component_ok() {
  local path="$1" eval_user="$2" need_read="${3:-0}"
  local owner group mode u g o mask primary_gid primary_group acl

  [[ -e "$path" ]] || return 1

  owner="$(stat -c '%U' "$path" 2>/dev/null || true)"
  group="$(stat -c '%G' "$path" 2>/dev/null || true)"
  mode="$(stat -c '%a' "$path" 2>/dev/null || true)"
  [[ -n "$mode" ]] || return 1

  u="${mode: -3:1}"
  g="${mode: -2:1}"
  o="${mode: -1:1}"
  mask=1
  [[ "$need_read" == "1" ]] && mask=5

  if [[ "$owner" == "$eval_user" ]] && _flakelet_has_bits "$u" "$mask"; then
    return 0
  fi

  primary_gid="$(getent passwd "$eval_user" 2>/dev/null | cut -d: -f4 || true)"
  if [[ -n "$primary_gid" ]]; then
    primary_group="$(getent group "$primary_gid" 2>/dev/null | cut -d: -f1 || true)"
    if [[ -n "$primary_group" && "$group" == "$primary_group" ]] \
      && _flakelet_has_bits "$g" "$mask"; then
      return 0
    fi
  fi

  if _flakelet_has_bits "$o" "$mask"; then
    return 0
  fi

  # ACL fallback (user:eval_user entry), if getfacl is available.
  if command -v getfacl >/dev/null 2>&1; then
    acl="$(getfacl -cp "$path" 2>/dev/null || true)"
    if [[ "$need_read" == "1" ]]; then
      printf '%s\n' "$acl" | grep -qE "^user:${eval_user}:r.x$" && return 0
    else
      printf '%s\n' "$acl" | grep -qE "^user:${eval_user}:..x$" && return 0
    fi
  fi

  return 1
}

# chmod o+x on every directory from target up to (but not including) /.
flakelet_access_grant_ancestors() {
  local target="$1"
  local p mode other

  [[ -n "$target" ]] || return 0
  p="$target"
  while [[ -n "$p" && "$p" != "/" ]]; do
    if [[ -d "$p" ]]; then
      mode="$(stat -c '%a' "$p" 2>/dev/null || true)"
      other="${mode: -1}"
      # Already world-executable — leave system dirs (e.g. /tmp) alone.
      if [[ -z "$mode" ]] || ! (( other & 1 )); then
        _flakelet_chmod o+x "$p" || true
      fi
    fi
    p="${p%/*}"
  done
}

# Grant primary-gid-safe access to modulesDir and optional module leaves.
flakelet_access_grant_tree() {
  local modules_dir="$1"
  shift || true
  local name leaf

  [[ -n "$modules_dir" ]] || {
    echo "flakelet-access: modules directory required" >&2
    return 1
  }

  flakelet_access_grant_ancestors "$modules_dir"
  if [[ -d "$modules_dir" ]]; then
    _flakelet_chmod o+rx "$modules_dir" || true
  fi

  for name in "$@"; do
    [[ -n "$name" ]] || continue
    leaf="${modules_dir}/${name}"
    flakelet_access_grant_ancestors "$leaf"
    if [[ -d "$leaf" ]]; then
      _flakelet_chmod o+rx "$leaf" || true
    fi
  done
}

# Emit failing path components for one target (modules dir or module leaf).
# Sets global _flakelet_check_failed=1 on failure.
_flakelet_check_target() {
  local target="$1" eval_user="$2" modules_dir="$3"
  local p need_read

  p="$target"
  while [[ -n "$p" && "$p" != "/" ]]; do
    if [[ -d "$p" ]]; then
      need_read=0
      if [[ "$p" == "$target" || "$p" == "$modules_dir" ]]; then
        need_read=1
      fi
      if ! _flakelet_component_ok "$p" "$eval_user" "$need_read"; then
        printf '%s\n' "$p"
        _flakelet_check_failed=1
        return 0
      fi
    fi
    p="${p%/*}"
  done
}

# Check modulesDir (+ optional leaves). Prints failing paths to stdout.
# Returns 0 if all ok, 1 if any component fails.
flakelet_access_check_tree() {
  local modules_dir="$1"
  local eval_user="$2"
  shift 2 || true
  local name leaf
  _flakelet_check_failed=0

  [[ -n "$modules_dir" && -n "$eval_user" ]] || {
    echo "flakelet-access: modules directory and eval user required" >&2
    return 1
  }

  if [[ ! -d "$modules_dir" ]]; then
    printf '%s\n' "$modules_dir"
    return 1
  fi

  _flakelet_check_target "$modules_dir" "$eval_user" "$modules_dir"

  for name in "$@"; do
    [[ -n "$name" ]] || continue
    leaf="${modules_dir}/${name}"
    [[ -d "$leaf" ]] || continue
    _flakelet_check_target "$leaf" "$eval_user" "$modules_dir"
  done

  return "$_flakelet_check_failed"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    grant)
      flakelet_access_grant_tree "$@"
      ;;
    check)
      flakelet_access_check_tree "$@"
      ;;
    *)
      echo "usage: $0 grant <modulesDir> [module...]" >&2
      echo "       $0 check <modulesDir> <evalUser> [module...]" >&2
      exit 2
      ;;
  esac
fi
