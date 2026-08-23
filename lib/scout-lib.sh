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

pin_gcroot() {
  local store="$1" name="$2"
  local gcroots="${NIX_SCOUT_GCROOTS:-/nix/var/nix/gcroots/per-user/${USER}/nix-scout}"
  _priv_mkdir "$gcroots"
  _priv_ln_sfn "$store" "$gcroots/$name"
}

# Dummy sentinel flake.lock (nix-scout + nixpkgs nodes never really resolved —
# real resolution always comes from the parent flake; see materialize-module.sh
# and nixos-module.nix). Shared by new-module.sh (initial scaffold) and
# update-module.sh (bootstrapping a module that lost its committed lock).
write_sentinel_lock() {
  local target="$1"
  local _SENTINEL="nix-scout_not-real-lockfile"
  local _NAR="sha256-0000000000000000000000000000000000000000000="
  local _REV="0000000000000000000000000000000000000000"
  cat > "$target" <<EOF
{
  "nodes": {
    "nix-scout": {
      "inputs": {
        "nixpkgs": [
          "nixpkgs"
        ]
      },
      "locked": {
        "lastModified": 0,
        "narHash": "${_NAR}",
        "owner": "${_SENTINEL}",
        "repo": "${_SENTINEL}",
        "rev": "${_REV}",
        "type": "github"
      },
      "original": {
        "owner": "mikenrafter",
        "repo": "nix-scout",
        "type": "github"
      }
    },
    "nixpkgs": {
      "locked": {
        "lastModified": 0,
        "narHash": "${_NAR}",
        "owner": "${_SENTINEL}",
        "repo": "${_SENTINEL}",
        "rev": "${_REV}",
        "type": "github"
      },
      "original": {
        "owner": "NixOS",
        "ref": "nixos-26.05",
        "repo": "nixpkgs",
        "type": "github"
      }
    },
    "root": {
      "inputs": {
        "nix-scout": "nix-scout",
        "nixpkgs": "nixpkgs"
      }
    }
  },
  "root": "root",
  "version": 7
}
EOF
}
