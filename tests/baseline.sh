#!/usr/bin/env bash
# baseline facet contracts:
#   - new-module.sh scaffolds a `# baseline` marker inside the nix-scout-gated
#     block (never inside the `// { # flakelet }` merge)
#   - nix-scout new <name> baseline emits a working NixOS-module stub
#   - nixos-module.nix collects out.baseline into baselineModules and merges
#     it into its own `imports` — the only place baseline is ever acted on
#   - bin/nix-scout: usage()/_facet_tags() know about baseline (informational
#     only); _switch_module never references baseline (switch must never
#     build/apply it)
#
# Run from nix-scout root:
#   tests/baseline.sh
set -euo pipefail

# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

echo "== baseline facet =="

scout_isolate
cleanup() { "$RM" -rf "$WORKDIR"; }
trap cleanup EXIT

export NIX_SCOUT_MODULES="$WORKDIR/modules"
"$MKDIR" -p "$NIX_SCOUT_MODULES"
scout_write_paths_file "$NIX_SCOUT_PATHS_FILE"

NEW_LIB="$REPO/lib/new-module.sh"
if [[ ! -f "$NEW_LIB" ]]; then
  fail "lib/new-module.sh missing"
  finish_suite
fi
pass "found new-module.sh at $NEW_LIB"

echo "-- new-module.sh accepts 'baseline' as a facet --"
run_capture bash "$NEW_LIB" "$NIX_SCOUT_MODULES" baseline-only baseline
if [[ "$CAPTURED_RC" -eq 0 ]]; then
  pass "new-module.sh baseline-only scaffold exit 0"
else
  fail "new-module.sh baseline-only scaffold failed: $(printf %q "$CAPTURED_ERR$CAPTURED_OUT")"
fi

flake="$NIX_SCOUT_MODULES/baseline-only/flake.nix"
if [[ -f "$flake" ]]; then
  pass "created flake.nix for baseline-only module"
else
  fail "missing flake.nix for baseline-only module"
  finish_suite
fi

for token in '# baseline' 'baseline = ' 'optionalAttrs (inputs ? nix-scout)'; do
  if "$GREP" -qF "$token" "$flake"; then
    pass "flake.nix contains $token"
  else
    fail "flake.nix missing $token"
  fi
done

# baseline must be emitted *inside* the `lib.optionalAttrs (inputs ? nix-scout) ( ... )`
# block, not after the `) // {` merge that starts the flakelet section.
gate_line="$("$GREP" -n 'optionalAttrs (inputs ? nix-scout)' "$flake" | "$HEAD" -n1 | cut -d: -f1)"
merge_line="$("$GREP" -n ') // {' "$flake" | "$HEAD" -n1 | cut -d: -f1)"
baseline_line="$("$GREP" -n 'baseline = ' "$flake" | "$HEAD" -n1 | cut -d: -f1)"
if [[ -n "$gate_line" && -n "$merge_line" && -n "$baseline_line" ]] \
  && (( baseline_line > gate_line && baseline_line < merge_line )); then
  pass "baseline stub sits inside the inputs?nix-scout-gated block, before the flakelet merge"
else
  fail "baseline stub must be inside lib.optionalAttrs (inputs ? nix-scout) ( ... ), before ) // { # flakelet }"
fi

echo "-- baseline-only leaves empty scout/home/flakelet sections --"
if "$GREP" -q '# scout' "$flake" && "$GREP" -q '# home' "$flake" && "$GREP" -q '# flakelet' "$flake"; then
  pass "all facet markers present even when only baseline requested"
else
  fail "all facet section markers must always be present"
fi
if "$GREP" -qE '[^#]*packages\.' "$flake"; then
  fail "baseline-only scaffold should not emit a packages.<system>.scout stub"
else
  pass "baseline-only scaffold has no packages.<system>.scout stub"
fi
if "$GREP" -q 'flakelets\.' "$flake"; then
  fail "baseline-only scaffold should not emit a flakelets stub"
else
  pass "baseline-only scaffold has no flakelets stub"
fi
if [[ -f "$NIX_SCOUT_MODULES/baseline-only/settings.nix" ]]; then
  fail "settings.nix must not be written for a baseline-only module"
else
  pass "no settings.nix written for baseline-only module"
fi

echo "-- all facets together (scout home flakelet baseline) --"
run_capture bash "$NEW_LIB" "$NIX_SCOUT_MODULES" all-facets scout home flakelet baseline
if [[ "$CAPTURED_RC" -eq 0 ]]; then
  pass "all-facets scaffold exit 0"
