#!/usr/bin/env bash
# Apply scout home-files facet: copy $STORE/home-files tree into $HOME.
#
# Removal tracking: every applied file is recorded (relpath, policy, baseline
# sha256) in the per-module manifest under
# $XDG_STATE_HOME/nix-scout/home-files/<name>.manifest. On the next run,
# manifest entries absent from $STORE/home-files are handled per their
# recorded policy (see scout-lib.sh):
#   - activation mode (NIX_SCOUT_ACTIVATION=1, set by the NixOS module's
#     nix-scout-home-files activation script): files are actually deleted.
#   - CLI mode (`nix-scout switch`, the default): nothing is ever deleted;
#     every vanished file is reported with what a rebuild would do.
set -euo pipefail

STORE="${1:?scout store path required}"
NAME="${2:-scout}"
HOME="${HOME:?HOME is required}"

# shellcheck source=scout-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scout-lib.sh"

# CLI mode unless the NixOS activation script says otherwise; only activation
# mode may delete vanished files.
MODE="cli"
if [[ "${NIX_SCOUT_ACTIVATION:-}" == "1" ]]; then
  MODE="activation"
fi

# The manifest is keyed by module name — refuse names that could escape the
# state directory (tracking is skipped for such names; application proceeds).
MANIFEST_OK=1
case "$NAME" in
  ''|*[!A-Za-z0-9._-]*) MANIFEST_OK=0 ;;
esac

_scout_diff_run_prepare "home-files-${NAME}" \
  "module: $NAME" \
  "store: $STORE" \
  "mode: $MODE"

_home_dest() {
  local rel="$1"
  if [[ "$rel" == .config/* ]]; then
    printf '%s/%s' "${XDG_CONFIG_HOME:-$HOME/.config}" "${rel#.config/}"
  else
    printf '%s/%s' "$HOME" "$rel"
  fi
}

# Optional per-file policies shipped by the module ($out/home-manage.json).
_scout_home_manage_parse "$STORE"
if [[ "$MANIFEST_OK" == "1" ]]; then
  _scout_manifest_load "$NAME"
fi

if [[ -d "$STORE/home-files" ]]; then
  src="" rel="" dest=""
  while IFS= read -r -d '' src; do
    rel="${src#"$STORE/home-files"/}"
    dest="$(_home_dest "$rel")"
    _priv_mkdir "$(dirname "$dest")"

    if [[ -f "$dest" ]]; then
      if ! cmp -s "$src" "$dest" 2>/dev/null; then
        _scout_emit_diff "$dest" "$src" \
          "previous" \
          "Nix baseline (scout module)"
      fi
    fi

    if [[ -L "$dest" ]]; then
      rm -f "$dest"
    fi
    cp --force "$src" "$dest"
    chmod u+w "$dest"

    # (Re-)adopt the file: record the policy currently in effect and the
    # baseline we just wrote, so a later removal can tell user edits from
    # pristine copies.
    if [[ "$MANIFEST_OK" == "1" ]]; then
      _SCOUT_MANIFEST_POLICY["$rel"]="${_SCOUT_FILE_POLICY[$rel]:-remove}"
      _SCOUT_MANIFEST_SHA["$rel"]="$(sha256sum "$dest" | cut -d' ' -f1)"
    fi
  done < <(find "$STORE/home-files" \( -type f -o -type l \) -print0)
fi

# Sweep: manifest entries no longer present in the store. Their recorded
# policy — from the run that last applied them — decides their fate; only
# activation mode deletes. A module that dropped its home-files/ tree (or was
# emptied) sweeps every entry.
if [[ "$MANIFEST_OK" == "1" ]]; then
  retired=("${!_SCOUT_MANIFEST_POLICY[@]}")
  for rel in "${retired[@]}"; do
    if [[ -e "$STORE/home-files/$rel" || -L "$STORE/home-files/$rel" ]]; then
      continue  # still in the config — the copy loop above just handled it
    fi
    dest="$(_home_dest "$rel")"
    if [[ ! -e "$dest" && ! -L "$dest" ]]; then
      # Already gone from disk — nothing left to track or report.
      unset '_SCOUT_MANIFEST_POLICY[$rel]' '_SCOUT_MANIFEST_SHA[$rel]'
      continue
    fi

    modified="unknown"
    baseline="${_SCOUT_MANIFEST_SHA[$rel]:-}"
    if [[ -n "$baseline" ]]; then
      current="$(sha256sum "$dest" 2>/dev/null | cut -d' ' -f1 || true)"
      if [[ -n "$current" ]]; then
        if [[ "$current" == "$baseline" ]]; then
          modified="no"
        else
          modified="yes"
        fi
      fi
    fi

    _scout_home_vanished_report "$NAME" "$rel" "${_SCOUT_MANIFEST_POLICY[$rel]}" "$modified" "$MODE"
    if [[ "$_SCOUT_HOME_VANISHED_ACTION" == "delete" ]]; then
      rm -f "$dest"
      unset '_SCOUT_MANIFEST_POLICY[$rel]' '_SCOUT_MANIFEST_SHA[$rel]'
    fi
    # Kept entries stay in the manifest so future runs keep reporting them and
    # a re-added config entry is re-adopted with a fresh baseline.
  done

  # Rewrite the manifest — but don't conjure one for a module that never had
  # any tracked files (profile-only modules run through here every rebuild).
  if [[ "${#_SCOUT_MANIFEST_POLICY[@]}" -gt 0 ]] || \
     [[ -s "$(_scout_manifest_dir)/$NAME.manifest" ]]; then
    _scout_manifest_store "$NAME"
  fi
fi

_scout_diff_run_log_finish
if [[ -d "$STORE/home-files" ]]; then
  echo "nix-scout: applied home-files scout $NAME from $STORE"
fi
