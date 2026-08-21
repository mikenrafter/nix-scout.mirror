#!/usr/bin/env bash
# Completions contract: bash/zsh/fish subcommands, installPhase paths, apply-env wiring.
set -euo pipefail

# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

echo "== nix-scout completions =="

STRICT_BIN=""
if STRICT_BIN="$(resolve_strict_nix_scout)"; then
  pass "resolved nix-scout at $STRICT_BIN"
else
  fail "nix-scout binary missing"
  finish_suite
fi

for shell in fish bash zsh; do
  run_capture "$STRICT_BIN" completions "$shell"
  if [[ "$CAPTURED_RC" -eq 0 && -n "$CAPTURED_OUT" ]]; then
    pass "completions $shell exits 0 with output"
  else
    fail "completions $shell failed (rc=$CAPTURED_RC)"
  fi
done

run_capture "$STRICT_BIN" completions fish
FISH="$CAPTURED_OUT"
for token in list new switch status clear doctor completions help; do
  if [[ "$FISH" == *"$token"* ]]; then
    pass "fish completions mention $token"
  else
    fail "fish completions missing subcommand $token"
  fi
done

run_capture "$STRICT_BIN" completions bash
BASH_COMP="$CAPTURED_OUT"
if [[ "$BASH_COMP" == *complete\ -F\ _nix_scout* && "$BASH_COMP" == *switch* ]]; then
  pass "bash completion defines _nix_scout function"
else
  fail "bash completion script incomplete"
fi
if [[ "$BASH_COMP" == *fish\ bash\ zsh* || "$BASH_COMP" == *'fish bash zsh'* ]]; then
  pass "bash completions subcommand offers fish bash zsh"
else
  fail "bash completions subcommand missing shell list"
fi

run_capture "$STRICT_BIN" completions zsh
ZSH_COMP="$CAPTURED_OUT"
if [[ "$ZSH_COMP" == *#compdef\ nix-scout* && "$ZSH_COMP" == *site-functions* ]]; then
  pass "zsh completion is compdef with site-functions comment"
else
  fail "zsh completion script incomplete"
fi
if [[ "$ZSH_COMP" == *scout\ home\ flakelet* ]]; then
  pass "zsh completions offer new facets"
else
  fail "zsh completions missing facet names"
fi

run_capture "$STRICT_BIN" completions nosuch
if [[ "$CAPTURED_RC" -ne 0 ]]; then
  pass "completions rejects unknown shell"
else
  fail "completions should fail for unknown shell"
fi

echo "-- flake.nix installPhase paths --"
FLAKE="$REPO/flake.nix"
for path in \
  'share/bash-completion/completions/nix-scout' \
  'share/zsh/site-functions/_nix-scout' \
  'share/fish/vendor_completions.d/nix-scout.fish'; do
  if "$GREP" -q "$path" "$FLAKE"; then
    pass "flake.nix installs $path"
  else
    fail "flake.nix must install $path"
  fi
done

echo "-- apply-env.sh shell snippets --"
APPLY="$REPO/lib/apply-env.sh"
for token in \
  'bash/nix-scout.bash' \
  'zsh/nix-scout.zsh' \
  'fish/vendor_completions.d' \
  'XDG_DATA_DIRS' \
  'site-functions'; do
  if "$GREP" -q "$token" "$APPLY"; then
    pass "apply-env.sh references $token"
  else
    fail "apply-env.sh missing $token"
  fi
done

echo "-- cmd_clear removes bash/zsh snippets --"
if "$GREP" -q 'bash/nix-scout.bash' "$REPO/bin/nix-scout" \
  && "$GREP" -q 'zsh/nix-scout.zsh' "$REPO/bin/nix-scout"; then
  pass "cmd_clear removes bash and zsh conf snippets"
else
  fail "cmd_clear must remove bash/nix-scout.bash and zsh/nix-scout.zsh"
fi

echo "-- nixos-module HM bash/zsh source hooks --"
NS="$REPO/nixos-module.nix"
if "$GREP" -q 'bash/nix-scout.bash' "$NS"; then
  pass "nixos-module sources bash snippet via programs.bash"
else
  fail "nixos-module must source bash/nix-scout.bash"
fi
if "$GREP" -q 'zsh/nix-scout.zsh' "$NS"; then
  pass "nixos-module sources zsh snippet via programs.zsh"
else
  fail "nixos-module must source zsh/nix-scout.zsh"
fi

finish_suite
