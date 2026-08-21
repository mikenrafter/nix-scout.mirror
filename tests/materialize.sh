#!/usr/bin/env bash
# Materialize contract (v2): lib/materialize-module.sh copies a module dir to /tmp
# and merges parent flake.lock inputs so drop-in modules build standalone.
#
# Run from repo root:
#   modules/nix-scout/tests/materialize.sh
set -euo pipefail

# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

require_nix

echo "== materialize-module.sh =="

scout_isolate
cleanup() { "$RM" -rf "$WORKDIR"; }
trap cleanup EXIT

BIN=""
if BIN="$(resolve_nix_scout)"; then
  pass "resolved nix-scout at $BIN (NIX_SCOUT_ROOT=$NIX_SCOUT_ROOT)"
else
  fail "nix-scout binary not resolved — NIX_SCOUT_ROOT unknown; cannot locate materialize script"
  finish_suite
fi

MAT=""
if ! MAT="$(resolve_materialize_script)"; then
  fail "missing ${NIX_SCOUT_ROOT}/lib/materialize-module.sh (materialize unimplemented)"
  finish_suite
fi
pass "resolved materialize script at $MAT"

if [[ ! -x "$MAT" ]]; then
  "$CHMOD" +x "$MAT" 2>/dev/null || true
fi

# Use nix-scout scout module as the test fixture (dms was removed).
TEST_MOD="$NIX_SCOUT_MODULES/nix-scout"
if [[ ! -d "$TEST_MOD" ]]; then
  fail "fixture module missing: $TEST_MOD (need scout-modules/nix-scout for materialize test)"
  finish_suite
fi

PARENT_LOCK="$NIX_SCOUT_PARENT/flake.lock"
if [[ ! -f "$PARENT_LOCK" ]]; then
  echo "FAIL: parent flake.lock missing at $PARENT_LOCK (harness)" >&2
  exit 2
fi

echo "-- materialize copies module to /tmp and returns path --"
MAT_OUT=""
run_capture env \
  NIX_SCOUT_PARENT="$NIX_SCOUT_PARENT" \
  WORKDIR="$WORKDIR" \
  bash "$MAT" "$TEST_MOD"
if [[ "$CAPTURED_RC" -eq 0 && -n "$CAPTURED_OUT" ]]; then
  MAT_OUT="${CAPTURED_OUT%%$'\n'*}"
  pass "materialize-module.sh exit 0 with output path"
else
  # Some implementations print path on stdout last line; accept env var contract too.
  MAT_OUT="${NIX_SCOUT_MATERIALIZED:-}"
  if [[ -n "$MAT_OUT" && -d "$MAT_OUT" ]]; then
    pass "materialize set NIX_SCOUT_MATERIALIZED=$MAT_OUT"
  else
    fail "materialize-module.sh failed (rc=$CAPTURED_RC err=$(printf %q "$CAPTURED_ERR") out=$(printf %q "$CAPTURED_OUT"))"
    finish_suite
  fi
fi

if [[ -z "$MAT_OUT" ]]; then
  MAT_OUT="${CAPTURED_OUT##*$'\n'}"
  MAT_OUT="${MAT_OUT%%$'\n'*}"
fi

