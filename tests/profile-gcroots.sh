#!/usr/bin/env bash
# Dedicated nix-scout profile + extra gc-roots (v2).
# switch scans modules/ for profile-type scouts; config-only home-files scouts get gc-roots.
#
# Run from repo root:
#   modules/nix-scout/tests/profile-gcroots.sh
set -euo pipefail

# shellcheck source=_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

require_nix

echo "== profile + gc-roots (v2) =="

scout_isolate
cleanup() { "$RM" -rf "$WORKDIR"; }
trap cleanup EXIT

echo "-- default path contracts --"
# Resolve binary first so NIX_SCOUT_ROOT is set for scout_module_candidates.
_bin=""
_bin="$(resolve_nix_scout)" || true

found_defaults=0
while IFS= read -r cand; do
  [[ -z "$cand" ]] && continue
  if "$GREP" -q '/nix/var/nix/profiles/per-user' "$cand" \
    && "$GREP" -q 'nix-scout' "$cand"; then
    found_defaults=1
    pass "default profile path referenced in $cand"
    break
  fi
done < <(scout_module_candidates; [[ -n "${NIX_SCOUT_ROOT:-}" ]] && printf '%s\n' "${NIX_SCOUT_ROOT}/bin/nix-scout" || true)

if [[ "$found_defaults" -eq 0 ]]; then
  fail "default profile /nix/var/nix/profiles/per-user/\$USER/nix-scout not implemented (no module/CLI source)"
fi

found_gc=0
while IFS= read -r cand; do
  [[ -z "$cand" ]] && continue
  if "$GREP" -q '/nix/var/nix/gcroots/per-user' "$cand"; then
    found_gc=1
    pass "default gc-roots path referenced in $cand"
    break
  fi
done < <(scout_module_candidates; [[ -n "${NIX_SCOUT_ROOT:-}" ]] && printf '%s\n' "${NIX_SCOUT_ROOT}/bin/nix-scout" || true)

if [[ "$found_gc" -eq 0 ]]; then
  fail "default gc-roots /nix/var/nix/gcroots/per-user/\$USER/nix-scout/ not implemented"
fi

BIN=""
if ! BIN="$(resolve_nix_scout)"; then
  fail "nix-scout binary missing (profile switch/status/clear unimplemented)"
  fail "program payload install into dedicated profile not testable (binary missing)"
  fail "config-only nix-scout gc-root not testable (binary missing)"
  fail "status/clear empty-after-clear not testable (binary missing)"
  assert_default_profile_untouched "did not touch default profile (binary missing; sentinel intact)"
  finish_suite
fi

FIXTURE_FLAKE="$TESTS/fixtures/probe-program"
echo "-- build probe program payload --"
run_capture "$NIX" build --no-link --print-out-paths --no-write-lock-file \
  "${FIXTURE_FLAKE}#packages.x86_64-linux.default"
if [[ "$CAPTURED_RC" -ne 0 ]]; then
  echo "FAIL: probe fixture failed to build (harness): $(printf %q "$CAPTURED_ERR")" >&2
  exit 2
fi
PROBE="${CAPTURED_OUT%%$'\n'*}"
if [[ ! -x "$PROBE/bin/scout-probe" ]]; then
  echo "FAIL: probe fixture missing bin/scout-probe (harness)" >&2
  exit 2
fi
pass "probe payload at $PROBE"

echo "-- switch profile-type store path into dedicated profile --"
run_capture env \
  HOME="$HOME" \
  NIX_SCOUT_PATHS_FILE="$NIX_SCOUT_PATHS_FILE" \
  NIX_SCOUT_PROFILE="$NIX_SCOUT_PROFILE" \
  NIX_SCOUT_GCROOTS="$NIX_SCOUT_GCROOTS" \
  "$BIN" switch "$PROBE"
if [[ "$CAPTURED_RC" -eq 0 ]]; then
  pass "nix-scout switch <program-store-path> exit 0"
else
  run_capture env \
    HOME="$HOME" \
    NIX_SCOUT_MODULES="$NIX_SCOUT_MODULES" \
    NIX_SCOUT_PARENT="$NIX_SCOUT_PARENT" \
    NIX_SCOUT_PROFILE="$NIX_SCOUT_PROFILE" \
    NIX_SCOUT_GCROOTS="$NIX_SCOUT_GCROOTS" \
    "$BIN" switch "${FIXTURE_FLAKE}#packages.x86_64-linux.default"
  if [[ "$CAPTURED_RC" -eq 0 ]]; then
    pass "nix-scout switch <flake-installable> exit 0"
  else
    fail "nix-scout switch of a program payload failed (rc=$CAPTURED_RC err=$(printf %q "$CAPTURED_ERR"))"
  fi
fi

PROFILE_BIN=""
for cand in \
  "$NIX_SCOUT_PROFILE/bin/scout-probe" \
  "$NIX_SCOUT_PROFILE/scout-probe"; do
  if [[ -e "$cand" ]]; then
    PROFILE_BIN="$cand"
    break
  fi
done
if [[ -z "$PROFILE_BIN" ]]; then
  PROFILE_BIN="$("$FIND" "$NIX_SCOUT_PROFILE" -name 'scout-probe' -type f -o -name 'scout-probe' -type l 2>/dev/null | "$HEAD" -n 1 || true)"
