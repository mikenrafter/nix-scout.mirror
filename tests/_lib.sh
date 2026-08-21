#!/usr/bin/env bash
# Shared helpers for nix-scout contract suites. Source from suite scripts.
# Not a suite itself — do not execute directly.

# shellcheck disable=SC2034

NIX="${NIX:-nix}"
# tests/ -> repo root
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# NIX_SCOUT_ROOT defaults to REPO since we're testing nix-scout itself.
NIX_SCOUT_ROOT="${NIX_SCOUT_ROOT:-$REPO}"

SYS_BIN="${NIX_SCOUT_TEST_SYS_BIN:-/run/current-system/sw/bin}"
_sys() {
  local n="$1"
  if [[ -x "${SYS_BIN}/${n}" ]]; then
    printf '%s' "${SYS_BIN}/${n}"
    return 0
  fi
  if command -v "$n" >/dev/null 2>&1; then
    command -v "$n"
    return 0
  fi
  printf '%s' "$n"
}

FIND="$(_sys find)"
SORT="$(_sys sort)"
GREP="$(_sys grep)"
MKTEMP="$(_sys mktemp)"
RM="$(_sys rm)"
CAT="$(_sys cat)"
HEAD="$(_sys head)"
MKDIR="$(_sys mkdir)"
CP="$(_sys cp)"
CHMOD="$(_sys chmod)"
STAT="$(_sys stat)"
DIFF="$(_sys diff)"
TOUCH="$(_sys touch)"
LS="$(_sys ls)"
SHA256SUM="$(_sys sha256sum)"
TEST_BIN="$(_sys test)"
BASENAME="$(_sys basename)"
DIRNAME="$(_sys dirname)"
READLINK="$(_sys readlink)"
JQ="$(_sys jq)"

# Harness PATH lookups must not auto-log (agent sessions wrap grep/head via tea).
export TEA_OFF=1

failures=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

require_nix() {
  if ! command -v "$NIX" >/dev/null 2>&1; then
    echo "FAIL: '$NIX' not found on PATH (set NIX=... to override) — harness" >&2
    exit 2
  fi
}

# Capture stdout without bash stripping trailing newlines (cmdsubst pitfall).
# Sets CAPTURED_OUT, CAPTURED_ERR, CAPTURED_RC.
run_capture() {
  local out_tmp err_tmp
  out_tmp="$("$MKTEMP" "${WORKDIR:-${TMPDIR:-/tmp}}/out.XXXXXX")"
  err_tmp="$("$MKTEMP" "${WORKDIR:-${TMPDIR:-/tmp}}/err.XXXXXX")"
  set +e
  "$@" >"$out_tmp" 2>"$err_tmp"
  CAPTURED_RC=$?
  set -e
  CAPTURED_OUT="$("$CAT" "$out_tmp"; printf x)"
  CAPTURED_OUT="${CAPTURED_OUT%x}"
  CAPTURED_ERR="$("$CAT" "$err_tmp"; printf x)"
  CAPTURED_ERR="${CAPTURED_ERR%x}"
  "$RM" -f "$out_tmp" "$err_tmp"
}

# Prefer source binary in this repo; fall back to system binary or build.
# Sets NIX_SCOUT_ROOT to REPO (already defaulted above).
resolve_nix_scout() {
  local resolved=""

  if [[ -n "${NIX_SCOUT:-}" && -e "${NIX_SCOUT}" ]]; then
    resolved="$NIX_SCOUT"
  elif [[ -x "$REPO/bin/nix-scout" ]]; then
    resolved="$REPO/bin/nix-scout"
  elif [[ -x "/run/current-system/sw/bin/nix-scout" ]]; then
    resolved="/run/current-system/sw/bin/nix-scout"
  else
    if ! command -v "$NIX" >/dev/null 2>&1; then
      echo "FAIL: '$NIX' not found on PATH (cannot build packages.x86_64-linux.nix-scout)" >&2
      exit 2
    fi
    local out
    set +e
    out="$("$NIX" build --no-link --print-out-paths --no-write-lock-file \
      "${REPO}#packages.x86_64-linux.nix-scout" 2>/dev/null)"
    local st=$?
    set -e
    out="${out%%$'\n'*}"
    if [[ "$st" -eq 0 && -n "$out" && -x "$out/bin/nix-scout" ]]; then
      resolved="$out/bin/nix-scout"
    else
      return 1
    fi
  fi

  NIX_SCOUT_ROOT="$(cd "$("$DIRNAME" "$resolved")/.." && pwd)"
  export NIX_SCOUT_ROOT
  printf '%s' "$resolved"
  return 0
}

resolve_materialize_script() {
  local cand="${NIX_SCOUT_ROOT:-$REPO}/lib/materialize-module.sh"
  if [[ -x "$cand" || -f "$cand" ]]; then
    printf '%s' "$cand"
    return 0
  fi
  return 1
}

resolve_apply_output_script() {
  local cand="${NIX_SCOUT_ROOT:-$REPO}/lib/apply-output.sh"
  if [[ -x "$cand" || -f "$cand" ]]; then
    printf '%s' "$cand"
    return 0
  fi
  return 1
}

resolve_hm_activate() {
  if [[ -n "${NIX_SCOUT_HM_ACTIVATE:-}" && -e "${NIX_SCOUT_HM_ACTIVATE}" ]]; then
    printf '%s' "$NIX_SCOUT_HM_ACTIVATE"
    return 0
  fi
  local cand="${NIX_SCOUT_ROOT:-$REPO}/lib/hm-activate-files.sh"
  if [[ -e "$cand" ]]; then
    printf '%s' "$cand"
    return 0
  fi
  return 1
}