if [[ "$MAT_OUT" == /tmp/* || "$MAT_OUT" == "${TMPDIR:-/tmp}"/* || "$MAT_OUT" == "$WORKDIR"/* ]]; then
  pass "materialized path is under /tmp or test workdir ($MAT_OUT)"
else
  fail "materialized path should be a temp dir (/tmp/...), got $MAT_OUT"
fi

if [[ -d "$MAT_OUT" && -f "$MAT_OUT/flake.nix" ]]; then
  pass "materialized dir contains flake.nix"
else
  fail "materialized dir missing flake.nix at $MAT_OUT"
fi

real_src="$(cd "$TEST_MOD" && pwd)"
real_mat="$(cd "$MAT_OUT" && pwd)"
if [[ "$real_mat" != "$real_src" ]]; then
  pass "materialized copy is not the source module dir (independent /tmp tree)"
else
  fail "materialize must copy to /tmp, not reuse source module path $TEST_MOD"
fi

echo "-- merged parent flake.lock inputs --"
if [[ -f "$MAT_OUT/flake.lock" ]]; then
  pass "materialized flake has flake.lock"
  parent_nodes=""
  mat_nodes=""
  if command -v "$JQ" >/dev/null 2>&1; then
    parent_nodes="$( "$JQ" -r '.nodes | keys | join(" ")' "$PARENT_LOCK" 2>/dev/null || true)"
    mat_nodes="$( "$JQ" -r '.nodes | keys | join(" ")' "$MAT_OUT/flake.lock" 2>/dev/null || true)"
    merged=0
    for node in nixpkgs home-manager; do
      if [[ "$parent_nodes" == *"$node"* && "$mat_nodes" == *"$node"* ]]; then
        merged=$((merged + 1))
      fi
    done
    if [[ "$merged" -ge 1 ]]; then
      pass "materialized flake.lock merges parent inputs (shared nodes with parent lock)"
    else
      fail "materialized flake.lock should merge parent inputs from $PARENT_LOCK (missing shared nodes)"
    fi
  else
    if "$GREP" -q '"nixpkgs"' "$MAT_OUT/flake.lock" && "$GREP" -q '"locked"' "$MAT_OUT/flake.lock"; then
      pass "materialized flake.lock looks populated (jq unavailable for deep compare)"
    else
      fail "materialized flake.lock missing expected locked inputs"
    fi
  fi
else
  fail "materialized dir has no flake.lock — parent inputs not merged"
fi

echo "-- materialized module builds .#scout only (not parent system) --"
run_capture "$NIX" build --no-link --print-out-paths --no-write-lock-file "$MAT_OUT#scout"
if [[ "$CAPTURED_RC" -eq 0 ]]; then
  pass "materialized module builds .#scout standalone"
  scout_out="${CAPTURED_OUT%%$'\n'*}"
  run_capture "$NIX" eval --json "$scout_out" --apply 'builtins.typeOf' --raw 2>/dev/null || true
else
  fail "materialized $MAT_OUT#scout build failed (rc=$CAPTURED_RC err=$(printf %q "$CAPTURED_ERR"))"
fi

echo "-- materialize writes scout-context.nix (systemRebuild=false) --"
if [[ -f "$MAT_OUT/scout-context.nix" ]] && "$GREP" -q 'systemRebuild = false' "$MAT_OUT/scout-context.nix"; then
  pass "materialize-module.sh seeds scout-context.nix with systemRebuild=false"
else
  fail "materialized module missing scout-context.nix with systemRebuild=false"
fi

echo "-- CLI build leaves systemRebuild at default false --"
PROBE_MOD="$WORKDIR/systemRebuild-probe"
mkdir -p "$PROBE_MOD"
cat > "$PROBE_MOD/flake.nix" <<'EOF'
{
  description = "systemRebuild probe fixture";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  outputs = args: let
    system = "x86_64-linux";
    pkgs = args.nixpkgs.legacyPackages.${system};
    systemRebuild = args.systemRebuild or (
      if builtins.pathExists ./scout-context.nix
      then (import ./scout-context.nix).systemRebuild
      else false
    );
  in {
    packages.${system}.scout = pkgs.writeText "scout-mode" (
      if systemRebuild then "rebuild" else "switch"
    );
  };
}
EOF
run_capture env NIX_SCOUT_PARENT="$NIX_SCOUT_PARENT" bash "$MAT" "$PROBE_MOD"
PROBE_MAT="${CAPTURED_OUT%%$'\n'*}"
run_capture "$NIX" build --no-link --print-out-paths --no-write-lock-file "$PROBE_MAT#scout"
if [[ "$CAPTURED_RC" -eq 0 ]]; then
  probe_out="${CAPTURED_OUT%%$'\n'*}"
  mode="$(cat "$probe_out" 2>/dev/null || true)"
  if [[ "$mode" == "switch" ]]; then
    pass "materialized nix build sees systemRebuild=false (CLI switch mode)"
  else
    fail "CLI build should default systemRebuild=false, got mode=$(printf %q "$mode")"
  fi
else
  fail "systemRebuild probe build failed (rc=$CAPTURED_RC err=$(printf %q "$CAPTURED_ERR"))"
fi

finish_suite
