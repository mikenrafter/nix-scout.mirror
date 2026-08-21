#!/usr/bin/env bash
# CLI contract (v2): binary is nix-scout; subcommands list/switch/status/clear/--help.
# Help must NOT mention dms-settings or hardcoded payload names.
#
# Run from repo root:
#   modules/nix-scout/tests/cli.sh
set -euo pipefail

# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

echo "== nix-scout CLI (v2) =="

scout_isolate
cleanup() { "$RM" -rf "$WORKDIR"; }
trap cleanup EXIT

BIN=""
STRICT_BIN=""
if BIN="$(resolve_nix_scout)"; then
  pass "resolved nix-scout at $BIN"
  STRICT_BIN="$(resolve_strict_nix_scout)"
else
  fail "nix-scout binary missing (tried \$NIX_SCOUT, system binary, and ${REPO}#packages.x86_64-linux.nix-scout build) — CLI unimplemented"
  finish_suite
fi

base="$("$BASENAME" "$BIN")"
if [[ "$base" == "nix-scout" ]]; then
  pass "binary basename is nix-scout (not scout)"
else
  fail "binary basename is '$base' (want nix-scout, not scout)"
fi

# CLI must not come from repo root bin/ (nix-scout was extracted to standalone repo).
if [[ "$BIN" != "$REPO/bin/nix-scout" ]]; then
  pass "binary resolved from correct location (not repo root bin/)"
else
  fail "binary should not come from repo root bin/ (nix-scout was extracted to standalone repo)"
fi

run_capture "$STRICT_BIN" --help
if [[ "$CAPTURED_RC" -eq 0 || "$CAPTURED_RC" -eq 1 ]]; then
  HELP_TEXT="$CAPTURED_OUT$CAPTURED_ERR"
  for sub in list switch status clear; do
    if [[ "$HELP_TEXT" == *"$sub"* ]]; then
      pass "--help mentions $sub"
    else
      fail "--help missing subcommand $sub (v2 contract: list/switch/status/clear)"
    fi
  done
  if [[ "$HELP_TEXT" == *nix-scout* ]]; then
    pass "--help names nix-scout"
  else
    fail "--help does not name nix-scout"
  fi
  if [[ "$HELP_TEXT" == *dms-settings* ]]; then
    fail "--help must NOT mention hardcoded payload dms-settings (v2 uses modules/<name>)"
  else
    pass "--help does not mention dms-settings"
  fi
  if [[ "$HELP_TEXT" == *payload* && "$HELP_TEXT" == *manifest* ]]; then
    fail "--help mentions manifest/payload registry (v2 has no manifest)"
  else
    pass "--help does not describe a manifest registry"
  fi
  help_paths_ok=0
  for token in NIX_SCOUT_PATHS_FILE /var/lib/nix-scout/paths "NixOS module"; do
    if [[ "$HELP_TEXT" == *"$token"* ]]; then
      help_paths_ok=1
      pass "--help documents paths file ($token)"
      break
    fi
  done
  if [[ "$help_paths_ok" -eq 0 ]]; then
    fail "--help should document /var/lib/nix-scout/paths (NixOS module contract)"
  fi
else
  fail "--help exited $CAPTURED_RC (stderr=$(printf %q "$CAPTURED_ERR"))"
fi

