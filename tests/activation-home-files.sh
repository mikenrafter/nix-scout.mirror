#!/usr/bin/env bash
# NixOS activation: system.activationScripts.nix-scout-home-files applies the
# `home` facet (home-files/ copied into $HOME) on every rebuild, not just on
# an explicit `nix-scout switch <name>`. Defined in the standalone nix-scout
# nixos-module.nix.
#
# Run from repo root:
#   tests/activation-home-files.sh
set -euo pipefail

# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

echo "== NixOS activation home-files =="

BIN=""
if BIN="$(resolve_nix_scout)"; then
  pass "resolved nix-scout at $BIN (NIX_SCOUT_ROOT=$NIX_SCOUT_ROOT)"
else
  fail "nix-scout binary not resolved — NIX_SCOUT_ROOT unknown; activation tests limited"
fi

NS_MODULE="${NIX_SCOUT_ROOT:-}/nixos-module.nix"
if [[ -f "$NS_MODULE" ]]; then
  pass "nixos-module.nix found at $NS_MODULE"

  if "$GREP" -qE 'activationScripts\.nix-scout-home-files' "$NS_MODULE"; then
    pass "system.activationScripts.nix-scout-home-files defined"
  else
    fail "activation script not found in $NS_MODULE (want system.activationScripts.nix-scout-home-files)"
  fi

  if "$GREP" -qE 'apply-hm\.sh' "$NS_MODULE"; then
    pass "home-files activation reuses apply-hm.sh (same script \`nix-scout switch\` uses)"
  else
    fail "home-files activation should reuse lib/apply-hm.sh, not reimplement the copy logic ($NS_MODULE)"
  fi

  # Removal tracking: the activation script is the only caller allowed to
  # delete vanished home files (NIX_SCOUT_ACTIVATION=1); a plain
  # `nix-scout switch` run of the same script must never delete.
  if "$GREP" -qE 'NIX_SCOUT_ACTIVATION=1' "$NS_MODULE"; then
    pass "home-files activation opts into deletion mode (NIX_SCOUT_ACTIVATION=1)"
  else
    fail "home-files activation must set NIX_SCOUT_ACTIVATION=1 so apply-hm.sh may delete vanished files; CLI runs stay report-only ($NS_MODULE)"
  fi

  # runuser inherits root's environment — the per-user manifest/diff state
  # must be pinned to the owning user's state dir.
  if "$GREP" -qE 'XDG_STATE_HOME=' "$NS_MODULE"; then
    pass "home-files activation pins XDG_STATE_HOME to the owning user"
  else
    fail "home-files activation must pin XDG_STATE_HOME to the user's state dir (runuser would otherwise inherit root's) ($NS_MODULE)"
  fi

  # Per-file removal policies reach the HM activator as an eval-time JSON file.
  if "$GREP" -qE 'NIX_SCOUT_HM_POLICIES_FILE' "$NS_MODULE"; then
    pass "HM activation receives NIX_SCOUT_HM_POLICIES_FILE"
  else
    fail "nixos-module must pass NIX_SCOUT_HM_POLICIES_FILE (from nix-scout.homeFilePolicies) to hm-activate-files.sh ($NS_MODULE)"
  fi
  if "$GREP" -qE 'homeFilePolicies' "$NS_MODULE"; then
    pass "per-user option nix-scout.homeFilePolicies defined"
  else
    fail "HM shared module must define nix-scout.homeFilePolicies (remove|keep|keep-if-modified|inform per home file) ($NS_MODULE)"
  fi

  if "$GREP" -qE 'runuser' "$NS_MODULE"; then
    pass "home-files activation runs as the target user (runuser), not root"
  else
    fail "home-files activation must run apply-hm.sh as the owning user, e.g. via runuser ($NS_MODULE)"
  fi

  # Must fan out per normalUserNames, same as nix-scout-dirs/nix-scout-clear.
  if "$GREP" -A25 'activationScripts.nix-scout-home-files' "$NS_MODULE" | "$GREP" -qE 'normalUserNames'; then
    pass "home-files activation fans out over normalUserNames"
  else
    fail "home-files activation must iterate normalUserNames like nix-scout-dirs/nix-scout-clear ($NS_MODULE)"
  fi

  # A single broken module/user must not fail the whole rebuild.
  if "$GREP" -A25 'activationScripts.nix-scout-home-files' "$NS_MODULE" | "$GREP" -qE '\|\|'; then
    pass "home-files activation is non-fatal per module/user"
  else
    fail "home-files activation must not let one module's failure abort the rebuild ($NS_MODULE)"
  fi

  # Must run after user accounts exist.
  if "$GREP" -A30 'activationScripts.nix-scout-home-files' "$NS_MODULE" | "$GREP" -qE 'deps = \[ "users"'; then
    pass "home-files activation depends on \"users\""
  else
    fail "home-files activation must depend on \"users\" so home directories exist first ($NS_MODULE)"
  fi
else
  fail "nixos-module.nix not found at $NS_MODULE (cannot verify home-files activation)"
fi

finish_suite