else
  fail "all-facets scaffold failed: $(printf %q "$CAPTURED_ERR$CAPTURED_OUT")"
fi
all_flake="$NIX_SCOUT_MODULES/all-facets/flake.nix"
for token in '# scout' '# home' '# baseline' '# flakelet' 'packages.' 'home-files' 'baseline = ' 'flakelets.default'; do
  if "$GREP" -qF "$token" "$all_flake"; then
    pass "all-facets flake.nix contains $token"
  else
    fail "all-facets flake.nix missing $token"
  fi
done

echo "-- unknown facet still rejected --"
run_capture bash "$NEW_LIB" "$NIX_SCOUT_MODULES" bogus-module notafacet
if [[ "$CAPTURED_RC" -ne 0 ]]; then
  pass "unknown facet rejected"
else
  fail "unknown facet should be rejected"
fi
if [[ "$CAPTURED_ERR" == *baseline* ]]; then
  pass "unknown-facet error message lists baseline as supported"
else
  fail "unknown-facet error message should mention baseline as a supported facet"
fi

echo "-- nixos-module.nix: collects out.baseline into imports --"
NS_MODULE="$REPO/nixos-module.nix"
if [[ -f "$NS_MODULE" ]]; then
  if "$GREP" -q 'out ? baseline' "$NS_MODULE" && "$GREP" -q 'out\.baseline' "$NS_MODULE"; then
    pass "nixos-module.nix filters scoutOutputs on out ? baseline and reads out.baseline"
  else
    fail "nixos-module.nix must filter scoutOutputs for out ? baseline and collect out.baseline"
  fi
  if "$GREP" -q 'baselineModules' "$NS_MODULE"; then
    pass "nixos-module.nix defines baselineModules"
  else
    fail "nixos-module.nix must define a baselineModules binding"
  fi
  if "$GREP" -qE 'imports = \[ flakelet\.nixosModules\.flakelet \] \+\+ baselineModules' "$NS_MODULE"; then
    pass "nixos-module.nix merges baselineModules into its own imports"
  else
    fail "nixos-module.nix's imports must be [ flakelet.nixosModules.flakelet ] ++ baselineModules"
  fi
else
  fail "nixos-module.nix not found at $NS_MODULE"
fi

echo "-- bin/nix-scout: usage() and _facet_tags() know about baseline --"
BIN="$REPO/bin/nix-scout"
if [[ -f "$BIN" ]]; then
  if "$GREP" -q 'baseline' "$BIN"; then
    pass "bin/nix-scout mentions baseline somewhere (usage/_facet_tags/completions)"
  else
    fail "bin/nix-scout should document/detect the baseline facet"
  fi

  # _facet_tags() is allowed (expected) to mention baseline — it's purely informational.
  facet_tags_body="$(awk '/^_facet_tags\(\)/{flag=1} flag{print} /^\}/{if(flag){exit}}' "$BIN")"
  if [[ "$facet_tags_body" == *baseline* ]]; then
    pass "_facet_tags() detects baseline for 'nix-scout list' (informational only)"
  else
    fail "_facet_tags() should tag baseline for 'nix-scout list'"
  fi

  # _switch_module() must NEVER reference baseline — switch must not build/apply it.
  switch_module_body="$(awk '/^_switch_module\(\)/{flag=1} flag{print} /^\}/{if(flag){exit}}' "$BIN")"
  if [[ -z "$switch_module_body" ]]; then
    fail "could not extract _switch_module() body from bin/nix-scout for inspection"
  elif [[ "$switch_module_body" == *baseline* ]]; then
    fail "_switch_module() must not reference baseline — 'nix-scout switch' must never build/apply it"
  else
    pass "_switch_module() has no baseline references — switch never touches the baseline facet"
  fi
else
  fail "bin/nix-scout not found at $BIN"
fi

echo "-- completions: baseline offered as a 'new' facet --"
STRICT_BIN="$(resolve_strict_nix_scout)" || STRICT_BIN="$BIN"
for shell in fish bash zsh; do
  run_capture "$STRICT_BIN" completions "$shell"
  if [[ "$CAPTURED_OUT" == *baseline* ]]; then
    pass "$shell completions offer baseline as a new-facet"
  else
    fail "$shell completions should offer baseline as a new-facet"
  fi
done

echo "-- README documents the baseline facet --"
if "$GREP" -qF 'baseline' "$REPO/README.md"; then
  pass "README.md documents baseline"
else
  fail "README.md must document the baseline facet"
fi

finish_suite
