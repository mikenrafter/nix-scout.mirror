#!/usr/bin/env bash
# update-module.sh / `nix-scout update`: sync a module's committed
# flake.lock from NIX_SCOUT_PARENT's own flake.lock, PRUNED down (via
# `nix flake metadata`) to exactly what the module's flake.nix actually
# references (sync_lock_from_parent in scout-lib.sh). A module's own lock
# is never independently resolved; it just mirrors the relevant slice of
# the host's — pruning matters because the host's lock is a strict superset
# of what any module needs, and `nix flake metadata`/`archive`/`build` all
# rewrite a lock with unreferenced extra nodes in place, same as they'd add
# a missing one; flakelet's own calls never pass `--no-write-lock-file`, so
# an unpruned copy would make its supposedly read-only eval_user hit the
# exact permission failure this tool exists to prevent, just from the
# opposite direction.
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
# scout_write_paths_file exports NIX_SCOUT_PARENT (defaults to $REPO, which
# has its own real flake.lock) — that's what update-module.sh copies from.

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

echo "-- scaffold a module --"
run_capture bash "$NEW_LIB" "$NIX_SCOUT_MODULES" sync-example scout
if [[ "$CAPTURED_RC" -ne 0 ]]; then
  fail "new-module.sh scaffold failed: $(printf %q "$CAPTURED_ERR$CAPTURED_OUT")"
  finish_suite
fi
MOD="$NIX_SCOUT_MODULES/sync-example"

echo "-- update is a no-op when the module's lock already matches the host's --"
BEFORE_SUM="$("$SHA256SUM" "$MOD/flake.lock")"
MTIME_BEFORE="$("$STAT" -c '%Y' "$MOD/flake.lock")"
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
MTIME_AFTER="$("$STAT" -c '%Y' "$MOD/flake.lock")"
if [[ "$BEFORE_SUM" == "$AFTER_SUM" && "$MTIME_BEFORE" == "$MTIME_AFTER" ]]; then
  pass "in-sync flake.lock is byte-identical and untouched (mtime) — no unnecessary write"
else
  fail "update-module.sh must not rewrite an already-in-sync flake.lock"
fi

echo "-- update overwrites a module whose lock has drifted from the host's --"
"$CHMOD" 644 "$MOD/flake.lock"
echo '{"nodes":{"root":{"inputs":{}}},"root":"root","version":7}' >"$MOD/flake.lock"
run_capture bash "$UPDATE_LIB" "$MOD"
if [[ "$CAPTURED_RC" -eq 0 && "$CAPTURED_OUT$CAPTURED_ERR" == *"updated"* ]]; then
  pass "update-module.sh reports updated for a drifted lock"
else
  fail "expected an 'updated' report: rc=$CAPTURED_RC out=$(printf %q "$CAPTURED_OUT$CAPTURED_ERR")"
fi
# The host's lock is a superset of what this module declares; update-module.sh
# prunes it down (via `nix flake metadata`) to what's actually referenced, so
# it won't be byte-identical to the host's own file — check real content and
# stability instead (see the dedicated stability check further down).
NS_OWNER="$("$JQ" -r '.nodes["nix-scout"].locked.owner // "MISSING"' "$MOD/flake.lock")"
if [[ "$NS_OWNER" == "mikenrafter" ]]; then
  pass "module's flake.lock has real content sourced from the host"
else
  fail "expected real host-sourced content, got nix-scout owner='$NS_OWNER'"
fi

echo "-- update preserves flake.lock permission mode across a real rewrite --"
# mktemp creates its tmp file 0600 regardless of the target's mode, and `mv`
# onto the same filesystem keeps the source inode's permissions, not the
# destination's, so a naive atomic-write would silently strip flake.lock's
# group/other-read bits on every sync — breaking flakelet's unprivileged,
# read-only access to it.
"$CHMOD" 644 "$MOD/flake.lock"
echo '{"nodes":{"root":{"inputs":{}}},"root":"root","version":7}' >"$MOD/flake.lock"
"$CHMOD" 644 "$MOD/flake.lock"
run_capture bash "$UPDATE_LIB" "$MOD"
MODE_AFTER="$("$STAT" -c '%a' "$MOD/flake.lock" 2>/dev/null || true)"
if [[ "$MODE_AFTER" == "644" ]]; then
  pass "flake.lock keeps mode 644 after a real content rewrite"
