#!/usr/bin/env bash
# Module mode (v2): scout NixOS module must not set options like programs.steam.enable.
# Module lives in nix-scout subflake (nixScout.nixosModules.default) or legacy shim.
#
# Run from repo root:
#   modules/nix-scout/tests/module-mode.sh
set -euo pipefail

# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

echo "== module-mode restriction =="

# Resolve binary early so NIX_SCOUT_ROOT is set for scout_module_candidates.
_bin=""
_bin="$(resolve_nix_scout)" || true

found=0
while IFS= read -r MODULE; do
  [[ -z "$MODULE" ]] && continue
  if "$GREP" -qE 'programs\.steam|module-mode|cannot set NixOS options|system-wide options|nfb' "$MODULE"; then
    found=1
    pass "module documents/asserts nix-scout cannot set NixOS options ($MODULE)"
    break
  fi
done < <(scout_module_candidates)

if [[ "$found" -eq 0 ]]; then
  fail "nixScout.nixosModules.default (or shim) missing module-mode restriction comment/assertion"
fi

# v2: no v0id.scout.payloads manifest in module options.
manifest_hit=0
while IFS= read -r MODULE; do
  [[ -z "$MODULE" ]] && continue
  if "$GREP" -qE 'v0id\.scout\.payloads|options\.v0id\.scout\.payloads' "$MODULE"; then
    manifest_hit=1
    fail "module still defines v0id.scout.payloads manifest ($MODULE) — v2 uses modules/ drop-ins"
  fi
done < <(scout_module_candidates)

if [[ "$manifest_hit" -eq 0 ]]; then
  pass "no v0id.scout.payloads manifest in scout NixOS module"
fi

BIN=""
STRICT_BIN=""
if BIN="$(resolve_nix_scout)"; then
  STRICT_BIN="$(resolve_strict_nix_scout)" || STRICT_BIN="$BIN"
  run_capture "$BIN" --help
  HELP_TEXT="$CAPTURED_OUT$CAPTURED_ERR"
  if [[ "$HELP_TEXT" == *module-mode* || "$HELP_TEXT" == *nfb* || "$HELP_TEXT" == *'system-wide'* ]]; then
    pass "--help mentions module-mode / nfb / system-wide options"
  else
    fail "--help should mention module-mode or nfb for system-wide NixOS options"
  fi
  # Check flakelet mention on the strict (sibling-source) binary since the system
  # binary may lag until the next nixos-rebuild.
  run_capture "$STRICT_BIN" --help
  STRICT_HELP="$CAPTURED_OUT$CAPTURED_ERR"
  if [[ "$STRICT_HELP" == *flakelet* ]]; then
    pass "--help documents flakelet integration (switch fan-out)"
  else
    fail "--help should mention flakelet (switch fan-out for flakelet facets)"
  fi
else
  fail "nix-scout binary missing (help text for module-mode / nfb unimplemented)"
fi

# prebuiltModules are computed inside nixos-module.nix (not a host option).
# Derive root from env, binary, or sibling repo (subshell export of NIX_SCOUT_ROOT
# does not propagate back from resolve_nix_scout command substitution).
_ns_root=""
if [[ -n "${NIX_SCOUT_ROOT:-}" && -f "${NIX_SCOUT_ROOT}/nixos-module.nix" ]]; then
  _ns_root="$NIX_SCOUT_ROOT"
elif [[ -n "${BIN:-}" ]]; then
  _bin_root="$(cd "$(dirname "$BIN")/.." && pwd)"
  if [[ -f "${_bin_root}/nixos-module.nix" ]]; then
    _ns_root="$_bin_root"
  fi
fi
# Fallback: this is the nix-scout repo itself.
if [[ -z "$_ns_root" && -f "$REPO/nixos-module.nix" ]]; then
  _ns_root="$REPO"
fi
NS_MODULE="${_ns_root}/nixos-module.nix"
if [[ -f "$NS_MODULE" ]]; then
  if "$GREP" -q 'prebuiltModules' "$NS_MODULE" && "$GREP" -q 'readDir' "$NS_MODULE"; then
    pass "nixos-module.nix enumerates prebuiltModules via readDir"
  else
    fail "nixos-module.nix must readDir modulesDir into prebuiltModules ($NS_MODULE)"
  fi

  if "$GREP" -q 'systemPackages' "$NS_MODULE" && "$GREP" -q 'prebuiltModules' "$NS_MODULE"; then
    pass "nixos-module.nix includes prebuiltModules in environment.systemPackages"
  else
    fail "nixos-module.nix must add prebuiltModules to environment.systemPackages ($NS_MODULE)"
  fi

  if "$GREP" -q 'systemRebuild = true' "$NS_MODULE"; then
    pass "nixos-module.nix passes systemRebuild=true to scout module outputs"
  else
    fail "nixos-module.nix must pass systemRebuild=true when prebuilding scout modules"
  fi

  # v3: prebuild is optional (filterAttrs); flakelet-only modules are valid.
  if "$GREP" -q 'filterAttrs' "$NS_MODULE" && "$GREP" -q 'packages.*scout\|scout.*packages' "$NS_MODULE"; then
    pass "nixos-module.nix filters prebuiltModules (packages.scout optional)"
  else
    fail "nixos-module.nix should filterAttrs prebuiltModules — packages.scout is optional ($NS_MODULE)"
  fi

  # v3: flakelet integration — imports flakelet module and reads settings.nix.
  if "$GREP" -q 'flakelet\.nixosModules\.flakelet' "$NS_MODULE"; then
    pass "nixos-module.nix imports flakelet.nixosModules.flakelet"
  else
    fail "nixos-module.nix must import flakelet.nixosModules.flakelet ($NS_MODULE)"
  fi

  if "$GREP" -q 'settings\.nix\|settings-nix\|settingsFile' "$NS_MODULE"; then
    pass "nixos-module.nix reads settings.nix for flakelet registration"
  else
    fail "nixos-module.nix must import settings.nix for flakelet-enabled modules ($NS_MODULE)"
  fi

  if "$GREP" -q 'services\.flakelets' "$NS_MODULE"; then
    pass "nixos-module.nix sets services.flakelets"
  else
    fail "nixos-module.nix must set services.flakelets.services for auto-registered modules ($NS_MODULE)"
  fi
else
  fail "nixos-module.nix not found at ${_ns_root:-<empty>}/nixos-module.nix (cannot verify prebuiltModules option)"
fi

finish_suite
