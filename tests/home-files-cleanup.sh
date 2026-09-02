#!/usr/bin/env bash
# Scout home-files removal tracking (apply-hm.sh):
#   - every applied file is recorded (relpath, policy, baseline sha256) in the
#     per-module manifest under $XDG_STATE_HOME/nix-scout/home-files/
#   - manifest entries absent from the store are handled per their recorded
#     policy: remove (default) | keep | keep-if-modified | inform
#   - CLI mode (the default when running apply-hm.sh by hand, i.e. what
#     `nix-scout switch` does) NEVER deletes — it reports what a rebuild
#     would do for every vanished file
#   - activation mode (NIX_SCOUT_ACTIVATION=1, what the NixOS module's
#     nix-scout-home-files script does) actually deletes per policy
#
# Run from repo root:
#   tests/home-files-cleanup.sh
set -euo pipefail

# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

echo "== scout home-files removal tracking (apply-hm.sh) =="

scout_isolate
cleanup() { "$RM" -rf "$WORKDIR"; }
trap cleanup EXIT

APPLY="$NIX_SCOUT_ROOT/lib/apply-hm.sh"
if [[ -f "$APPLY" ]]; then
  pass "apply-hm.sh found at $APPLY"
else
  fail "apply-hm.sh missing from NIX_SCOUT_ROOT/lib/ ($NIX_SCOUT_ROOT)"
  finish_suite
fi

MANIFEST="$XDG_STATE_HOME/nix-scout/home-files/scoutapp.manifest"
DEST_CFG="$XDG_CONFIG_HOME/scoutapp"

# Run apply-hm.sh the way each caller does: CLI mode (nix-scout switch) and
# activation mode (NixOS module activation script).
run_cli() {
  run_capture env \
    HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_STATE_HOME="$XDG_STATE_HOME" \
    bash "$APPLY" "$1" scoutapp
}
run_activation() {
  run_capture env \
    HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_STATE_HOME="$XDG_STATE_HOME" \
    NIX_SCOUT_ACTIVATION=1 \
    bash "$APPLY" "$1" scoutapp
}
assert_rc0() {
  if [[ "$CAPTURED_RC" -eq 0 ]]; then
    pass "$1"
  else
    fail "$1 (rc=$CAPTURED_RC err=$(printf %q "$CAPTURED_ERR"))"
  fi
}
assert_manifest_has() {
  if [[ -f "$MANIFEST" ]] && "$GREP" -qF "$1" "$MANIFEST"; then
    pass "manifest records $1"
  else
    fail "manifest missing entry $1 ($(cat "$MANIFEST" 2>/dev/null || echo 'no manifest'))"
  fi
}
assert_manifest_lacks() {
  if [[ -f "$MANIFEST" ]] && "$GREP" -qF "$1" "$MANIFEST"; then
    fail "manifest still records $1 (wanted dropped)"
  else
    pass "manifest dropped $1"
  fi
}
assert_output_contains() {
  local haystack="$CAPTURED_OUT$CAPTURED_ERR"
  if [[ "$haystack" == *"$1"* ]]; then
    pass "$2"
  else
    fail "$2 (output: $(printf %q "$haystack"))"
  fi
}

# --- generation A: three files, no home-manage.json (all default remove) ----
STORE="$WORKDIR/gen-a"
"$MKDIR" -p "$STORE/home-files/.config/scoutapp" "$STORE/home-files/.local/share/scoutapp"
printf '%s\n' '{"v":1}' >"$STORE/home-files/.config/scoutapp/config.json"
printf 'extra\n' >"$STORE/home-files/.config/scoutapp/extra.conf"
printf 'data\n' >"$STORE/home-files/.local/share/scoutapp/data.txt"

run_cli "$STORE"
assert_rc0 "CLI first apply exit 0"
assert_file_present "$DEST_CFG/config.json" "config.json copied"
assert_file_present "$DEST_CFG/extra.conf" "extra.conf copied"
assert_manifest_has ".config/scoutapp/config.json"
assert_manifest_has ".config/scoutapp/extra.conf"
assert_manifest_has ".local/share/scoutapp/data.txt"

# --- generation B: extra.conf + data.txt dropped; user has edited config ----
printf '%s\n' '{"v":1,"edited":true}' >"$DEST_CFG/config.json"
STORE="$WORKDIR/gen-b"
"$MKDIR" -p "$STORE/home-files/.config/scoutapp"
printf '%s\n' '{"v":1}' >"$STORE/home-files/.config/scoutapp/config.json"

run_cli "$STORE"
assert_rc0 "CLI second apply exit 0"
assert_file_present "$DEST_CFG/extra.conf" "CLI never deletes: vanished extra.conf left in place"
assert_file_present "$HOME/.local/share/scoutapp/data.txt" "CLI never deletes: vanished data.txt left in place"
assert_output_contains \
  ".config/scoutapp/extra.conf is no longer in the config — a rebuild would delete it (policy: remove); skipped" \
  "CLI reports would-be deletion for default-policy file"
assert_output_contains \
  ".local/share/scoutapp/data.txt is no longer in the config — a rebuild would delete it (policy: remove); skipped" \
  "CLI reports would-be deletion outside .config too"
