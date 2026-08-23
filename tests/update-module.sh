#!/usr/bin/env bash
# update-module.sh / `nix-scout update`: sync a module's committed flake.lock
# with its flake.nix-declared inputs via `nix flake lock` (add-only — never
# touches nodes already present, so the dummy sentinel nix-scout/nixpkgs
# nodes written by new-module.sh stay dummy). Covers the local/no-network
# contract (no-op when already in sync, error paths); resolving a genuinely
# new real input requires network and is exercised manually against a real
# module (e.g. `nix-scout update claude-code-proxy` in phoe-nix), not here.
#
# Run from repo root:
#   modules/nix-scout/tests/update-module.sh
set -euo pipefail

# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

echo "== update-module.sh / nix-scout update =="

scout_isolate
cleanup() { "$RM" -rf "$WORKDIR"; }
trap cleanup EXIT

export NIX_SCOUT_MODULES="$WORKDIR/modules"
"$MKDIR" -p "$NIX_SCOUT_MODULES"
scout_write_paths_file "$NIX_SCOUT_PATHS_FILE"

BIN=""
if BIN="$(resolve_strict_nix_scout)"; then
  pass "resolved nix-scout at $BIN"
else
  fail "nix-scout binary missing"
  finish_suite
fi

UPDATE_LIB="${NIX_SCOUT_ROOT:-$REPO}/lib/update-module.sh"
if [[ ! -f "$UPDATE_LIB" ]]; then
  fail "lib/update-module.sh missing"
  finish_suite
fi
pass "found update-module.sh at $UPDATE_LIB"

NEW_LIB="${NIX_SCOUT_ROOT:-$REPO}/lib/new-module.sh"

echo "-- scaffold a module (scout facet) --"
run_capture bash "$NEW_LIB" "$NIX_SCOUT_MODULES" sync-example scout
if [[ "$CAPTURED_RC" -ne 0 ]]; then
  fail "new-module.sh scaffold failed: $(printf %q "$CAPTURED_ERR$CAPTURED_OUT")"
  finish_suite
fi
MOD="$NIX_SCOUT_MODULES/sync-example"

echo "-- update is a no-op when flake.lock already covers every declared input --"
BEFORE_SUM="$("$SHA256SUM" "$MOD/flake.lock")"
run_capture bash "$UPDATE_LIB" "$MOD"
if [[ "$CAPTURED_RC" -eq 0 ]]; then
  pass "update-module.sh exit 0 on in-sync module"
else
  fail "update-module.sh should exit 0 on an in-sync module: $(printf %q "$CAPTURED_ERR")"
fi
if [[ "$CAPTURED_OUT$CAPTURED_ERR" == *"already up to date"* ]]; then
  pass "reports already up to date"
else
  fail "expected an 'already up to date' message, got $(printf %q "$CAPTURED_OUT$CAPTURED_ERR")"
fi
AFTER_SUM="$("$SHA256SUM" "$MOD/flake.lock")"
if [[ "$BEFORE_SUM" == "$AFTER_SUM" ]]; then
  pass "in-sync flake.lock is byte-identical after update (dummy sentinel untouched)"
else
  fail "update-module.sh must not rewrite an already-in-sync flake.lock"
fi

echo "-- update preserves flake.lock permission mode across a real rewrite --"
# sha256sum (used above) only covers content, not mode — mktemp creates its
# tmp file 0600 regardless of the target's mode, and `mv` onto the same
# filesystem keeps the source inode's permissions, not the destination's, so
# a naive atomic-write would silently strip flake.lock's group/other-read
# bits on every real update (breaking flakelet's unprivileged, read-only
# access to it). Force a real content change (nix flake lock itself is a
# no-op here since every declared input already has a node) so the
# mv/chmod-preserve path actually executes, not just the no-op branch.
"$CHMOD" 644 "$MOD/flake.lock"
"$JQ" '.nodes["nix-scout"].locked.lastModified = 1' "$MOD/flake.lock" >"$WORKDIR/corrupted-lock.json"
"$CP" "$WORKDIR/corrupted-lock.json" "$MOD/flake.lock"
"$CHMOD" 644 "$MOD/flake.lock"
run_capture bash "$UPDATE_LIB" "$MOD"
if [[ "$CAPTURED_RC" -eq 0 && "$CAPTURED_OUT$CAPTURED_ERR" == *"nix-scout: updated"* ]]; then
  pass "update-module.sh rewrote the corrupted flake.lock (sanity: real-write path exercised)"
