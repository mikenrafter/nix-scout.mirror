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

echo "-- regression: home-files symlink + directory-valued entry (real HM layout) --"
# Real Home Manager generations never contain a home-files *directory* —
# home-files is itself a symlink to a store path (fixed in commit bf04afc),
# and a home.file entry sourced from a directory (e.g. programs.fish's
# generated_completions) is represented as a *single* symlink to a store
# directory, not one symlink per file inside it (fixed in commit 7fc93db).
# find's type filter previously matched each symlink itself instead of
# descending through it, so `cp --force` hit a bare directory and aborted
# activation under set -e. Both shapes are reproduced here so a third
# variant of this bug fails loudly instead of slipping past the suite.

GEN_C_STORE="$WORKDIR/gen-c-store"
GEN_C="$WORKDIR/new-gen-c"
FISH_COMPLETIONS_STORE="$WORKDIR/fish-completions-store"

"$MKDIR" -p \
  "$GEN_C_STORE/.config/DankMaterialShell" \
  "$GEN_C_STORE/.local/share/fish/home-manager" \
  "$FISH_COMPLETIONS_STORE" \
  "$GEN_C"
printf '%s\n' '{"theme":"gamma"}' >"$GEN_C_STORE/.config/DankMaterialShell/settings.json"
printf 'complete -c foo\n' >"$FISH_COMPLETIONS_STORE/foo.fish"
# Directory-sourced home.file entry: HM symlinks the whole dir as one leaf.
ln -s "$FISH_COMPLETIONS_STORE" "$GEN_C_STORE/.local/share/fish/home-manager/generated_completions"
# home-files itself is a symlink to the generation's store path, not a real dir.
ln -s "$GEN_C_STORE" "$GEN_C/home-files"

run_activator "$GEN_C" ""
if [[ "$CAPTURED_RC" -eq 0 ]]; then
  pass "activator exit 0 with home-files symlink + directory-valued entry"
else
  fail "activator failed on symlinked home-files layout (rc=$CAPTURED_RC err=$(printf %q "$CAPTURED_ERR"))"
fi

GEN_C_SETTINGS="$HOME/.config/DankMaterialShell/settings.json"
GEN_C_COMPLETION="$HOME/.local/share/fish/home-manager/generated_completions/foo.fish"

assert_regular_writable_file "$GEN_C_SETTINGS" "settings.json copied through home-files symlink"
assert_regular_writable_file "$GEN_C_COMPLETION" "file inside directory-valued home.file entry copied"

got="$("$CAT" "$GEN_C_COMPLETION" 2>/dev/null || true)"
if [[ "$got" == 'complete -c foo' || "$got" == $'complete -c foo\n' ]]; then
  pass "directory-valued entry content matches source"
else
  fail "directory-valued entry content mismatch: $(printf %q "$got")"
fi

echo "-- regression: systemd/user unit + .wants dropin stay symlinks --"
# cp-ing these breaks systemd: a .wants/ dropin that isn't a real symlink is
# rejected ("is not a symlink, ignoring"), so the unit never gets pulled in
# by graphical-session.target. Everything else still gets copied as before.

GEN_D_STORE="$WORKDIR/gen-d-store"
GEN_D="$WORKDIR/new-gen-d"

"$MKDIR" -p \
  "$GEN_D_STORE/.config/systemd/user/graphical-session.target.wants" \
  "$GEN_D_STORE/.config/DankMaterialShell" \
  "$GEN_D"
printf '[Service]\nExecStart=/nix/store/xxx/bin/dms\n' >"$GEN_D_STORE/.config/systemd/user/dms.service"
ln -s "$GEN_D_STORE/.config/systemd/user/dms.service" \
  "$GEN_D_STORE/.config/systemd/user/graphical-session.target.wants/dms.service"
printf '%s\n' '{"theme":"delta"}' >"$GEN_D_STORE/.config/DankMaterialShell/settings.json"
ln -s "$GEN_D_STORE" "$GEN_D/home-files"

run_activator "$GEN_D" ""
if [[ "$CAPTURED_RC" -eq 0 ]]; then
  pass "activator exit 0 with systemd/user units present"
else
  fail "activator failed on systemd/user layout (rc=$CAPTURED_RC err=$(printf %q "$CAPTURED_ERR"))"
fi

UNIT="$HOME/.config/systemd/user/dms.service"
WANTS_DROPIN="$HOME/.config/systemd/user/graphical-session.target.wants/dms.service"
UNIT_STORE_TARGET="$("$READLINK" -f "$GEN_D_STORE/.config/systemd/user/dms.service")"