assert_manifest_has ".config/scoutapp/extra.conf" "entry retained for the rebuild to act on"

run_activation "$STORE"
assert_rc0 "activation apply exit 0"
assert_file_absent "$DEST_CFG/extra.conf" "activation deletes vanished default-policy file"
assert_file_absent "$HOME/.local/share/scoutapp/data.txt" "activation deletes vanished file outside .config"
assert_manifest_lacks ".config/scoutapp/extra.conf"

# --- keep-if-modified: user edit survives, pristine baseline does not -------
STORE="$WORKDIR/gen-c"
"$MKDIR" -p "$STORE/home-files/.config/scoutapp"
printf 'modme\n' >"$STORE/home-files/.config/scoutapp/modcheck.conf"
cat >"$STORE/home-manage.json" <<'EOF'
{
  ".config/scoutapp/modcheck.conf": "keep-if-modified"
}
EOF

run_activation "$STORE"
assert_rc0 "activation apply with home-manage.json exit 0"
assert_manifest_has ".config/scoutapp/modcheck.conf"

printf 'user edit\n' >"$DEST_CFG/modcheck.conf"
STORE="$WORKDIR/gen-d"
"$MKDIR" -p "$STORE/home-files/.config/scoutapp"
printf 'placeholder\n' >"$STORE/home-files/.config/scoutapp/config.json"

run_activation "$STORE"
assert_rc0 "activation run with edited keep-if-modified file exit 0"
assert_file_present "$DEST_CFG/modcheck.conf" "keep-if-modified: user-edited file left in place"
assert_output_contains \
  "kept .config/scoutapp/modcheck.conf (no longer in the config; differs from its baseline)" \
  "activation reports why the edited file was kept"
assert_manifest_has ".config/scoutapp/modcheck.conf"

# revert to the baseline the activator wrote -> the sweep may proceed
printf 'modme\n' >"$DEST_CFG/modcheck.conf"
run_activation "$STORE"
assert_file_absent "$DEST_CFG/modcheck.conf" "keep-if-modified: reverted (unmodified) file deleted"
assert_manifest_lacks ".config/scoutapp/modcheck.conf"

# --- keep: never deleted; inform: never deleted, always announced -----------
STORE="$WORKDIR/gen-e"
"$MKDIR" -p "$STORE/home-files/.config/scoutapp"
printf 'persist\n' >"$STORE/home-files/.config/scoutapp/persist.conf"
printf 'notify\n' >"$STORE/home-files/.config/scoutapp/notify.conf"
printf 'weird\n' >"$STORE/home-files/.config/scoutapp/banana.conf"
cat >"$STORE/home-manage.json" <<'EOF'
{
  ".config/scoutapp/persist.conf": "keep",
  ".config/scoutapp/notify.conf": "inform",
  ".config/scoutapp/banana.conf": "banana"
}
EOF

run_activation "$STORE"
assert_rc0 "activation apply of keep/inform files exit 0"
assert_output_contains \
  "unknown home-file policy 'banana' — treating as 'remove'" \
  "unknown policy value warns at parse time"

STORE="$WORKDIR/gen-f"
"$MKDIR" -p "$STORE/home-files/.config/scoutapp"
printf 'placeholder\n' >"$STORE/home-files/.config/scoutapp/config.json"

run_cli "$STORE"
assert_output_contains \
  "a rebuild would leave it in place (policy: keep)" \
  "CLI reports keep-policy vanished file"
assert_output_contains \
  ".config/scoutapp/notify.conf is no longer managed by nix-scout (policy: inform)" \
  "CLI announces inform-policy vanished file"

run_activation "$STORE"
assert_file_present "$DEST_CFG/persist.conf" "keep: file never deleted by activation"
assert_file_present "$DEST_CFG/notify.conf" "inform: file never deleted by activation"
assert_output_contains \
  ".config/scoutapp/notify.conf is no longer managed by nix-scout (policy: inform)" \
  "activation announces inform-policy vanished file"

# unknown policy value must have warned (parse time) and fall back to remove
assert_file_absent "$DEST_CFG/banana.conf" "unknown policy falls back to remove (deleted)"
assert_manifest_lacks ".config/scoutapp/banana.conf"

# --- re-adoption: a file restored to the config gets a fresh baseline -------
STORE="$WORKDIR/gen-g"
"$MKDIR" -p "$STORE/home-files/.config/scoutapp"
printf 'persist\n' >"$STORE/home-files/.config/scoutapp/persist.conf"
run_activation "$STORE"
assert_manifest_has ".config/scoutapp/persist.conf"

STORE="$WORKDIR/gen-h"
"$MKDIR" -p "$STORE/home-files/.config/scoutapp"
printf 'placeholder\n' >"$STORE/home-files/.config/scoutapp/config.json"
run_activation "$STORE"
assert_file_absent "$DEST_CFG/persist.conf" "re-adopted file re-swept under its fresh (default) policy"

# --- module that dropped home-files/ entirely still sweeps ------------------
STORE="$WORKDIR/gen-i"
"$MKDIR" -p "$STORE"
run_activation "$STORE"
assert_rc0 "activation with no home-files/ tree exit 0"
assert_manifest_lacks ".config/scoutapp/config.json" "dropped-facet module sweeps its manifest"

finish_suite
