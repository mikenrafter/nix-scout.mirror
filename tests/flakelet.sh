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
  # Doctor may mention the command in fix hints; switch must not call it inline.
  if "$GREP" -n 'sudo flakelet update' "$BIN" | "$GREP" -vE 'printf|Fix:|re-run' | "$GREP" -q .; then
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
  if "$GREP" -q 'flakelet-access\.sh grant' "$NS_MODULE"; then
    pass "nixos-module.nix activation grants modules-path access via flakelet-access.sh"
  else
    fail "nixos-module.nix must call flakelet-access.sh grant from nix-scout-flakelet-access"
  fi
  if "$GREP" -q 'extraGroups.*users\|extraGroups = \[ "users" \]' "$NS_MODULE"; then
    fail "nixos-module.nix must not rely on flakelet extraGroups=users (no initgroups)"
  else
    pass "nixos-module.nix does not rely on supplementary users group for flakelet"
  fi
else
  fail "nixos-module.nix not found at $NS_MODULE"
fi

# ── nixos-module.nix: scout-module input threading (converged eval/switch) ──
echo "-- nixos-module.nix: threads parent inputs into scout-module eval --"
if [[ -f "$NS_MODULE" ]]; then
  if "$GREP" -q 'providedOutputsArgs' "$NS_MODULE"; then
    fail "nixos-module.nix must not hardcode a fixed providedOutputsArgs set — pass through the parent's own inputs instead"
  else
    pass "nixos-module.nix does not hardcode a fixed providedOutputsArgs set"
  fi
  if "$GREP" -q 'unsatisfiedNames\|requiredArgs' "$NS_MODULE"; then
    fail "nixos-module.nix must not throw on 'unsatisfied' required args — every module now receives the full parent inputs attrset"
  else
    pass "nixos-module.nix does not throw on unsatisfied required args"
  fi
  if "$GREP" -q 'm\.outputs (inputs //' "$NS_MODULE"; then
    pass "nixos-module.nix calls m.outputs with the parent's inputs merged in"
  else
    fail "nixos-module.nix must call m.outputs (inputs // { nix-scout = ...; systemRebuild = true; }) so eval-time and switch-time converge"
  fi
  if "$GREP" -q '{ nixScout, parent, modulesRel, flakelet, inputs }' "$NS_MODULE"; then
    pass "nixos-module.nix constructor accepts the host's inputs attrset"
  else
    fail "nixos-module.nix constructor must accept 'inputs' (the host flake's own resolved inputs)"
  fi
else
  fail "nixos-module.nix not found at $NS_MODULE"
fi

# ── flake.nix: nixosModule threads hostInputs through ───────────────────────
echo "-- flake.nix: nixosModule constructor forwards hostInputs --"
NS_FLAKE="$REPO/flake.nix"
if [[ -f "$NS_FLAKE" ]]; then
  if "$GREP" -q 'nixosModule = parent: modulesRel: hostInputs:' "$NS_FLAKE"; then
    pass "flake.nix's nixosModule takes parent, modulesRel, and hostInputs"
  else
    fail "flake.nix's nixosModule must be a 3-arg curried function: parent modulesRel hostInputs"
  fi
  if "$GREP" -q 'inputs = hostInputs' "$NS_FLAKE"; then
    pass "flake.nix forwards hostInputs into nixos-module.nix as 'inputs'"
  else
    fail "flake.nix must forward hostInputs into nixos-module.nix's 'inputs' arg"
  fi
else
  fail "flake.nix not found at $NS_FLAKE"
fi

# ── flakelet-access.sh: primary-gid-only grant/check ───────────────────────
echo "-- flakelet-access.sh: grant/check contracts --"
ACCESS_SCRIPT="$REPO/lib/flakelet-access.sh"
if [[ -f "$ACCESS_SCRIPT" ]]; then
  if "$GREP" -q 'o+x\|o+rx' "$ACCESS_SCRIPT"; then
    pass "flakelet-access.sh grants other-execute / other-rx"
  else
    fail "flakelet-access.sh must chmod o+x/o+rx for primary-gid-only access"
  fi
  if "$GREP" -q 'flakelet_access_grant_tree\|flakelet_access_check_tree' "$ACCESS_SCRIPT"; then
    pass "flakelet-access.sh defines grant_tree and check_tree"
  else
    fail "flakelet-access.sh must define flakelet_access_grant_tree and check_tree"
  fi
  if "$GREP" -q 'initgroups' "$ACCESS_SCRIPT"; then
    pass "flakelet-access.sh documents flakelet missing initgroups"
  else
    fail "flakelet-access.sh must document why supplementary groups are ineffective"
  fi

  # Functional: 750 home-like ancestor blocks other/foreign primary-gid access.
  tmp="$(mktemp -d)"
  chmod 755 "$tmp"
  mkdir -p "$tmp/home/repo/modules/svc"
  chmod 755 "$tmp/home" "$tmp/home/repo" "$tmp/home/repo/modules" "$tmp/home/repo/modules/svc"
  chmod 750 "$tmp/home"
  if bash "$ACCESS_SCRIPT" check "$tmp/home/repo/modules" nobody svc >/dev/null 2>&1; then
    fail "flakelet-access check must fail when an ancestor is mode 750 (no other-x)"
  else
    pass "flakelet-access check detects 750 ancestor as blocked"
  fi
  # Grant as current user (we own tmp) — chmod without sudo.
  bash "$ACCESS_SCRIPT" grant "$tmp/home/repo/modules" svc
  if bash "$ACCESS_SCRIPT" check "$tmp/home/repo/modules" nobody svc >/dev/null 2>&1; then
    pass "flakelet-access grant repairs other-x/rx so check passes"
  else
    fail "flakelet-access grant should make check pass on owned temp tree"
  fi
  rm -rf "$tmp"
else
  fail "flakelet-access.sh not found at $ACCESS_SCRIPT"
fi

# ── CLI doctor: modules-path mutation + last_error health ──────────────────
echo "-- CLI doctor: modules-path access + last_error parsing --"
BIN=""
if BIN="$(resolve_strict_nix_scout)"; then
  if "$GREP" -q 'flakelet_access_grant_tree\|flakelet-access\.sh' "$BIN"; then
    pass "bin/nix-scout doctor uses flakelet-access grant/check"
  else
    fail "bin/nix-scout doctor must use flakelet-access.sh for path mutation"
  fi
  if "$GREP" -q 'last_error' "$BIN"; then
    pass "bin/nix-scout doctor inspects last_error from flakelet status"
  else
    fail "bin/nix-scout doctor must detect services via last_error (not .state)"
  fi
  if "$GREP" -q 'sudo -u .* test -x' "$BIN"; then
    fail "bin/nix-scout doctor must not use sudo -u test -x (misleading with initgroups)"
  else
    pass "bin/nix-scout doctor does not use misleading sudo -u traverse check"
  fi
else
  fail "nix-scout binary not found (doctor contracts unimplemented)"
fi

finish_suite
