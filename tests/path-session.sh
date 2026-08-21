#!/usr/bin/env bash
# PATH: nixScout.nixosModules.default prepends scout profile bin; Fish under Niri
# needs home.sessionPath (does not source /etc/set-environment).
# home.sessionPath lives in the standalone nix-scout nixos-module.nix.
#
# Run from repo root:
#   modules/nix-scout/tests/path-session.sh
set -euo pipefail

# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

echo "== PATH / sessionPath =="

# Resolve the binary first so NIX_SCOUT_ROOT is set and scout_module_candidates works.
BIN=""
if BIN="$(resolve_nix_scout)"; then
  pass "resolved nix-scout at $BIN (NIX_SCOUT_ROOT=$NIX_SCOUT_ROOT)"
else
  fail "nix-scout binary not resolved — NIX_SCOUT_ROOT unknown; PATH/sessionPath tests limited"
fi

# home.sessionPath definition must be in the standalone nixos-module.nix.
NS_MODULE="${NIX_SCOUT_ROOT:-}/nixos-module.nix"
if [[ ! -f "$NS_MODULE" && -f "$REPO/../nix-scout/nixos-module.nix" ]]; then
  NS_MODULE="$(cd "$REPO/../nix-scout" && pwd)/nixos-module.nix"
fi
if [[ -f "$NS_MODULE" ]]; then
  pass "nixos-module.nix found at $NS_MODULE"
  if "$GREP" -q 'home.sessionPath' "$NS_MODULE"; then
    pass "nixos-module.nix sets home.sessionPath (Fish/Niri HM path)"
  else
    fail "nixos-module.nix must set home.sessionPath so Fish under Niri gets scout profile bin ($NS_MODULE)"
  fi
  if "$GREP" -qE 'fish_add_path|sessionPath' "$NS_MODULE"; then
    pass "nixos-module.nix mentions home.sessionPath and/or fish_add_path"
  else
    fail "nixos-module.nix has neither home.sessionPath nor fish_add_path ($NS_MODULE)"
  fi
  if "$GREP" -qE 'profiles/per-user/.*/nix-scout|NIX_SCOUT_PROFILE|nix-scout/bin' "$NS_MODULE"; then
    pass "nixos-module.nix references scout profile bin on PATH"
  else
    fail "nixos-module.nix does not prepend scout profile bin ($NS_MODULE)"
  fi
else
  fail "nixos-module.nix not found at $NS_MODULE (NIX_SCOUT_ROOT may not be set)"
fi

# Host must import the constructor, not define sessionPath locally.
HOST="$REPO/hosts/void.nix"
if [[ -f "$HOST" ]] && "$GREP" -q 'nixosModule' "$HOST"; then
  pass "hosts/void.nix imports nix-scout.nixosModule"
else
  fail "hosts/void.nix must import inputs.nix-scout.nixosModule ($HOST)"
fi

finish_suite
