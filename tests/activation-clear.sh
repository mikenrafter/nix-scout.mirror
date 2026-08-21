#!/usr/bin/env bash
# NixOS activation: system.activationScripts.nix-scout-clear clears profile +
# gc-roots on rebuild/boot. Defined in the standalone nix-scout nixos-module.nix.
#
# Run from repo root:
#   modules/nix-scout/tests/activation-clear.sh
set -euo pipefail

# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

echo "== NixOS activation clear =="

# Resolve the binary so NIX_SCOUT_ROOT is set.
BIN=""
if BIN="$(resolve_nix_scout)"; then
  pass "resolved nix-scout at $BIN (NIX_SCOUT_ROOT=$NIX_SCOUT_ROOT)"
else
  fail "nix-scout binary not resolved — NIX_SCOUT_ROOT unknown; activation tests limited"
fi

NS_MODULE="${NIX_SCOUT_ROOT:-}/nixos-module.nix"
if [[ -f "$NS_MODULE" ]]; then
  pass "nixos-module.nix found at $NS_MODULE"

  if "$GREP" -qE 'activationScripts\.nix-scout-config|/var/lib/nix-scout/paths' "$NS_MODULE"; then
    pass "system.activationScripts.nix-scout-config writes /var/lib/nix-scout/paths"
  else
    fail "activation must write /var/lib/nix-scout/paths ($NS_MODULE)"
  fi

  if "$GREP" -qE 'activationScripts\.nix-scout-clear|system\.activationScripts\.nix-scout' "$NS_MODULE"; then
    pass "system.activationScripts.nix-scout-clear (or equivalent) defined"
  else
    fail "activation script not found in $NS_MODULE (want system.activationScripts.nix-scout-clear)"
  fi

  if "$GREP" -qE 'nix-env|NIX_SCOUT_PROFILE|profiles/per-user/.*/nix-scout' "$NS_MODULE" \
    && "$GREP" -qE 'gcroots|NIX_SCOUT_GCROOTS' "$NS_MODULE"; then
    pass "activation clear mentions profile + gc-roots cleanup"
  else
    fail "activation clear does not reset profile + gc-roots ($NS_MODULE)"
  fi

  # Clear script uninstalls/removes profile — must use --uninstall or rm -f.
  if "$GREP" -qE 'uninstall|rm -f' "$NS_MODULE"; then
    pass "activation clear uses --uninstall or rm -f to clear profile"
  else
    fail "activation clear must use nix-env --uninstall or rm -f to clear profile ($NS_MODULE)"
  fi

  # Activation only clears — must not trigger a build.
  if "$GREP" -qE 'nix build|nix-build' "$NS_MODULE"; then
    fail "activation clear must not run nix build (activation only clears; switch builds)"
  else
    pass "activation clear does not contain nix build / nix-build"
  fi
else
  fail "nixos-module.nix not found at $NS_MODULE (cannot verify activation clear)"
fi

finish_suite
