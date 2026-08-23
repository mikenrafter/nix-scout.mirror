#!/usr/bin/env bash
# update-module.sh / `nix-scout update`: sync a module's committed flake.lock
# with its flake.nix-declared inputs. Behavior branches on whether the
# module has a flakelet facet (see lib/update-module.sh's header comment):
#
# * No flakelet facet: nothing ever really touches this module's own lock
#   (switch/rebuild always threads the parent's own resolved inputs
#   instead), so nix-scout AND nixpkgs both stay the dummy sentinel
#   new-module.sh writes, permanently — every other declared input is real.
# * Has a flakelet facet: flakelet's own `nix flake archive` (run after
#   every build, to gc-root the flake source + ALL inputs) eagerly fetches
#   every node regardless of whether anything dereferences it — so NOTHING
#   can be dummy, not even nix-scout.
#
# Covers both branches (real inputs via a local path: stand-in where
# possible, no network needed for that part) and the error/permission
# paths. Requires network for the framework-input promotions themselves; a
# genuinely new non-framework *network* input is exercised manually against
# a real module (e.g. `nix-scout update claude-code-proxy` in phoe-nix), not
# here.
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

# ============================================================
# No flakelet facet: nix-scout AND nixpkgs stay dummy, always.
# ============================================================

echo "-- scaffold a module (scout facet, no flakelet) --"
run_capture bash "$NEW_LIB" "$NIX_SCOUT_MODULES" sync-example scout
if [[ "$CAPTURED_RC" -ne 0 ]]; then
  fail "new-module.sh scaffold failed: $(printf %q "$CAPTURED_ERR$CAPTURED_OUT")"
  finish_suite
fi
MOD="$NIX_SCOUT_MODULES/sync-example"
"$GREP" -qF 'flakelets.' "$MOD/flake.nix" && {
  fail "sync-example unexpectedly has a flakelet facet — test fixture assumption broken"
  finish_suite
}

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
  pass "in-sync flake.lock is byte-identical after update (dummy sentinel untouched, no network)"
else
  fail "update-module.sh must not rewrite an already-in-sync flake.lock"
fi
NS_OWNER="$("$JQ" -r '.nodes["nix-scout"].locked.owner // "MISSING"' "$MOD/flake.lock")"
NP_OWNER="$("$JQ" -r '.nodes[(.nodes.root.inputs.nixpkgs)].locked.owner // "MISSING"' "$MOD/flake.lock")"
if [[ "$NS_OWNER" == "nix-scout_not-real-lockfile" && "$NP_OWNER" == "nix-scout_not-real-lockfile" ]]; then
  pass "nix-scout AND nixpkgs both stay dummy (no flakelet facet — nothing real ever touches this lock)"
else
  fail "expected both dummy, got nix-scout='$NS_OWNER' nixpkgs='$NP_OWNER'"
fi

echo "-- update resolves a non-framework input for real, framework nodes stay dummy --"
# A local path: input stands in for a real network input without requiring
# further network access in this suite.
"$MKDIR" -p "$WORKDIR/tiny-flake"
cat >"$WORKDIR/tiny-flake/flake.nix" <<'EOF'
{ outputs = _: { }; }
EOF
"$GREP" -q 'inputs.nixpkgs.url' "$MOD/flake.nix" || {
  fail "scaffolded flake.nix missing expected inputs.nixpkgs.url line"
  finish_suite
}
TMP_FLAKE="$WORKDIR/patched-flake.nix"
"$CAT" "$MOD/flake.nix" | while IFS= read -r line; do
  printf '%s\n' "$line"
  if [[ "$line" == *'inputs.nixpkgs.url'* ]]; then
    printf '  inputs.tiny.url = "path:%s";\n' "$WORKDIR/tiny-flake"
  fi
done >"$TMP_FLAKE"
"$CP" "$TMP_FLAKE" "$MOD/flake.nix"

run_capture bash "$UPDATE_LIB" "$MOD"
if [[ "$CAPTURED_RC" -eq 0 ]]; then
  pass "update-module.sh resolves the new real input successfully"
else
  fail "update-module.sh failed on a module with a real extra input: $(printf %q "$CAPTURED_ERR$CAPTURED_OUT")"
fi
TINY_NAR="$("$JQ" -r '.nodes.tiny.locked.narHash // "MISSING"' "$MOD/flake.lock")"
if [[ "$TINY_NAR" != "MISSING" && "$TINY_NAR" != "sha256-0000000000000000000000000000000000000000000=" ]]; then
  pass "non-framework input (tiny) resolved to real, non-sentinel content"
else
  fail "expected a real narHash for the 'tiny' input, got '$TINY_NAR'"