run_capture env NIX_SCOUT_PATHS_FILE="$NIX_SCOUT_PATHS_FILE" "$STRICT_BIN" list
if [[ "$CAPTURED_RC" -eq 0 ]]; then
  pass "nix-scout list exit 0"
  LIST_TEXT="$CAPTURED_OUT$CAPTURED_ERR"
  if [[ ! -d "$NIX_SCOUT_MODULES" ]]; then
    fail "list ran but \$NIX_SCOUT_MODULES ($NIX_SCOUT_MODULES) missing — switch cannot scan modules/"
  else
    # Verify at least one module from scout-modules/ appears in the listing.
    found_module=0
    for mod_dir in "$NIX_SCOUT_MODULES"/*/; do
      mod_name="$("$BASENAME" "$mod_dir")"
      if [[ "$LIST_TEXT" == *"$mod_name"* ]]; then
        found_module=1
        pass "list includes $mod_name module from \$NIX_SCOUT_MODULES"
        break
      fi
    done
    if [[ "$found_module" -eq 0 ]]; then
      fail "list should enumerate scout-modules/; got $(printf %q "$LIST_TEXT")"
    fi
  fi
else
  fail "nix-scout list failed (rc=$CAPTURED_RC err=$(printf %q "$CAPTURED_ERR")) — list subcommand unimplemented"
fi

run_capture "$BIN"
if [[ "$CAPTURED_RC" -ne 0 || "$CAPTURED_OUT$CAPTURED_ERR" == *switch* || "$CAPTURED_OUT$CAPTURED_ERR" == *usage* || "$CAPTURED_OUT$CAPTURED_ERR" == *Usage* ]]; then
  pass "bare nix-scout prints usage or non-zero (not a silent success)"
else
  fail "bare nix-scout succeeded with no usage text"
fi

echo "-- root guard --"
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  run_capture sudo env \
    NIX_SCOUT_PATHS_FILE="$NIX_SCOUT_PATHS_FILE" \
    NIX_SCOUT_PROFILE="$NIX_SCOUT_PROFILE" \
    NIX_SCOUT_GCROOTS="$NIX_SCOUT_GCROOTS" \
    "$BIN" list
  if [[ "$CAPTURED_RC" -ne 0 ]]; then
    pass "root guard: functional subcommands reject root execution"
  else
    fail "root guard: nix-scout list should exit non-zero when run as root"
  fi
  run_capture sudo "$BIN" --help
  if [[ "$CAPTURED_RC" -eq 0 || "$CAPTURED_RC" -eq 1 ]]; then
    pass "root guard: --help allowed under root"
  else
    fail "root guard: --help should work under root (got rc=$CAPTURED_RC)"
  fi
else
  pass "root guard: skipped (sudo not available without password)"
fi

echo "-- missing paths file must fail with NixOS module hint --"
run_capture env NIX_SCOUT_PATHS_FILE="$WORKDIR/missing-paths" "$STRICT_BIN" list
if [[ "$CAPTURED_RC" -ne 0 && "$CAPTURED_ERR$CAPTURED_OUT" == *nixosModule* ]]; then
  pass "list fails when paths file missing (mentions nixosModule)"
elif [[ "$CAPTURED_RC" -ne 0 && "$CAPTURED_ERR$CAPTURED_OUT" == *NixOS* ]]; then
  pass "list fails when paths file missing (mentions NixOS module)"
else
  fail "list without paths file should fail naming nixosModule; rc=$CAPTURED_RC err=$(printf %q "$CAPTURED_ERR$CAPTURED_OUT")"
fi

echo "-- runtime paths resolution --"
PATHS_CHECK="$STRICT_BIN"
if "$GREP" -q '/var/lib/nix-scout/paths' "$PATHS_CHECK"; then
  pass "CLI defaults to /var/lib/nix-scout/paths"
else
  fail "CLI must read paths from /var/lib/nix-scout/paths ($PATHS_CHECK)"
fi
if "$GREP" -q '@scoutModules@' "$PATHS_CHECK" || "$GREP" -q '@scoutParent@' "$PATHS_CHECK"; then
  fail "CLI must not bake paths via @scoutModules@/@scoutParent@ sentinels"
else
  pass "CLI has no path bake sentinels"
fi
if [[ -f /var/lib/nix-scout/paths ]]; then
  pass "/var/lib/nix-scout/paths exists on this system"
  # shellcheck source=/dev/null
  source /var/lib/nix-scout/paths
  if [[ -n "${NIX_SCOUT_MODULES:-}" && -n "${NIX_SCOUT_PARENT:-}" ]]; then
    pass "/var/lib/nix-scout/paths defines NIX_SCOUT_PARENT and NIX_SCOUT_MODULES"
  else
    fail "/var/lib/nix-scout/paths must assign NIX_SCOUT_PARENT and NIX_SCOUT_MODULES"
  fi
else
  pass "paths file check: /var/lib/nix-scout/paths absent (tests use NIX_SCOUT_* env)"
fi

finish_suite