else
  fail "expected update-module.sh to rewrite the corrupted lock: rc=$CAPTURED_RC out=$(printf %q "$CAPTURED_OUT$CAPTURED_ERR")"
fi
MODE_AFTER="$("$STAT" -c '%a' "$MOD/flake.lock" 2>/dev/null || true)"
if [[ "$MODE_AFTER" == "644" ]]; then
  pass "flake.lock keeps mode 644 after a real content rewrite"
else
  fail "flake.lock mode changed to '$MODE_AFTER' (want 644) after update — mktemp's 0600 leaked through mv"
fi

echo "-- update errors clearly on a module with no flake.nix --"
"$MKDIR" -p "$NIX_SCOUT_MODULES/no-flake"
run_capture bash "$UPDATE_LIB" "$NIX_SCOUT_MODULES/no-flake"
if [[ "$CAPTURED_RC" -ne 0 && "$CAPTURED_ERR" == *"missing flake.nix"* ]]; then
  pass "clear error for a module dir with no flake.nix"
else
  fail "expected a 'missing flake.nix' error, got rc=$CAPTURED_RC err=$(printf %q "$CAPTURED_ERR")"
fi

echo "-- update errors clearly when flake.lock is not writable --"
"$CHMOD" 444 "$MOD/flake.lock"
run_capture bash "$UPDATE_LIB" "$MOD"
"$CHMOD" 644 "$MOD/flake.lock"
if [[ "$CAPTURED_RC" -ne 0 && "$CAPTURED_ERR" == *"no write access"* ]]; then
  pass "clear error when flake.lock is read-only"
else
  fail "expected a 'no write access' error, got rc=$CAPTURED_RC err=$(printf %q "$CAPTURED_ERR")"
fi

echo "-- CLI: nix-scout update <name> --"
run_capture "$BIN" update sync-example
if [[ "$CAPTURED_RC" -eq 0 ]]; then
  pass "nix-scout update <name> exit 0"
else
  fail "nix-scout update <name> failed: $(printf %q "$CAPTURED_ERR$CAPTURED_OUT")"
fi

echo "-- CLI: nix-scout update all --"
run_capture bash "$NEW_LIB" "$NIX_SCOUT_MODULES" sync-example-two scout
[[ "$CAPTURED_RC" -eq 0 ]] || { fail "second scaffold failed"; finish_suite; }
run_capture "$BIN" update all
if [[ "$CAPTURED_RC" -eq 0 ]]; then
  pass "nix-scout update all exit 0"
else
  fail "nix-scout update all failed: $(printf %q "$CAPTURED_ERR$CAPTURED_OUT")"
fi
if [[ "$CAPTURED_ERR" == *"sync-example"* && "$CAPTURED_ERR" == *"sync-example-two"* ]]; then
  pass "update all visits every module"
else
  fail "expected update all to mention both modules, got $(printf %q "$CAPTURED_ERR")"
fi

echo "-- CLI: nix-scout update with no argument --"
run_capture "$BIN" update
if [[ "$CAPTURED_RC" -ne 0 && "$CAPTURED_ERR" == *"missing module name"* ]]; then
  pass "nix-scout update with no argument errors with usage"
else
  fail "expected a missing-argument error, got rc=$CAPTURED_RC err=$(printf %q "$CAPTURED_ERR")"
fi

echo "-- switch runs the same sync automatically (non-fatally) --"
if "$GREP" -qF 'bash "$(_scout_lib update-module.sh)" "$mod_dir"' "${NIX_SCOUT_ROOT:-$REPO}/bin/nix-scout"; then
  pass "_switch_module calls update-module.sh before materializing"
else
  fail "switch must sync flake.lock inputs automatically before materializing"
fi

finish_suite