fi
NS_OWNER2="$("$JQ" -r '.nodes["nix-scout"].locked.owner // "MISSING"' "$MOD/flake.lock")"
NP_OWNER2="$("$JQ" -r '.nodes[(.nodes.root.inputs.nixpkgs)].locked.owner // "MISSING"' "$MOD/flake.lock")"
if [[ "$NS_OWNER2" == "nix-scout_not-real-lockfile" && "$NP_OWNER2" == "nix-scout_not-real-lockfile" ]]; then
  pass "nix-scout/nixpkgs stay dummy alongside a real extra input"
else
  fail "must stay dummy: nix-scout='$NS_OWNER2' nixpkgs='$NP_OWNER2'"
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

# ============================================================
# Has a flakelet facet: everything real, including nix-scout.
# ============================================================

echo "-- scaffold a module with a flakelet facet --"
run_capture bash "$NEW_LIB" "$NIX_SCOUT_MODULES" flakelet-example flakelet
if [[ "$CAPTURED_RC" -ne 0 ]]; then
  fail "new-module.sh flakelet scaffold failed: $(printf %q "$CAPTURED_ERR$CAPTURED_OUT")"
  finish_suite
fi
FMOD="$NIX_SCOUT_MODULES/flakelet-example"
"$GREP" -qF 'flakelets.' "$FMOD/flake.nix" || {
  fail "flakelet-example missing expected flakelets. facet"
  finish_suite
}

echo "-- update on a flakelet-facet module promotes nix-scout to real too --"
run_capture bash "$UPDATE_LIB" "$FMOD"
if [[ "$CAPTURED_RC" -eq 0 ]]; then
  pass "update-module.sh exit 0 on flakelet-facet module"
else
  fail "update-module.sh failed on flakelet-facet module: $(printf %q "$CAPTURED_ERR$CAPTURED_OUT")"
fi
FNS_OWNER="$("$JQ" -r '.nodes["nix-scout"].locked.owner // "MISSING"' "$FMOD/flake.lock")"
FNP_OWNER="$("$JQ" -r '.nodes[(.nodes.root.inputs.nixpkgs)].locked.owner // "MISSING"' "$FMOD/flake.lock")"
if [[ "$FNS_OWNER" == "mikenrafter" ]]; then
  pass "nix-scout promoted to real content (flakelet facet: nothing may stay dummy)"
else
  fail "expected nix-scout to be real for a flakelet-facet module, got owner='$FNS_OWNER'"
fi
if [[ "$FNP_OWNER" == "NixOS" ]]; then
  pass "nixpkgs is real content"
else
  fail "expected nixpkgs to be real, got owner='$FNP_OWNER'"
fi

echo "-- a second update on the flakelet-facet module is a true no-op --"
FMTIME_BEFORE="$("$STAT" -c '%Y' "$FMOD/flake.lock")"
run_capture bash "$UPDATE_LIB" "$FMOD"
FMTIME_AFTER="$("$STAT" -c '%Y' "$FMOD/flake.lock")"
if [[ "$CAPTURED_RC" -eq 0 && "$CAPTURED_OUT$CAPTURED_ERR" == *"already up to date"* && "$FMTIME_BEFORE" == "$FMTIME_AFTER" ]]; then
  pass "second run on flakelet-facet module is a true no-op"
else
  fail "expected a stable no-op second run: rc=$CAPTURED_RC out=$(printf %q "$CAPTURED_OUT$CAPTURED_ERR")"
fi

echo "-- a flakelet-only module with zero declared inputs is a graceful no-op --"
"$MKDIR" -p "$NIX_SCOUT_MODULES/flakelet-only"
cat >"$NIX_SCOUT_MODULES/flakelet-only/flake.nix" <<'EOF'
{
  outputs = inputs: {
    flakelets.default = { types, ... }: {
      options = { };
      impl = { options, pkgs, name, ... }: {
        services.${name} = {
          description = "test";
          serviceConfig.ExecStart = "${pkgs.coreutils}/bin/true";
        };
      };
    };
  };
}
EOF
run_capture bash "$UPDATE_LIB" "$NIX_SCOUT_MODULES/flakelet-only"
if [[ "$CAPTURED_RC" -eq 0 ]]; then
  pass "update-module.sh exit 0 on a zero-input flakelet-only module"
else
  fail "update-module.sh should not error on a zero-input module: $(printf %q "$CAPTURED_ERR$CAPTURED_OUT")"
fi
if [[ -f "$NIX_SCOUT_MODULES/flakelet-only/flake.lock" ]]; then
  fail "a zero-input flakelet-only module should get no flake.lock at all"
else
  pass "no flake.lock created for a zero-input module (matches flakelet's own contract)"
fi
if [[ "$CAPTURED_ERR" != *"jq: error"* ]]; then
  pass "no stray jq errors on a zero-input module"
else
  fail "got a stray jq error: $(printf %q "$CAPTURED_ERR")"
fi

# ============================================================
# Shared error paths
# ============================================================

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
