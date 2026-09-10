# Turns `nix build --dry-run` stderr into the list of derivations still to be built, one
# store path per line on stdout.
#
# Split out of modules/auto-upgrade.nix so it can be exercised against fixtures without
# booting anything (tests/upgrade-plan-parse.nix). That matters more than it looks: this is
# the one place in the one-derivation-per-process upgrade that reads nix's *human-readable*
# output, and its dangerous failure mode is silent. If a future nix reworded the plan header,
# a naive parser would find zero derivations, the caller's build loop would do nothing, and
# the nixos-rebuild afterwards would fall back to a single monolithic build -- which is
# exactly the ~6.5 GB coordinator that OOMs the 4 GB Pi. So the parse cross-checks itself
# against nix's own count and fails loudly rather than degrading quietly.
{ pkgs }:

pkgs.writeShellApplication {
  name = "nixos-upgrade-plan-parse";
  runtimeInputs = [ pkgs.coreutils pkgs.gawk pkgs.gnugrep ];
  text = ''
    if [ "$#" -ne 1 ]; then
      echo "usage: nixos-upgrade-plan-parse <dry-run-stderr-file>" >&2
      exit 2
    fi
    plan="$1"

    todo="$(mktemp)"
    trap 'rm -f "$todo"' EXIT

    # Derivations still to build. Paths to *fetch* are listed in the same indented form but
    # are outputs, not .drv paths, which is what separates the two sections. Bracketed "."
    # rather than a backslash escape so the pattern is unambiguous however the surrounding
    # Nix string is quoted. `|| true` because grep exits 1 on no matches and the caller runs
    # under `set -o pipefail` -- an empty plan is a legitimate result, not an error.
    grep -oE '^  /nix/store/[a-z0-9]{32}-.*[.]drv$' "$plan" | tr -d ' ' | sort -u > "$todo" || true
    count="$(wc -l < "$todo" | tr -d ' ')"

    # nix writes "this derivation will be built:" (singular) for exactly one, and omits the
    # header entirely when there is nothing to build.
    expected="$(awk '/^these [0-9]+ derivations will be built:$/ { print $2 }' "$plan")"
    if [ -z "$expected" ]; then
      if grep -qxF 'this derivation will be built:' "$plan"; then
        expected=1
      else
        expected=0
      fi
    fi

    if [ "$count" -ne "$expected" ]; then
      echo "nixos-upgrade-plan-parse: parsed $count derivations but nix planned $expected; refusing to continue" >&2
      head -n 20 "$plan" >&2
      exit 1
    fi

    cat "$todo"
  '';
}
