#!/usr/bin/env bash
# Shared primitives for nix-scout lib scripts.

_can_write() {
  local check="$1"
  while [[ "$check" != "/" && ! -e "$check" ]]; do
    check="$(dirname "$check")"
  done
  [[ -w "$check" ]]
}

_priv_mkdir() {
  local dir="$1"
  if _can_write "$dir"; then
    mkdir -p "$dir"
  else
    echo "nix-scout: need elevated permissions to create $dir" >&2
    sudo mkdir -p "$dir"
  fi
}

_priv_ln_sfn() {
  local target="$1" link="$2"
  if [[ -w "$(dirname "$link")" ]]; then
    ln -sfn "$target" "$link"
  else
    echo "nix-scout: need elevated permissions to link $link" >&2
    sudo ln -sfn "$target" "$link"
  fi
}

_priv_nix_env() {
  local profile="$1" store="$2"
  if _can_write "$profile"; then
    nix-env -p "$profile" -i "$store"
  else
    echo "nix-scout: need elevated permissions for nix-env profile $profile" >&2
    sudo nix-env -p "$profile" -i "$store"
  fi
}

# Per-run unified-diff logs under $XDG_STATE_HOME/nix-scout/diffs/.
# Set NIX_SCOUT_DIFF_LOG=0 to skip file logging (stdout unchanged).
# Override directory with NIX_SCOUT_DIFF_LOG_DIR.
_SCOUT_DIFF_LOG=""
_SCOUT_DIFF_PREFIX=""
_SCOUT_DIFF_META=()

_scout_diff_log_dir() {
  printf '%s' "${NIX_SCOUT_DIFF_LOG_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/nix-scout/diffs}"
}

# Call once before the first _scout_emit_diff; pass a filesystem-safe prefix
# (e.g. home-files-break-lock) and optional header lines (module:, store:, …).
_scout_diff_run_prepare() {
  _SCOUT_DIFF_PREFIX="${1:?diff log prefix required}"
  shift
  _SCOUT_DIFF_META=("$@")
}

_scout_diff_run_log_open() {
  [[ -n "$_SCOUT_DIFF_LOG" || "${NIX_SCOUT_DIFF_LOG:-1}" == "0" ]] && return 0
  local dir ts
  dir="$(_scout_diff_log_dir)"
  _priv_mkdir "$dir"
  ts="$(date +%Y%m%dT%H%M%S)"
  _SCOUT_DIFF_LOG="$dir/${_SCOUT_DIFF_PREFIX}-${ts}.log"
  {
    echo "=== nix-scout diff run: $_SCOUT_DIFF_PREFIX ==="
    echo "started: $(date -Iseconds)"
    echo "home: $HOME"
    local line
    for line in "${_SCOUT_DIFF_META[@]}"; do
      echo "$line"
    done
  } | tee "$_SCOUT_DIFF_LOG"
}

# Print a unified diff to stdout and append the same bytes to the per-run log.
_scout_emit_diff() {
  local dest="$1" src="$2"
  local label_old="${3:-previous}"
  local label_new="${4:-Nix baseline}"

  if [[ "${NIX_SCOUT_DIFF_LOG:-1}" != "0" && -z "$_SCOUT_DIFF_LOG" ]]; then
    _scout_diff_run_log_open
  fi

  _emit() {
    echo ""
    echo "--- file: $dest ---"
    diff -u --label "$label_old" --label "$label_new" "$dest" "$src" || true
  }

  if [[ -n "$_SCOUT_DIFF_LOG" ]]; then
    _emit | tee -a "$_SCOUT_DIFF_LOG"
  else
    _emit
  fi
}

_scout_diff_run_log_finish() {
  if [[ -n "$_SCOUT_DIFF_LOG" ]]; then
    echo "nix-scout: diff log $_SCOUT_DIFF_LOG"
  fi
}

# ── home-files removal policies ──────────────────────────────────────────────
# Files nix-scout copies into $HOME are mutable regular copies, so a user can
# edit them after activation and a file can outlive its config entry (dropped
# from home-files/, or the home-files/ tree removed entirely). Both home-files
# activators (apply-hm.sh for scout modules, hm-activate-files.sh for Home
# Manager generations) share this vocabulary for files that are no longer in
# their config:
#
#   remove (default)  delete the file
#   keep              never delete it
#   keep-if-modified  delete it only if it still matches the baseline the
#                     activator last wrote; keep it if the user has edited it
#   inform            never delete; report that it is no longer managed
#
# Deletions only ever happen in activation mode (NIX_SCOUT_ACTIVATION=1, set
# by the NixOS module's activation scripts). A `nix-scout switch` run is CLI
# mode: it never deletes anything and reports, for every vanished file, what
# a rebuild would do under that file's policy.

