# Eval-only guard on what the DEPLOYED hosts actually tell systemd to do about time.
#
# Two claims, both read off the rendered units of the real host configs, and both invisible to
# every VM test -- because both VM tests have to override exactly these values to be testable
# at all:
#
#   * the cadence, "a separate service runs every hour and after boot". tests/time-correction.nix
#     overrides `interval` to 3h and asserts 3h, because a second timed run landing mid-test
#     would step the clock out from under subtests that place it by hand; tests/nts-sync.nix
#     pushes `bootDelay` to 3h for the same reason and drives the unit by hand.
#   * the ARGUMENTS the correction service is handed. tests/time-correction.nix forces `servers`
#     to two hosts, `sample` to 1 and `floor` to a fixture; tests/nts-sync.nix forces `servers`
#     and `floor`. So no test has ever seen a host ask the four real NTS servers through the
#     four real DoH resolvers with the build-time floor.
#
# A drift in either is silent in the worst way: the unit stays green, the timer stays armed, and
# the only symptom is that the hourly run which is supposed to catch a dead provider *while the
# host is still reachable* now happens daily -- or that the quorum is drawn from a smaller pool
# than the configuration appears to describe.
#
# The argument check is what catches the join in modules/time-sync.nix going wrong. `selected`
# there is `filterAttrs (_: p: elem p.hostname cfg.servers)` over lib/nts-servers.nix, while
# chrony reads `cfg.servers` directly -- so a hostname that stops matching leaves chrony using
# the name while time-correction silently loses that operator, shrinking the pool the quorum is
# drawn from with nothing anywhere reporting it. Comparing against the full provider list rather
# than against `cfg.servers` is what makes that visible: the two are the same list today, and
# this check is the statement that they still are.
#
# Read from the rendered units rather than from `config.common.timeSync.*`: the option value
# being right is not the claim worth making -- the claim is that systemd is told it. That catches
# a module that stopped threading an option into the unit, which reading the option back cannot.
#
# Fails with `throw` during evaluation, so this stays usable from a pure `nix flake check`.
{ pkgs, hosts, ntsServers, dohStamps }:

