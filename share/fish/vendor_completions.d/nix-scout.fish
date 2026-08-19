# Fish completions for nix-scout

complete -c nix-scout -f

function __nix_scout_needs_subcommand
    not __fish_seen_subcommand_from list switch status clear help --help -h
end

complete -c nix-scout -n __nix_scout_needs_subcommand -a list   -d 'List scout modules'
complete -c nix-scout -n __nix_scout_needs_subcommand -a switch -d 'Materialize, build, and apply a scout module'
complete -c nix-scout -n __nix_scout_needs_subcommand -a status -d 'Show active scout profile and gc-roots'
complete -c nix-scout -n __nix_scout_needs_subcommand -a clear  -d 'Clear scout profile and gc-roots'
complete -c nix-scout -n __nix_scout_needs_subcommand -a help   -d 'Show usage'

# switch: offer module names from `nix-scout list`
complete -c nix-scout -n '__fish_seen_subcommand_from switch' \
    -a '(nix-scout list 2>/dev/null)' -d 'Scout module'