# Print a line to stdout and, when a per-run diff log is open, append it there
# too so removal decisions land in the same audit log as the diffs.
_scout_say() {
  if [[ -n "$_SCOUT_DIFF_LOG" ]]; then
    printf '%s\n' "$1" | tee -a "$_SCOUT_DIFF_LOG"
  else
    printf '%s\n' "$1"
  fi
}

# Validate a removal policy. Echoes one of remove|keep|keep-if-modified|inform;
# an empty value (a missing entry) means the default. Unknown values warn and
# fall back to remove so a typo can never silently pin a file forever.
_scout_home_policy_normalize() {
  local policy="${1:-}"
  case "$policy" in
    ""|remove|keep|keep-if-modified|inform)
      printf '%s' "${policy:-remove}"
      ;;
    *)
      echo "nix-scout: unknown home-file policy '$policy' — treating as 'remove'" >&2
      printf '%s' "remove"
      ;;
  esac
}

# Report a vanished home file (on record from a previous run, absent from the
# current config) and decide its fate.
#   $1 module label   $2 rel path   $3 policy
#   $4 modified: yes|no|unknown — does the file differ from the baseline that
#      was set for it?  $5 mode: activation|cli
# Sets _SCOUT_HOME_VANISHED_ACTION to "delete" or "keep".
_scout_home_vanished_report() {
  local module="$1" rel="$2" policy="$3" modified="$4" mode="$5"
  local will_delete=0 reason=""

  case "$policy" in
    remove)
      will_delete=1
      ;;
    keep-if-modified)
      case "$modified" in
        no)  will_delete=1; reason="; unmodified from its baseline" ;;
        yes) reason="; differs from its baseline" ;;
        # No baseline on record (applied before tracking existed, or the
        # file cannot be hashed) — no proof it is unmodified, so it stays.
        *)   reason="; no baseline on record" ;;
      esac
      ;;
    inform)
      _SCOUT_HOME_VANISHED_ACTION="keep"
      _scout_say "nix-scout: $module: $rel is no longer managed by nix-scout (policy: inform); left in place"
      return 0
      ;;
    # keep: falls through with will_delete=0, reason="" — never deletes.
  esac

  if [[ "$mode" == "activation" ]]; then
    if [[ "$will_delete" == "1" ]]; then
      _SCOUT_HOME_VANISHED_ACTION="delete"
      _scout_say "nix-scout: $module: removed $rel (no longer in the config$reason)"
    else
      _SCOUT_HOME_VANISHED_ACTION="keep"
      # A plain "keep" policy was never going to delete — nothing to report.
      [[ "$policy" == "keep" ]] || _scout_say "nix-scout: $module: kept $rel (no longer in the config$reason)"
    fi
  else
    _SCOUT_HOME_VANISHED_ACTION="keep"
    if [[ "$policy" == "keep" ]]; then
      _scout_say "nix-scout: $module: $rel is no longer in the config — a rebuild would leave it in place (policy: keep)"
    elif [[ "$will_delete" == "1" ]]; then
      _scout_say "nix-scout: $module: $rel is no longer in the config — a rebuild would delete it (policy: $policy$reason); skipped: the nix-scout CLI never deletes"
    else
      _scout_say "nix-scout: $module: $rel is no longer in the config — a rebuild would leave it in place (policy: $policy$reason)"
    fi
  fi
}

# ── per-module home-files manifest (scout modules only) ─────────────────────
# hm-activate-files.sh tracks the previous generation via oldGenPath; scout
# home-files have no generations, so apply-hm.sh records what it last applied
# to $HOME: one line per file, TAB-separated: relpath, policy, baseline
# sha256. Lives with the diff logs under the user's state dir so both the CLI
# and the rebuild activation script (run as the user) see the same record.
declare -gA _SCOUT_MANIFEST_POLICY=()
declare -gA _SCOUT_MANIFEST_SHA=()

_scout_manifest_dir() {
  printf '%s' "${NIX_SCOUT_MANIFEST_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/nix-scout/home-files}"
}

