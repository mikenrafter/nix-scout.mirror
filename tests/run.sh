#!/usr/bin/env bash
# Run all nix-scout contract suites. Continue after exit 1 (contract red);
# abort on exit 2 (harness).
#
# From nix-scout root:
#   tests/run.sh
#
# Static suites (grep-only, no build needed):
#   module-mode.sh  path-session.sh  activation-clear.sh  flakelet.sh  baseline.sh
#
# Integration suites (require nix-scout binary or nix build):
#   cli.sh  hm-activate-files.sh  materialize.sh  profile-gcroots.sh  update-module.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

suites=(
  module-mode.sh
  path-session.sh
  activation-clear.sh
  flakelet.sh
  baseline.sh
  cli.sh
  new-module.sh
  completions.sh
  hm-activate-files.sh
  materialize.sh
  profile-gcroots.sh
  update-module.sh
)

failed=0
for s in "${suites[@]}"; do
  echo
  echo "######## $s ########"
  set +e
  bash "$DIR/$s" 2>&1
  rc=$?
  set -e
  if [[ "$rc" -eq 2 ]]; then
    echo "Harness failure in $s (exit 2)" >&2
    exit 2
  fi
  if [[ "$rc" -ne 0 ]]; then
    failed=$((failed + 1))
    echo "SUITE RED: $s (exit $rc)"
  else
    echo "SUITE GREEN: $s"
  fi
done

echo
if [[ "$failed" -eq 0 ]]; then
  echo "All nix-scout suites passed."
  exit 0
fi
echo "$failed suite(s) failed." >&2
exit 1