let
  lib = pkgs.lib;

  # OnBootSec is the "after boot" half. A minute rather than zero: the run needs
  # network-online.target, and starting a DoH exchange the instant userspace comes up only means
  # waiting for the network inside the unit instead of in front of it.
  expected = {
    "OnBootSec" = "1min";
    "OnUnitActiveSec" = "1h";
  };

  # The scalar flags, spelled out rather than read back from the options they come from. Reading
  # them back would assert only that a value survived a round trip; these are the numbers the
  # hosts are supposed to ship, and a change to any of them should have to be made twice.
  expectedFlags = {
    "--sample" = "2";
    "--tolerance" = "60";
    "--timeout" = "10";
  };

  # A floor is a build-time constant (nixpkgs.lastModified), so its exact value changes with
  # every input bump and cannot be asserted. What can be asserted is that it is a real one:
  # present, numeric, and not some degenerate value that would disable the bound it exists to
  # be. 2023-11-14, comfortably before any nixpkgs this repo could be pinned to and comfortably
  # after 0 -- which is what `--floor` would carry if the option ever defaulted its way through.
  floorLowerBound = 1700000000;

  unitOf = host: name: hosts.${host}.config.systemd.units.${name}.text or null;

  trimmedLines = text: map lib.trim (lib.splitString "\n" (if text == null then "" else text));

  # --- the timer ------------------------------------------------------------------------

  timerDrift =
    host:
    let
      text = unitOf host "time-correction.timer";
      lines = trimmedLines text;
      has = directive: value: lib.elem "${directive}=${value}" lines;
      present = directive: lib.any (l: lib.hasPrefix "${directive}=" l) lines;
      actual = directive: toString (lib.filter (l: lib.hasPrefix "${directive}=" l) lines);
    in
    if text == null then
      [ "${host}: has no time-correction.timer at all, so nothing runs the correction service" ]
    else
      lib.concatMap (
        directive:
        lib.optional (!has directive expected.${directive}) (
          if present directive then
            "${host}: has ${actual directive}, expected ${directive}=${expected.${directive}}"
          else
            "${host}: no ${directive} directive at all, expected ${directive}=${expected.${directive}}"
        )
      ) (builtins.attrNames expected)
      # Persistent + OnCalendar is the shape this must never become: Persistent works out what was
      # missed by comparing a stored wall-clock stamp against the current clock, and a wrong clock
      # is precisely the state this service exists for. tests/time-correction.nix asserts this on
      # its own node; here it is asserted on the deployed ones.
      ++ lib.optional (present "OnCalendar")
        "${host}: ${actual "OnCalendar"} -- the timer must be monotonic, not calendar-driven"
      ++ lib.optional (has "Persistent" "true" || has "Persistent" "yes")
        "${host}: Persistent is set, which decides what was missed from a clock that cannot be trusted";

  # --- the service's arguments ----------------------------------------------------------

  # An expected argument pair, rendered the way modules/time-sync.nix renders it.
  #
  # Through `lib.escapeShellArgs` rather than by quoting here, because that function quotes only
  # what needs quoting: `--sample 2` comes out bare while `cloudflare=...@1.1.1.1,...` is quoted
  # for its `=`. Hard-coding either spelling would make this check pass or fail on nixpkgs'
  # escaping rules rather than on the arguments, which are what it is about.
  flag = name: value: lib.escapeShellArgs [ name value ];

  # Substring, but bounded on both sides by the spaces that separate arguments. Unbounded,
  # `--sample 2` is a substring of `--sample 20`, and the one option whose value is a small
  # integer is exactly the one where that matters. Every argument on the line is preceded by a
  # space (the binary path comes first), so the leading bound is always available.
  hasArg = exec: want: lib.hasInfix " ${want} " exec || lib.hasSuffix " ${want}" exec;

  # Counted rather than merely found, so a duplicated entry -- which would inflate the apparent
  # pool without adding independence, the same failure tests/nts-servers.nix guards the source
  # list against -- is caught here too.
  occurrences = needle: haystack: builtins.length (lib.splitString needle haystack) - 1;

  serviceDrift =
    host:
    let
      text = unitOf host "time-correction.service";
      lines = trimmedLines text;
      execLines = lib.filter (l: lib.hasPrefix "ExecStart=" l) lines;
      exec = if execLines == [ ] then null else builtins.head execLines;

      expectedNts = lib.mapAttrsToList (
        name: p: flag "--nts" "${name}=${p.hostname}@${p.operator}"
      ) ntsServers.providers;

      expectedDoh = lib.mapAttrsToList (
        name: p:
        flag "--doh" "${name}=${p.hostname}@${
          lib.concatStringsSep "," ([ p.v4 ] ++ lib.optional (p ? v6) p.v6)
        }"
      ) dohStamps.providers;

      floor =
        let
          m = builtins.match ".* --floor (-?[0-9]+)( .*|)" exec;
        in
        if m == null then null else lib.toInt (builtins.head m);
    in
    if text == null then
      [ "${host}: has no time-correction.service, so the timer above triggers nothing" ]
    else if exec == null then
      [ "${host}: time-correction.service has no ExecStart line at all" ]
    else
      # More than one ExecStart on a Type=oneshot is legal systemd and would mean the unit runs
      # the binary twice with different arguments -- an accident of module merging rather than
      # anything intended, and one this check would otherwise report as a pass.
      lib.optional (builtins.length execLines != 1)
        "${host}: ${toString (builtins.length execLines)} ExecStart lines, expected exactly one: ${toString execLines}"
      ++ lib.concatMap (
        want: lib.optional (!(hasArg exec want)) "${host}: ExecStart is missing ${want}"
      ) (expectedNts ++ expectedDoh)
      # The counts, which is the half that catches a DROPPED entry rather than a changed one:
      # one `--nts` short of the provider list means the filterAttrs join in modules/time-sync.nix
      # let a hostname fall through while chrony kept using it.
      ++ lib.optional (occurrences " --nts " exec != builtins.length expectedNts)
        "${host}: ${toString (occurrences " --nts " exec)} --nts arguments, expected ${toString (builtins.length expectedNts)} (one per lib/nts-servers.nix entry)"
      ++ lib.optional (occurrences " --doh " exec != builtins.length expectedDoh)
        "${host}: ${toString (occurrences " --doh " exec)} --doh arguments, expected ${toString (builtins.length expectedDoh)} (one per lib/doh-stamps.nix provider)"
      ++ lib.concatMap (
        name:
        lib.optional (!(hasArg exec (flag name expectedFlags.${name})))
          "${host}: ExecStart does not carry ${flag name expectedFlags.${name}}"
      ) (builtins.attrNames expectedFlags)
      ++ (
        if floor == null then
          [
            "${host}: ExecStart carries no numeric --floor, so nothing bounds how far back a compromised provider could roll this clock"
          ]
        else
          lib.optional (floor < floorLowerBound)
            "${host}: --floor ${toString floor} is below ${toString floorLowerBound}, which is not a plausible build-time constant"
      );

  errors = lib.concatMap (host: timerDrift host ++ serviceDrift host) (builtins.attrNames hosts);
in
if errors != [ ] then
  throw ''
    The deployed time-correction units do not match the spec.

    ${lib.concatStringsSep "\n  " errors}

    Spec: "a separate service runs every hour and after boot", and "it chooses 2 distinct sets
    of providers, where each set contains a provider for DoH and a provider for NTS". The hourly
    run is also the check that DoH and NTS still work at all -- it does the whole exchange even
    where the clock is demonstrably fine, so a provider that stopped answering shows up as a
    failing unit while the host is still healthy enough to say so. Stretching the interval delays
    that discovery to the next cold boot, when nothing works and nobody can reach the box; losing
    a provider from the arguments shrinks the pool those two sets are drawn from without changing
    anything a running host would report.
  ''
else
  pkgs.runCommand "time-sync-deployed-check" { } ''
    echo "cadence and provider arguments verified on: ${toString (builtins.attrNames hosts)}" > $out
  ''