# Manifest relpaths come from our own state file and from module-authored
# home-manage.json — defensive regardless: no absolute paths, no traversal,
# no characters that would break the TAB/line-based formats.
_scout_manifest_rel_ok() {
  local rel="$1" part
  [[ -n "$rel" && "$rel" != /* && "$rel" != *$'\t'* && "$rel" != *$'\n'* ]] || return 1
  while IFS=/ read -r -a parts; do
    for part in "${parts[@]}"; do
      [[ "$part" == "." || "$part" == ".." || -z "$part" ]] && return 1
    done
  done <<< "$rel"
  return 0
}

_scout_manifest_load() {
  local module="$1" file rel policy sha
  _SCOUT_MANIFEST_POLICY=()
  _SCOUT_MANIFEST_SHA=()
  file="$(_scout_manifest_dir)/$module.manifest"
  [[ -f "$file" ]] || return 0
  while IFS=$'\t' read -r rel policy sha; do
    [[ "$rel" == "#"* || -z "$rel" ]] && continue
    if ! _scout_manifest_rel_ok "$rel"; then
      echo "nix-scout: ignoring unsafe path in $file: $rel" >&2
      continue
    fi
    _SCOUT_MANIFEST_POLICY["$rel"]="$(_scout_home_policy_normalize "$policy")"
    _SCOUT_MANIFEST_SHA["$rel"]="${sha:-}"
  done < "$file"
}

# Atomically rewrite the manifest from the current arrays; call after the
# copy/sweep pass so the file always reflects exactly what this run left on
# disk.
_scout_manifest_store() {
  local module="$1" dir file tmp rel
  dir="$(_scout_manifest_dir)"
  file="$dir/$module.manifest"
  _priv_mkdir "$dir"
  tmp="$(mktemp "$dir/.${module}.manifest.XXXXXX")"
  {
    echo "# nix-scout home-files manifest v1: relpath, policy, baseline sha256 (module: $module)"
    for rel in "${!_SCOUT_MANIFEST_POLICY[@]}"; do
      printf '%s\t%s\t%s\n' "$rel" "${_SCOUT_MANIFEST_POLICY[$rel]}" "${_SCOUT_MANIFEST_SHA[$rel]}"
    done
  } | LC_ALL=C sort > "$tmp"
  mv -f "$tmp" "$file"
}

# ── shared JSON policy-file parsing ──────────────────────────────────────────
# Both home-files activators take an optional JSON object mapping a
# home-relative path to a removal policy: apply-hm.sh from a module's
# home-manage.json, hm-activate-files.sh from the eval-time
# NIX_SCOUT_HM_POLICIES_FILE. One parser, one path-safety check, one jq
# filter, so the two never drift apart.
#   $1 JSON file (missing/non-object: warns and leaves the array untouched)
#   $2 name of a caller-declared associative array to fill (relpath -> policy)
_scout_home_policies_load_json() {
  local json="$1" array_name="$2"
  local -n _scout_policies_dest="$array_name"
  local policy rel
  [[ -f "$json" ]] || return 0
  if ! jq -e 'type == "object"' "$json" >/dev/null 2>&1; then
    echo "nix-scout: $json is not a JSON object — ignoring per-file policies" >&2
    return 0
  fi
  while IFS=$'\t' read -r policy rel; do
    [[ -z "$rel" ]] && continue
    if ! _scout_manifest_rel_ok "$rel"; then
      echo "nix-scout: ignoring unsafe path in $json: $rel" >&2
      continue
    fi
    _scout_policies_dest["$rel"]="$(_scout_home_policy_normalize "$policy")"
  done < <(jq -r '
    to_entries[]
    | select((.value | type) == "string")
    | select((.key | test("[\\x00-\\x1f]")) | not)
    | "\(.value)\t\(.key)"
  ' "$json")
}

# ── per-file policies shipped by a scout module ─────────────────────────────
# A module's package may carry a home-manage.json next to home-files/: a JSON
# object mapping home-files-relative paths to a policy, authored in the
# module's flake.nix via pkgs.writeText + builtins.toJSON. Fills
# _SCOUT_FILE_POLICY; unlisted (and modules without the file) default to
# remove.
declare -gA _SCOUT_FILE_POLICY=()

_scout_home_manage_parse() {
  local store="$1"
  _SCOUT_FILE_POLICY=()
  _scout_home_policies_load_json "$store/home-manage.json" _SCOUT_FILE_POLICY
}

pin_gcroot() {
  local store="$1" name="$2"
  local gcroots="${NIX_SCOUT_GCROOTS:-/nix/var/nix/gcroots/per-user/${USER}/nix-scout}"
  _priv_mkdir "$gcroots"
  _priv_ln_sfn "$store" "$gcroots/$name"
}

# Sync a scout module's committed flake.lock from the parent (host) flake's
# own already-resolved lock — nixpkgs, nix-scout, and anything else
# (llm-agents, etc.) the host itself declares at top level. This is the same
# starting point materialize-module.sh already uses for tmpdir builds at
# switch time; `nix-scout new` (initial scaffold) and `nix-scout update`
# (ongoing sync) do it for the *committed* module directory too.
#
# The host's lock is a strict superset of what any given module actually
# declares, so it can't just be copied verbatim: `nix flake metadata` (and
# `archive`, `build`, ...) evaluate a flake for real and PRUNE any node the
# flake.nix doesn't actually reference, rewriting the lock file in place —
# confirmed directly, and true with or without `--refresh`. flakelet's own
# calls never pass `--no-write-lock-file`, so an unpruned copy would make
# its supposedly read-only evaluation of a registered module itself try (and
# fail — flakelet's eval_user has no write access to the module tree, see
# flakelet-access.sh) to write a trimmed copy — the exact same class of
# failure as a missing node, just from the opposite direction. So this
# copies the host's lock into a scratch copy of the module first, lets
# `nix flake metadata` prune it there (as this process's own user, who does
# have write access), and only then compares/writes the *pruned* result into
# the committed file — already in the minimal, stable form flakelet's
# read-only eval expects.
#
# Requires NIX_SCOUT_PARENT to be set and point at a directory with a
# flake.lock. Only writes when the pruned content actually differs from
# what's currently committed (a no-op run of `nix-scout switch` shouldn't
# dirty git status); preserves the target's existing file mode across the
# write. Prints "created"/"updated"/"already up to date" as appropriate.
# Returns 1 with a clear message if the parent lock can't be found, pruning
# fails, or the target isn't writable.
sync_lock_from_parent() {
  local module_dir="$1"
  local parent="${NIX_SCOUT_PARENT:-}"

  if [[ -z "$parent" ]]; then
    echo "nix-scout: NIX_SCOUT_PARENT not set — cannot sync $module_dir/flake.lock from the host" >&2
    return 1
  fi
  local parent_lock="$parent/flake.lock"
  if [[ ! -f "$parent_lock" ]]; then
    echo "nix-scout: host flake.lock missing at $parent_lock — cannot sync $module_dir/flake.lock" >&2
    return 1
  fi
  if [[ -f "$module_dir/flake.lock" && ! -w "$module_dir/flake.lock" ]]; then
    echo "nix-scout: no write access to $module_dir/flake.lock" >&2
    return 1
  fi
  if [[ ! -w "$module_dir" ]]; then
    echo "nix-scout: no write access to $module_dir" >&2
    return 1
  fi

  local before=""
  # Hash content only (`sha256sum < file`, not `sha256sum file`) so it's
  # comparable against the scratch copy's hash below despite the differing
  # paths.
  [[ -f "$module_dir/flake.lock" ]] && before="$(sha256sum < "$module_dir/flake.lock")"

  local scratch
  scratch="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$scratch'" RETURN
  cp "$module_dir/flake.nix" "$scratch/flake.nix"
  cp "$parent_lock" "$scratch/flake.lock"
  if ! nix flake metadata --json "$scratch" >/dev/null 2>&1; then
    echo "nix-scout: failed to resolve $module_dir against the host's flake.lock — run \`nix flake metadata $scratch\` to see why" >&2
    return 1
  fi

  local after
  after="$(sha256sum < "$scratch/flake.lock")"

  if [[ "$before" == "$after" ]]; then
    echo "nix-scout: $module_dir/flake.lock already up to date"
    return 0
  fi

  # mktemp'ing $scratch already gave it mode 0700 -> the copied flake.lock
  # inside it is 0600; `cp`/`mv` into place keeps the source's permissions,
  # not the destination's, so without an explicit chmod the committed
  # flake.lock would silently lose its group/other-read bits on every sync —
  # breaking flakelet's (unprivileged eval_user, read-only) access to it.
  if [[ -f "$module_dir/flake.lock" ]]; then
    chmod --reference="$module_dir/flake.lock" "$scratch/flake.lock" 2>/dev/null || chmod 644 "$scratch/flake.lock"
    cp "$scratch/flake.lock" "$module_dir/flake.lock"
    echo "nix-scout: updated $module_dir/flake.lock from host flake.lock"
  else
    chmod 644 "$scratch/flake.lock"
    cp "$scratch/flake.lock" "$module_dir/flake.lock"
    echo "nix-scout: created $module_dir/flake.lock from host flake.lock"
  fi
}