else
  fail "flake.lock mode changed to '$MODE_AFTER' (want 644) after update — mktemp's 0600 leaked through mv"
fi

echo "-- update creates flake.lock for a module that lost it --"
"$RM" -f "$MOD/flake.lock"
run_capture bash "$UPDATE_LIB" "$MOD"
if [[ "$CAPTURED_RC" -eq 0 && -f "$MOD/flake.lock" ]]; then
  pass "update-module.sh recreates a missing flake.lock from the host's"
else
  fail "expected flake.lock to be recreated: rc=$CAPTURED_RC out=$(printf %q "$CAPTURED_OUT$CAPTURED_ERR")"
fi
NS_OWNER2="$("$JQ" -r '.nodes["nix-scout"].locked.owner // "MISSING"' "$MOD/flake.lock")"
if [[ "$NS_OWNER2" == "mikenrafter" ]]; then
  pass "recreated flake.lock has real content sourced from the host"
else
  fail "expected real host-sourced content, got nix-scout owner='$NS_OWNER2'"
fi
MODE_CREATED="$("$STAT" -c '%a' "$MOD/flake.lock" 2>/dev/null || true)"
if [[ "$MODE_CREATED" == "644" ]]; then
  pass "newly-created flake.lock is world-readable (644)"
else
  fail "newly-created flake.lock has unexpected mode '$MODE_CREATED' (want 644)"
fi

echo "-- the synced lock is stable: a real nix flake command never rewrites it again --"
# This is the core property update-module.sh must guarantee: flakelet's own
# calls (nix flake metadata / archive, never with --no-write-lock-file) must
# never find anything left to add OR prune, or its unprivileged, read-only
# eval_user hits the exact permission failure this tool exists to prevent —
# from the opposite direction of a merely-incomplete lock.
STABLE_BEFORE="$("$SHA256SUM" "$MOD/flake.lock")"
nix flake metadata --json "path:$MOD" >/dev/null 2>&1
STABLE_AFTER="$("$SHA256SUM" "$MOD/flake.lock")"
if [[ "$STABLE_BEFORE" == "$STABLE_AFTER" ]]; then
  pass "nix flake metadata does not rewrite the synced lock (already pruned/stable)"
else
  fail "nix flake metadata rewrote the synced lock — it wasn't fully pruned"
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

echo "-- update errors clearly when NIX_SCOUT_PARENT is unset --"
run_capture env -u NIX_SCOUT_PARENT bash "$UPDATE_LIB" "$MOD"
if [[ "$CAPTURED_RC" -ne 0 && "$CAPTURED_ERR" == *"NIX_SCOUT_PARENT"* ]]; then
  pass "clear error when NIX_SCOUT_PARENT is unset"
else
  fail "expected a NIX_SCOUT_PARENT error, got rc=$CAPTURED_RC err=$(printf %q "$CAPTURED_ERR")"
fi

echo "-- update errors clearly when the host has no flake.lock --"
"$MKDIR" -p "$WORKDIR/no-lock-parent"
run_capture env NIX_SCOUT_PARENT="$WORKDIR/no-lock-parent" bash "$UPDATE_LIB" "$MOD"
if [[ "$CAPTURED_RC" -ne 0 && "$CAPTURED_ERR" == *"flake.lock missing"* ]]; then
  pass "clear error when the host's own flake.lock is missing"
else
  fail "expected a host-flake.lock-missing error, got rc=$CAPTURED_RC err=$(printf %q "$CAPTURED_ERR")"
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