assert_symlink_to "$UNIT" "$UNIT_STORE_TARGET" "unit file is a symlink, not a copy"
assert_symlink_to "$WANTS_DROPIN" "$UNIT_STORE_TARGET" ".wants dropin is a symlink, not a copy"

# Non-systemd files in the same generation are unaffected.
assert_regular_writable_file "$HOME/.config/DankMaterialShell/settings.json" \
  "settings.json still copied (unaffected by systemd/user carve-out)"

echo "-- per-file removal policies for vanished home.file entries --"
# NIX_SCOUT_HM_POLICIES_FILE (JSON, generated at eval time by the nix-scout
# NixOS module from nix-scout.homeFilePolicies) decides what happens to a file
# that vanishes from the generation. The baseline a keep-if-modified file is
# compared against is its copy in the old generation. Default (unlisted) is
# remove — covered above by the vanished keep note.

GEN_E_STORE="$WORKDIR/gen-e-store"
GEN_E="$WORKDIR/new-gen-e"
GEN_F_STORE="$WORKDIR/gen-f-store"
GEN_F="$WORKDIR/new-gen-f"

"$MKDIR" -p \
  "$GEN_E_STORE/.config/policyapp" \
  "$GEN_F_STORE/.config/policyapp" \
  "$GEN_E" "$GEN_F"
for f in default.conf keepme.conf edited.conf pristine.conf inform.conf; do
  printf 'original %s\n' "$f" >"$GEN_E_STORE/.config/policyapp/$f"
done
ln -s "$GEN_E_STORE" "$GEN_E/home-files"
ln -s "$GEN_F_STORE" "$GEN_F/home-files"

run_activator "$GEN_E" ""
if [[ "$CAPTURED_RC" -eq 0 ]]; then
  pass "activator exit 0 copying policy-test generation"
else
  fail "activator failed on policy-test generation (rc=$CAPTURED_RC err=$(printf %q "$CAPTURED_ERR"))"
fi

# User edits one keep-if-modified file after activation; the other stays
# pristine, so the old-generation copy is still its baseline.
printf 'user edit\n' >"$HOME/.config/policyapp/edited.conf"

POLICIES="$WORKDIR/hm-policies.json"
cat >"$POLICIES" <<'EOF'
{
  ".config/policyapp/keepme.conf": "keep",
  ".config/policyapp/edited.conf": "keep-if-modified",
  ".config/policyapp/pristine.conf": "keep-if-modified",
  ".config/policyapp/inform.conf": "inform"
}
EOF

# gen F drops all five files from the config. The policies file rides the
# environment (the NixOS module passes it the same way).
run_capture env \
  HOME="$HOME" \
  newGenPath="$GEN_F" \
  oldGenPath="$GEN_E" \
  NIX_SCOUT_HM_POLICIES_FILE="$POLICIES" \
  "$ACT"
if [[ "$CAPTURED_RC" -eq 0 ]]; then
  pass "activator exit 0 applying policies to vanished files"
else
  fail "activator failed on policy run (rc=$CAPTURED_RC err=$(printf %q "$CAPTURED_ERR"))"
fi

assert_file_absent "$HOME/.config/policyapp/default.conf" \
  "unlisted (default remove) vanished file deleted"
assert_file_present "$HOME/.config/policyapp/keepme.conf" \
  "keep-policy vanished file left in place"
assert_file_absent "$HOME/.config/policyapp/pristine.conf" \
  "keep-if-modified vanished file deleted when unmodified from baseline"
assert_file_present "$HOME/.config/policyapp/edited.conf" \
  "keep-if-modified vanished file left in place when user-edited"
assert_file_present "$HOME/.config/policyapp/inform.conf" \
  "inform-policy vanished file left in place"

for want in \
  "removed .config/policyapp/default.conf (no longer in the config)" \
  "removed .config/policyapp/pristine.conf (no longer in the config; unmodified from its baseline)" \
  "kept .config/policyapp/edited.conf (no longer in the config; differs from its baseline)" \
  "no longer managed by nix-scout (policy: inform)"; do
  if [[ "$CAPTURED_OUT$CAPTURED_ERR" == *"$want"* ]]; then
    pass "policy message: $want"
  else
    fail "policy message missing: $want (output: $(printf %q "$CAPTURED_OUT$CAPTURED_ERR"))"
  fi
done

# keep-policy files are silent on activation: no would-report noise.
if [[ "$CAPTURED_OUT$CAPTURED_ERR" == *".config/policyapp/keepme.conf"* ]]; then
  fail "keep-policy file should be silent on activation, got a message about it"
else
  pass "keep-policy file silent on activation"
fi

finish_suite
