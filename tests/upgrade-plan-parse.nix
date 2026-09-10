# Fixture test for lib/upgrade-plan-parse.nix, the one place the one-derivation-per-process
# upgrade depends on nix's human-readable output.
#
# Why this is worth its own check: every way this parser can drift fails *silently* on a real
# host. If it returns zero derivations, modules/auto-upgrade.nix's build loop does nothing,
# the nixos-rebuild after it falls back to a single monolithic build, and the 4 GB Pi is back
# to the ~6.5 GB coordinator that OOM-killed it for four nights. Nothing downstream notices:
# the upgrade unit just fails days later with a SIGKILL. So the parser cross-checks itself
# against nix's own count, and the cases below pin that cross-check in both directions.
#
# Builds no machine image, so it lives in the eval checkSet.
{ pkgs }:

let
  parse = import ../lib/upgrade-plan-parse.nix { inherit pkgs; };
in
pkgs.runCommand "upgrade-plan-parse-test"
{
  nativeBuildInputs = [ pkgs.coreutils pkgs.gnugrep ];
} ''
  parse=${pkgs.lib.getExe parse}

  # Built with printf rather than written out, so the hashes are exactly 32 chars -- the
  # parser's pattern is anchored on that length and a miscounted literal would make these
  # fixtures pass for the wrong reason.
  A=$(printf 'a%.0s' $(seq 32))
  B=$(printf 'b%.0s' $(seq 32))
  C=$(printf 'c%.0s' $(seq 32))
  D=$(printf 'd%.0s' $(seq 32))

  fail() { echo "FAIL: $*" >&2; exit 1; }

  echo "== nothing to build =="
  : > empty
  got=$("$parse" empty)
  [ -z "$got" ] || fail "empty plan should yield nothing, got: $got"

  echo "== singular header (nix says 'this derivation', not 'these 1') =="
  {
    echo "this derivation will be built:"
    echo "  /nix/store/$A-one.drv"
  } > singular
  got=$("$parse" singular)
  [ "$got" = "/nix/store/$A-one.drv" ] || fail "singular: got '$got'"

  echo "== plural header, with a fetched section that must not be counted =="
  {
    echo "these 2 derivations will be built:"
    echo "  /nix/store/$A-one.drv"
    echo "  /nix/store/$B-two.drv"
    echo "these 2 paths will be fetched (1.0 MiB download, 2.0 MiB unpacked):"
    echo "  /nix/store/$C-fetched-output"
    echo "  /nix/store/$D-another-output"
  } > mixed
  got=$("$parse" mixed)
  [ "$(printf '%s\n' "$got" | wc -l)" = 2 ] || fail "mixed: expected 2 lines, got: $got"
  if printf '%s\n' "$got" | grep -q 'fetched-output'; then
    fail "mixed: a path to be fetched leaked into the build list"
  fi

  echo "== warnings and progress noise around the plan are ignored =="
  {
    echo "warning: Git tree '/etc/nixos' is dirty"
    echo "this derivation will be built:"
    echo "  /nix/store/$A-one.drv"
    echo "warning: unable to download 'https://cache.nixos.org/nix-cache-info'"
  } > noisy
  got=$("$parse" noisy)
  [ "$got" = "/nix/store/$A-one.drv" ] || fail "noisy: got '$got'"

  echo "== header count larger than the list -> abort =="
  {
    echo "these 5 derivations will be built:"
    echo "  /nix/store/$A-one.drv"
  } > short
  if "$parse" short > /dev/null 2> short.err; then
    fail "a header/list mismatch must not be accepted"
  fi
  grep -q 'refusing to continue' short.err || fail "short: no explanatory message: $(cat short.err)"

  echo "== reworded header, list intact -> abort (catches nix rewording the header) =="
  {
    echo "these 2 derivations shall be constructed:"
    echo "  /nix/store/$A-one.drv"
    echo "  /nix/store/$B-two.drv"
  } > reworded
  if "$parse" reworded > /dev/null 2>&1; then
    fail "an unrecognised header with entries present must not be accepted"
  fi

  echo "== header intact, list format changed -> abort (the silent-degradation case) =="
  # The dangerous direction: entries stop matching, so a naive parser reports "nothing to
  # build" and the caller quietly does the whole thing in one process.
  {
    echo "these 2 derivations will be built:"
    echo "/nix/store/$A-one.drv"
    echo "/nix/store/$B-two.drv"
  } > unindented
  if "$parse" unindented > /dev/null 2>&1; then
    fail "an unrecognised entry format must not be reported as an empty plan"
  fi

  echo "== usage error =="
  if "$parse" > /dev/null 2>&1; then
    fail "missing argument should be a usage error"
  fi

  touch "$out"
''
