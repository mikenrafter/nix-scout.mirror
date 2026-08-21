#!/usr/bin/env bash
# Flakelet integration contracts:
#   - scout-lib.sh exists and provides pin_gcroot
#   - apply-hm.sh / apply-env.sh self-detect and exit 0 when facet is absent
#   - apply-flakelet.sh self-detects via flake.nix grep and exit 0 when absent
#   - CLI _switch_module flat fan-out: pin_gcroot + apply-hm + apply-env + apply-flakelet
#   - nixos-module.nix imports flakelet and auto-registers via settings.nix
#
# Run from nix-scout root:
#   tests/flakelet.sh
set -euo pipefail

# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

echo "== flakelet integration =="

# ── lib/ scripts exist ────────────────────────────────────────────────────────
echo "-- lib/: scout-lib.sh, apply-hm.sh, apply-env.sh, apply-flakelet.sh exist --"
for script in scout-lib.sh apply-hm.sh apply-env.sh apply-flakelet.sh; do
  cand="$REPO/lib/$script"
  if [[ -f "$cand" ]]; then
    pass "lib/$script exists"
  else
    fail "lib/$script missing"
  fi
done

# ── scout-lib.sh: provides shared primitives ──────────────────────────────────
echo "-- scout-lib.sh: provides pin_gcroot and priv helpers --"
SCOUT_LIB=""
if SCOUT_LIB="$(resolve_scout_lib_script)"; then
  for fn in pin_gcroot _can_write _priv_mkdir _priv_ln_sfn _priv_nix_env; do
    if "$GREP" -q "$fn" "$SCOUT_LIB"; then
      pass "scout-lib.sh defines $fn"
    else
      fail "scout-lib.sh must define $fn"
    fi
  done
else
  fail "scout-lib.sh not found (resolve_scout_lib_script failed)"
fi

# ── apply-hm.sh / apply-env.sh: self-detect, no hard exit 1 on absent facet ──
echo "-- apply-hm.sh / apply-env.sh: self-detect (exit 0 when facet absent) --"
for script in apply-hm.sh apply-env.sh; do
  cand="$REPO/lib/$script"
  if [[ -f "$cand" ]]; then
    if "$GREP" -q 'exit 0' "$cand"; then
      pass "lib/$script has exit 0 self-detection path"
    else
      fail "lib/$script must exit 0 (no-op) when its store facet is absent"
    fi
    if "$GREP" -q 'scout-lib\.sh' "$cand"; then
      pass "lib/$script sources scout-lib.sh"
    else
      fail "lib/$script must source scout-lib.sh"
    fi
  else
    fail "lib/$script not found"
  fi
done

# ── apply-flakelet.sh: self-detects via flake.nix grep, calls flakelet update ─
echo "-- apply-flakelet.sh: self-detect + MOD_DIR arg + flakelet update --"
FLAKELET_SCRIPT="$REPO/lib/apply-flakelet.sh"
if [[ -f "$FLAKELET_SCRIPT" ]]; then
  if "$GREP" -q 'MOD_DIR' "$FLAKELET_SCRIPT"; then
    pass "apply-flakelet.sh accepts MOD_DIR argument"
  else
    fail "apply-flakelet.sh must accept MOD_DIR as second argument for self-detection"
  fi
  if "$GREP" -q 'exit 0' "$FLAKELET_SCRIPT"; then
    pass "apply-flakelet.sh exits 0 when module has no flakelet facet"
  else
    fail "apply-flakelet.sh must exit 0 (no-op) when flake.nix has no flakelets"
  fi
  if "$GREP" -q 'flakelet update' "$FLAKELET_SCRIPT"; then
    pass "apply-flakelet.sh calls 'flakelet update'"
  else
    fail "apply-flakelet.sh must call 'sudo flakelet update \$NAME'"
  fi
else
  fail "apply-flakelet.sh not found at $FLAKELET_SCRIPT"
fi

# ── CLI: _switch_module flat fan-out ─────────────────────────────────────────
echo "-- CLI: _switch_module flat fan-out with pin_gcroot --"
BIN=""
if BIN="$(resolve_strict_nix_scout)"; then
  if "$GREP" -q 'pin_gcroot' "$BIN"; then
    pass "bin/nix-scout calls pin_gcroot"
  else
    fail "bin/nix-scout must call pin_gcroot after a successful nix build"
  fi
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
