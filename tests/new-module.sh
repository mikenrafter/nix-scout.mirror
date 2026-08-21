#!/usr/bin/env bash
# nix-scout new: scaffold facet-separated scout modules + dummy lock + rebuild hint.
set -euo pipefail

# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

echo "== nix-scout new =="

scout_isolate
cleanup() { "$RM" -rf "$WORKDIR"; }
trap cleanup EXIT

# Writable modules dir for scaffolds (do not write into repo fixtures).
export NIX_SCOUT_MODULES="$WORKDIR/modules"
"$MKDIR" -p "$NIX_SCOUT_MODULES"
scout_write_paths_file "$NIX_SCOUT_PATHS_FILE"

BIN=""
STRICT_BIN=""
if BIN="$(resolve_nix_scout)"; then
  pass "resolved nix-scout at $BIN"
  STRICT_BIN="$(resolve_strict_nix_scout)"
else
  fail "nix-scout binary missing"
  finish_suite
fi

NEW_LIB="$REPO/lib/new-module.sh"
if [[ ! -f "$NEW_LIB" ]]; then
  fail "lib/new-module.sh missing"
  finish_suite
fi
pass "found new-module.sh at $NEW_LIB"

echo "-- scaffold all facets --"
run_capture bash "$NEW_LIB" "$NIX_SCOUT_MODULES" example-module flakelet scout home
if [[ "$CAPTURED_RC" -ne 0 ]]; then
  fail "new-module.sh all-facets failed: $(printf %q "$CAPTURED_ERR$CAPTURED_OUT")"
else
  pass "new-module.sh all-facets exit 0"
fi
if [[ "$CAPTURED_OUT" == *nixos-rebuild* ]] || [[ "$CAPTURED_OUT" == *"full"* && "$CAPTURED_OUT" == *rebuild* ]]; then
  pass "stdout mentions full rebuild for flakelet"
else
  fail "stdout must mention full rebuild; got $(printf %q "$CAPTURED_OUT")"
fi

mod="$NIX_SCOUT_MODULES/example-module"
for f in flake.nix flake.lock settings.nix; do
  if [[ -f "$mod/$f" ]]; then
    pass "created $f"
  else
    fail "missing $f in scaffold"
  fi
done

flake="$mod/flake.nix"
for token in '# scout' '# home' '# flakelet' 'optionalAttrs (inputs ? nix-scout)' 'flakelets.default' 'packages.' 'home-files'; do
  if "$GREP" -qF "$token" "$flake"; then
    pass "flake.nix contains $token"
  else
    fail "flake.nix missing $token"
  fi
done

lock="$mod/flake.lock"
if "$GREP" -q 'sha256-0000000000000000000000000000000000000000000=' "$lock" \
  && "$GREP" -q 'nix-scout_not-real-lockfile' "$lock"; then
  pass "dummy flake.lock uses zero narHash + nix-scout_not-real-lockfile"
else
  fail "dummy flake.lock pins incorrect; got $(printf %q "$("$HEAD" -c 400 "$lock")")"
fi

echo "-- scout+home leaves empty flakelet section --"
run_capture bash "$NEW_LIB" "$NIX_SCOUT_MODULES" scout-home-only scout home
if [[ "$CAPTURED_RC" -eq 0 ]]; then
  pass "scout+home scaffold exit 0"
else
  fail "scout+home scaffold failed"
fi
sh_flake="$NIX_SCOUT_MODULES/scout-home-only/flake.nix"
if "$GREP" -q '# flakelet' "$sh_flake" && ! "$GREP" -q 'flakelets\.' "$sh_flake"; then
  pass "scout+home keeps empty # flakelet section"
else
  fail "scout+home should keep empty flakelet comment only"
fi
if [[ -f "$NIX_SCOUT_MODULES/scout-home-only/settings.nix" ]]; then
  fail "settings.nix must not be written without flakelet facet"
else
  pass "no settings.nix without flakelet facet"
fi

echo "-- refuse overwrite --"
run_capture bash "$NEW_LIB" "$NIX_SCOUT_MODULES" example-module scout
if [[ "$CAPTURED_RC" -ne 0 ]]; then
  pass "refuses to overwrite existing module"
else
  fail "should refuse overwrite"
fi

echo "-- CLI wires new subcommand --"
if "$GREP" -q 'new-module.sh' "$REPO/bin/nix-scout"; then
  pass "CLI references new-module.sh"
else
  fail "CLI must implement nix-scout new"
fi
run_capture env NIX_SCOUT_PATHS_FILE="$NIX_SCOUT_PATHS_FILE" "$STRICT_BIN" --help
if [[ "$CAPTURED_OUT$CAPTURED_ERR" == *new* ]]; then
  pass "--help mentions new"
else
  fail "--help should mention new"
fi

echo "-- completions: switch tokens have no escaped spaces --"
for shell in fish bash zsh; do
  run_capture "$STRICT_BIN" completions "$shell"
  COMP="$CAPTURED_OUT"
  if [[ "$COMP" == *switch* && "$COMP" == *new* ]]; then
    pass "completions $shell include switch and new"
  else
    fail "completions $shell should offer switch and new"
  fi
done
run_capture "$STRICT_BIN" completions fish
COMP="$CAPTURED_OUT"
if [[ "$COMP" == *__nix_scout_module_completions* ]] && [[ "$COMP" == *"string replace"* ]]; then
  pass "fish completions use name\\tdescription transform for switch"
else
  fail "completions must not feed raw \`nix-scout list\` lines to -a"
fi
if [[ "$COMP" == *new* && "$COMP" == *flakelet* ]]; then
  pass "completions include new + facets"
else
  fail "completions should offer new and facet names"
fi
run_capture "$STRICT_BIN" completions bash
if [[ "$CAPTURED_OUT" == *scout\ home\ flakelet* || "$CAPTURED_OUT" == *'scout home flakelet'* ]]; then
  pass "bash completions offer new facets"
else
  fail "bash completions should offer facet names for new"
fi

finish_suite
