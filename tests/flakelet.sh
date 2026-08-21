#!/usr/bin/env bash
# Flakelet integration contracts (v3):
#   - apply-output.sh delegates to apply-hm.sh / apply-env.sh (split scripts exist)
#   - apply-output.sh has no early exit 0 after home-files
#   - apply-flakelet.sh exists in lib/
#   - CLI _switch_module fan-out: uses apply-flakelet.sh, tracks switch_rc
#   - nixos-module.nix imports flakelet and auto-registers via settings.nix
#
# Run from nix-scout root:
#   tests/flakelet.sh
set -euo pipefail

# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

echo "== flakelet integration =="

# ── lib/ split scripts exist ─────────────────────────────────────────────────
echo "-- lib/: apply-hm.sh, apply-env.sh, apply-flakelet.sh exist --"
for script in apply-hm.sh apply-env.sh apply-flakelet.sh; do
  cand="$REPO/lib/$script"
  if [[ -f "$cand" ]]; then
    pass "lib/$script exists"
  else
    fail "lib/$script missing — apply-output.sh should be split into sub-scripts"
  fi
done

# ── apply-output.sh: orchestrator, calls sub-scripts, no early exit 0 ────────
echo "-- apply-output.sh: orchestrates sub-scripts, non-exclusive --"
APPLY=""
if APPLY="$(resolve_apply_output_script)"; then
  if "$GREP" -q 'exit 0' "$APPLY"; then
    fail "apply-output.sh still has early 'exit 0' — must be non-exclusive"
  else
    pass "apply-output.sh has no early exit 0"
  fi
  if "$GREP" -q 'apply-hm\.sh' "$APPLY" && "$GREP" -q 'apply-env\.sh' "$APPLY"; then
    pass "apply-output.sh delegates to apply-hm.sh and apply-env.sh"
  else
    fail "apply-output.sh must call apply-hm.sh and apply-env.sh"
  fi
  if "$GREP" -qE 'rc=0|rc=\$\?' "$APPLY"; then
    pass "apply-output.sh tracks aggregated rc (non-atomic error handling)"
  else
    fail "apply-output.sh must aggregate rc from sub-scripts"
  fi
else
  fail "apply-output.sh not found (resolve_apply_output_script failed)"
fi

# ── apply-flakelet.sh: calls flakelet update ─────────────────────────────────
echo "-- apply-flakelet.sh: calls flakelet update --"
FLAKELET_SCRIPT="$REPO/lib/apply-flakelet.sh"
if [[ -f "$FLAKELET_SCRIPT" ]]; then
  if "$GREP" -q 'flakelet update' "$FLAKELET_SCRIPT"; then
    pass "apply-flakelet.sh calls 'flakelet update'"
  else
    fail "apply-flakelet.sh must call 'sudo flakelet update \$NAME'"
  fi
else
  fail "apply-flakelet.sh not found at $FLAKELET_SCRIPT"
fi

# ── CLI: _switch_module uses apply-flakelet.sh, tracks switch_rc ─────────────
echo "-- CLI: _switch_module non-atomic error handling --"
BIN=""
if BIN="$(resolve_strict_nix_scout)"; then
  if "$GREP" -q 'apply-flakelet\.sh\|apply_flakelet' "$BIN"; then
    pass "bin/nix-scout references apply-flakelet.sh"
  else
    fail "bin/nix-scout must use lib/apply-flakelet.sh in _switch_module"
  fi
  if "$GREP" -q 'switch_rc' "$BIN"; then
    pass "bin/nix-scout tracks switch_rc for non-atomic error accumulation"
  else
    fail "bin/nix-scout must track switch_rc so all facets run before reporting failure"
  fi
  if "$GREP" -q 'sudo flakelet update' "$BIN"; then
    fail "bin/nix-scout still has inline 'sudo flakelet update' — should delegate to apply-flakelet.sh"
  else
    pass "bin/nix-scout delegates flakelet to apply-flakelet.sh (no inline sudo call)"
  fi
else
  fail "nix-scout binary not found (CLI flakelet fan-out unimplemented)"
fi

# ── nixos-module.nix: flakelet import + settings.nix wiring ─────────────────
echo "-- nixos-module.nix: flakelet module import and settings.nix wiring --"
NS_MODULE="$REPO/nixos-module.nix"
if [[ -f "$NS_MODULE" ]]; then
  if "$GREP" -q 'flakelet\.nixosModules\.flakelet' "$NS_MODULE"; then
    pass "nixos-module.nix imports flakelet.nixosModules.flakelet"
  else
    fail "nixos-module.nix must import flakelet.nixosModules.flakelet"
  fi
  if "$GREP" -q 'settingsFile' "$NS_MODULE" && "$GREP" -q 'settings\.nix' "$NS_MODULE"; then
    pass "nixos-module.nix reads settings.nix for flakelet registration"
  else
    fail "nixos-module.nix must read settings.nix from each flakelet scout-module"
  fi
  if "$GREP" -q 'services\.flakelets' "$NS_MODULE"; then
    pass "nixos-module.nix sets services.flakelets.services"
  else
    fail "nixos-module.nix must populate services.flakelets.services from scoutOutputs"
  fi
  if "$GREP" -q 'throw.*settings\.nix\|throw.*no settings' "$NS_MODULE"; then
    pass "nixos-module.nix throws on missing settings.nix for flakelet modules"
  else
    fail "nixos-module.nix must throw when a flakelet module is missing settings.nix"
  fi
else
  fail "nixos-module.nix not found at $NS_MODULE"
fi

finish_suite