fi
if [[ -n "$PROFILE_BIN" && -e "$PROFILE_BIN" ]]; then
  pass "dedicated profile bin contains scout-probe ($PROFILE_BIN)"
else
  fail "dedicated profile $NIX_SCOUT_PROFILE does not contain scout-probe after switch"
fi

assert_default_profile_untouched "switch did not modify ~/.nix-profile / default nix-env profile"

echo "-- status lists live payloads --"
run_capture env \
  HOME="$HOME" \
  NIX_SCOUT_PATHS_FILE="$NIX_SCOUT_PATHS_FILE" \
  NIX_SCOUT_PROFILE="$NIX_SCOUT_PROFILE" \
  NIX_SCOUT_GCROOTS="$NIX_SCOUT_GCROOTS" \
  "$BIN" status
STATUS_TEXT="$CAPTURED_OUT$CAPTURED_ERR"
if [[ "$CAPTURED_RC" -eq 0 && ( "$STATUS_TEXT" == *scout-probe* || "$STATUS_TEXT" == *probe* ) ]]; then
  pass "nix-scout status prints live program payload name"
else
  fail "nix-scout status should list live payloads; rc=$CAPTURED_RC out=$(printf %q "$CAPTURED_OUT")"
fi

echo "-- config-only nix-scout module gets a gc-root --"
run_capture env \
  HOME="$HOME" \
  XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
  NIX_SCOUT_PATHS_FILE="$NIX_SCOUT_PATHS_FILE" \
  NIX_SCOUT_PROFILE="$NIX_SCOUT_PROFILE" \
  NIX_SCOUT_GCROOTS="$NIX_SCOUT_GCROOTS" \
  "$BIN" switch nix-scout
if [[ "$CAPTURED_RC" -eq 0 ]]; then
  pass "nix-scout switch nix-scout exit 0"
else
  fail "nix-scout switch nix-scout failed (rc=$CAPTURED_RC err=$(printf %q "$CAPTURED_ERR"))"
fi

gc_hit=""
if [[ -d "$NIX_SCOUT_GCROOTS" ]]; then
  gc_hit="$("$FIND" "$NIX_SCOUT_GCROOTS" -mindepth 1 2>/dev/null | "$HEAD" -n 1 || true)"
fi
if [[ -n "$gc_hit" ]]; then
  pass "nix-scout scout module created extra gc-root under NIX_SCOUT_GCROOTS ($gc_hit)"
else
  fail "config-only home-files scout should leave a gc-root under $NIX_SCOUT_GCROOTS"
fi

run_capture env \
  HOME="$HOME" \
  NIX_SCOUT_PATHS_FILE="$NIX_SCOUT_PATHS_FILE" \
  NIX_SCOUT_PROFILE="$NIX_SCOUT_PROFILE" \
  NIX_SCOUT_GCROOTS="$NIX_SCOUT_GCROOTS" \
  "$BIN" status
if [[ "$CAPTURED_OUT$CAPTURED_ERR" == *nix-scout* ]]; then
  pass "status lists nix-scout among live payloads"
else
  fail "status should mention nix-scout after switch; got $(printf %q "$CAPTURED_OUT")"
fi

echo "-- clear empties profile + scout gc-roots --"
run_capture env \
  HOME="$HOME" \
  NIX_SCOUT_PATHS_FILE="$NIX_SCOUT_PATHS_FILE" \
  NIX_SCOUT_PROFILE="$NIX_SCOUT_PROFILE" \
  NIX_SCOUT_GCROOTS="$NIX_SCOUT_GCROOTS" \
  "$BIN" clear
if [[ "$CAPTURED_RC" -eq 0 ]]; then
  pass "nix-scout clear exit 0"
else
  fail "nix-scout clear failed (rc=$CAPTURED_RC err=$(printf %q "$CAPTURED_ERR"))"
fi

still_probe="$("$FIND" "$NIX_SCOUT_PROFILE" -name 'scout-probe' 2>/dev/null | "$HEAD" -n 1 || true)"
if [[ -z "$still_probe" ]]; then
  pass "clear removed program from dedicated profile"
else
  fail "clear left scout-probe in profile ($still_probe)"
fi

gc_left=""
if [[ -d "$NIX_SCOUT_GCROOTS" ]]; then
  gc_left="$("$FIND" "$NIX_SCOUT_GCROOTS" -mindepth 1 2>/dev/null | "$HEAD" -n 1 || true)"
fi
if [[ -z "$gc_left" ]]; then
  pass "clear removed scout gc-roots"
else
  fail "clear left gc-roots under $NIX_SCOUT_GCROOTS ($gc_left)"
fi

run_capture env \
  HOME="$HOME" \
  NIX_SCOUT_PATHS_FILE="$NIX_SCOUT_PATHS_FILE" \
  NIX_SCOUT_PROFILE="$NIX_SCOUT_PROFILE" \
  NIX_SCOUT_GCROOTS="$NIX_SCOUT_GCROOTS" \
  "$BIN" status
STATUS_AFTER="$CAPTURED_OUT$CAPTURED_ERR"
if [[ "$STATUS_AFTER" != *scout-probe* && "$STATUS_AFTER" != *nix-scout* ]]; then
  pass "status empty of live payloads after clear"
else
  fail "status still lists payloads after clear: $(printf %q "$STATUS_AFTER")"
fi

assert_default_profile_untouched "clear did not modify default user profile"

finish_suite