# Collect candidate NixOS module files from this repo.
scout_module_candidates() {
  for f in \
    "${NIX_SCOUT_ROOT:-$REPO}/nixos-module.nix" \
    "$REPO/nixos-module.nix"; do
    if [[ -f "$f" ]]; then
      printf '%s\n' "$f"
    fi
  done
}

# Source binary — use repo source directly (no system lag).
resolve_strict_nix_scout() {
  local src="$REPO/bin/nix-scout"
  if [[ -f "$src" ]]; then
    printf '%s' "$src"
    return 0
  fi
  resolve_nix_scout
}

# Isolated HOME + scout profile/gc-roots. Never uses the real user nix-env profile.
scout_write_paths_file() {
  local file="${1:-${NIX_SCOUT_PATHS_FILE:-${WORKDIR:-${TMPDIR:-/tmp}}/nix-scout-paths}}}"
  "$MKDIR" -p "$(dirname "$file")"
  cat >"$file" <<EOF
NIX_SCOUT_PARENT=${NIX_SCOUT_PARENT:-$REPO}
NIX_SCOUT_MODULES=${NIX_SCOUT_MODULES:-$REPO/tests/fixtures}
EOF
  export NIX_SCOUT_PATHS_FILE="$file"
}

scout_isolate() {
  WORKDIR="$("$MKTEMP" -d "${TMPDIR:-/tmp}/nix-scout-test.XXXXXX")"
  export HOME="$WORKDIR/home"
  export XDG_CONFIG_HOME="$WORKDIR/xdg-config"
  export XDG_CACHE_HOME="$WORKDIR/xdg-cache"
  export XDG_DATA_HOME="$WORKDIR/xdg-data"
  export XDG_STATE_HOME="$WORKDIR/xdg-state"
  export NIX_SCOUT_PROFILE="$WORKDIR/scout-profile"
  export NIX_SCOUT_GCROOTS="$WORKDIR/scout-gcroots"
  scout_write_paths_file "$WORKDIR/nix-scout-paths"
  "$MKDIR" -p \
    "$HOME/.nix-profile/bin" \
    "$XDG_CONFIG_HOME" \
    "$XDG_CACHE_HOME" \
    "$XDG_DATA_HOME" \
    "$XDG_STATE_HOME" \
    "$NIX_SCOUT_GCROOTS"
  printf 'default-profile-sentinel\n' >"$HOME/.nix-profile/bin/.default-profile-sentinel"
  FAKE_DEFAULT_PROFILE="$HOME/.nix-profile"
  FAKE_DEFAULT_SENTINEL="$FAKE_DEFAULT_PROFILE/bin/.default-profile-sentinel"
  REAL_USER_PROFILE="${NIX_USER_PROFILE_DIR:-/nix/var/nix/profiles/per-user/${USER}}/profile"
  REAL_PROFILE_SNAPSHOT=""
  if [[ -e "$REAL_USER_PROFILE" ]]; then
    REAL_PROFILE_SNAPSHOT="$("$LS" -la "$REAL_USER_PROFILE" 2>/dev/null || true)"
  fi
}

assert_default_profile_untouched() {
  local label="${1:-default user profile untouched}"
  if [[ ! -f "$FAKE_DEFAULT_SENTINEL" ]]; then
    fail "$label: fake ~/.nix-profile sentinel missing (scout mutated default profile under \$HOME)"
    return
  fi
  local got
  got="$("$CAT" "$FAKE_DEFAULT_SENTINEL")"
  if [[ "$got" != $'default-profile-sentinel\n' && "$got" != "default-profile-sentinel" ]]; then
    fail "$label: fake ~/.nix-profile sentinel changed"
    return
  fi
  local extra
  extra="$("$FIND" "$FAKE_DEFAULT_PROFILE/bin" -mindepth 1 ! -name '.default-profile-sentinel' | "$HEAD" -n 1 || true)"
  if [[ -n "$extra" ]]; then
    fail "$label: extra path in fake ~/.nix-profile: $extra"
    return
  fi
  if [[ -n "$REAL_PROFILE_SNAPSHOT" && -e "$REAL_USER_PROFILE" ]]; then
    local now
    now="$("$LS" -la "$REAL_USER_PROFILE" 2>/dev/null || true)"
    if [[ "$now" != "$REAL_PROFILE_SNAPSHOT" ]]; then
      fail "$label: real user nix-env profile changed at $REAL_USER_PROFILE"
      return
    fi
  fi
  pass "$label"
}

assert_regular_writable_file() {
  local path="$1" label="$2"
  if [[ ! -e "$path" ]]; then
    fail "$label: missing $path"
    return
  fi
  if [[ -L "$path" ]]; then
    fail "$label: $path is a symlink ($("$READLINK" -f "$path" 2>/dev/null || "$READLINK" "$path")) — want regular writable file, not store link"
    return
  fi
  if [[ ! -f "$path" ]]; then
    fail "$label: $path is not a regular file"
    return
  fi
  if [[ ! -w "$path" ]]; then
    fail "$label: $path is not writable"
    return
  fi
  pass "$label (regular writable file)"
}

finish_suite() {
  echo
  if [[ "$failures" -eq 0 ]]; then
    echo "All checks passed."
    exit 0
  fi
  echo "$failures check(s) failed." >&2
  exit 1
}
