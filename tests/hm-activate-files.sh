#!/usr/bin/env bash
# nix-scout Home Manager file-activation replacement:
# copy each managed home.file as a regular file (cp --force), not ln -Tsf.
# Print unified diff when replacing a different existing file. mkdir -p parents.
# Clean up vanished generation files even when they are regular copies (not
# only store symlinks matching *-home-manager-files/*).
#
# Lookup: $NIX_SCOUT_HM_ACTIVATE, then lib/hm-activate-files.sh in this repo.
#
# Interface: export HOME, newGenPath, optional oldGenPath (HM activation vars).
#
# Run from nix-scout root:
#   tests/hm-activate-files.sh
set -euo pipefail

# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

echo "== HM activate-files (copy, not symlink) =="

scout_isolate
cleanup() { "$RM" -rf "$WORKDIR"; }
trap cleanup EXIT

# Resolve nix-scout first so NIX_SCOUT_ROOT is set.
_bin=""
_bin="$(resolve_nix_scout)" || true

if [[ -n "${NIX_SCOUT_ROOT:-}" ]] && [[ -x "$NIX_SCOUT_ROOT/lib/hm-activate-files.sh" || -f "$NIX_SCOUT_ROOT/lib/hm-activate-files.sh" ]]; then
  pass "HM activator at $NIX_SCOUT_ROOT/lib/hm-activate-files.sh"
else
  fail "missing hm-activate-files.sh in NIX_SCOUT_ROOT/lib/ (activator lives in standalone nix-scout package)"
fi

ACT=""
if ! ACT="$(resolve_hm_activate)"; then
  fail "HM activator missing (tried \$NIX_SCOUT_HM_ACTIVATE, \$NIX_SCOUT_ROOT/lib/hm-activate-files.sh)"
  fail "copy-not-symlink home.file contract not testable (activator missing)"
  fail "unified diff on replace not testable (activator missing)"
  fail "vanished-file cleanup of regular copies not testable (activator missing)"
  finish_suite
fi

pass "resolved HM activator at $ACT"
if [[ ! -x "$ACT" ]]; then
  "$CHMOD" +x "$ACT" 2>/dev/null || true
fi

seed_gen() {
  local dest="$1"
  "$RM" -rf "$dest"
  "$MKDIR" -p \
    "$dest/home-files/.config/DankMaterialShell" \
    "$dest/home-files/.config/nix-scout-keep" \
    "$dest/home-files/.config/deep/nested"
  printf '%s\n' "$2" >"$dest/home-files/.config/DankMaterialShell/settings.json"
  printf 'keep-v1\n' >"$dest/home-files/.config/nix-scout-keep/note.txt"
  printf 'nested-ok\n' >"$dest/home-files/.config/deep/nested/file.txt"
}

GEN_A="$WORKDIR/new-gen-a"
GEN_B="$WORKDIR/new-gen-b"
seed_gen "$GEN_A" '{"theme":"alpha"}'
# Gen B changes settings, drops the keep file (vanished), keeps nested.
"$MKDIR" -p \
  "$GEN_B/home-files/.config/DankMaterialShell" \
  "$GEN_B/home-files/.config/deep/nested"
printf '%s\n' '{"theme":"beta"}' >"$GEN_B/home-files/.config/DankMaterialShell/settings.json"
printf 'nested-ok\n' >"$GEN_B/home-files/.config/deep/nested/file.txt"

run_activator() {
  local new="$1" old="${2:-}"
  run_capture env \
    HOME="$HOME" \
    newGenPath="$new" \
    oldGenPath="$old" \
    "$ACT"
}

echo "-- first run copies tree as regular files --"
run_activator "$GEN_A" ""
if [[ "$CAPTURED_RC" -eq 0 ]]; then
  pass "activator exit 0 on first generation"
else
  fail "activator failed on first generation (rc=$CAPTURED_RC err=$(printf %q "$CAPTURED_ERR"))"
fi

SETTINGS="$HOME/.config/DankMaterialShell/settings.json"
KEEP="$HOME/.config/nix-scout-keep/note.txt"
NESTED="$HOME/.config/deep/nested/file.txt"

assert_regular_writable_file "$SETTINGS" "managed settings.json"
assert_regular_writable_file "$KEEP" "managed keep note"
assert_regular_writable_file "$NESTED" "nested parent dirs created"

if [[ -L "$SETTINGS" ]]; then
  fail "activator used ln -Tsf (settings.json is a symlink); want cp --force regular file"
else
  pass "settings.json is not a symlink (not vanilla linkGeneration)"
fi

got="$("$CAT" "$SETTINGS")"
if [[ "$got" == '{"theme":"alpha"}' || "$got" == $'{"theme":"alpha"}\n' ]]; then
  pass "copied content matches generation A"
else
  fail "settings.json content mismatch: $(printf %q "$got")"
fi

echo "-- second run with changed content prints diff and overwrites --"
run_activator "$GEN_B" "$GEN_A"
if [[ "$CAPTURED_RC" -eq 0 ]]; then
  pass "activator exit 0 on second generation"
else
  fail "activator failed on second generation (rc=$CAPTURED_RC err=$(printf %q "$CAPTURED_ERR"))"
fi

DIFF_TEXT="$CAPTURED_OUT$CAPTURED_ERR"
if [[ "$DIFF_TEXT" == *'@@'* || "$DIFF_TEXT" == *$'\n--- '* || "$DIFF_TEXT" == *'theme'* ]]; then
  pass "replacing a different existing file printed a unified diff"
else
  fail "expected unified diff on content change; got $(printf %q "$DIFF_TEXT")"
fi

got="$("$CAT" "$SETTINGS")"
if [[ "$got" == '{"theme":"beta"}' || "$got" == $'{"theme":"beta"}\n' ]]; then
  pass "overwrote settings.json with generation B (cp --force)"
else
  fail "settings.json not overwritten: $(printf %q "$got")"
fi
assert_regular_writable_file "$SETTINGS" "settings.json still regular after replace"

echo "-- vanished files cleaned even if they are regular copies --"
if [[ -e "$KEEP" ]]; then
  fail "vanished home.file still present at $KEEP (cleanup must drop scout/HM-managed copies, not only *-home-manager-files/* symlinks)"
else
  pass "vanished generation file removed (regular copy, not store symlink)"
fi

if [[ -f "$NESTED" && ! -L "$NESTED" ]]; then
  pass "file still in new generation was kept"
else
  fail "nested file from generation B missing"
fi

finish_suite
