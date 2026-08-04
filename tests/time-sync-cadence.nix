# Eval-only guard on the correction service's cadence, read off the DEPLOYED host configs.
#
# Spec: "a separate service runs every hour and after boot". Both halves are option defaults, and
# both are invisible to the VM tests that would otherwise cover them:
#
#   * tests/time-correction.nix overrides `interval` to 3h and asserts 3h, because a second timed
#     run landing mid-test would step the clock out from under subtests that place it by hand;
#   * tests/nts-sync.nix pushes `bootDelay` to 3h for the same reason, and drives the unit by hand.
#
# So no check sees the values a host actually ships. A drift here is silent in the worst way: the
# unit stays green, the timer stays armed, and the only symptom is that the hourly run which is
# supposed to catch a dead provider *while the host is still reachable* now happens daily, or the
# boot run that breaks the cold-boot deadlock waits an hour before trying.
#
# Read from the rendered timer rather than from `config.common.timeSync.*`: the option value being
# right is not the claim worth making -- the claim is that systemd is told it. That catches a
# module that stopped threading the option into the unit, which reading the option back cannot.
#
# Fails with `throw` during evaluation, so this stays usable from a pure `nix flake check`.
{ pkgs, hosts }:

let
  lib = pkgs.lib;

  # OnBootSec is the "after boot" half. A minute rather than zero: the run needs
  # network-online.target, and starting a DoH exchange the instant userspace comes up only means
  # waiting for the network inside the unit instead of in front of it.
  expected = {
    "OnBootSec" = "1min";
    "OnUnitActiveSec" = "1h";
  };

  timerOf =
    host: hosts.${host}.config.systemd.units."time-correction.timer".text or null;

  hostDrift =
    host:
    let
      text = timerOf host;
      lines = lib.splitString "\n" (if text == null then "" else text);
      has = directive: value: lib.elem "${directive}=${value}" (map lib.trim lines);
      present = directive: lib.any (l: lib.hasPrefix "${directive}=" (lib.trim l)) lines;
      actual =
        directive:
        toString (map lib.trim (lib.filter (l: lib.hasPrefix "${directive}=" (lib.trim l)) lines));
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

  errors = lib.concatMap hostDrift (builtins.attrNames hosts);
in
if errors != [ ] then
  throw ''
    The deployed time-correction timers do not match the spec's cadence.

    ${lib.concatStringsSep "\n  " errors}

    Spec: "a separate service runs every hour and after boot". The hourly run is also the check
    that DoH and NTS still work at all -- it does the whole exchange even where the clock is
    demonstrably fine, so a provider that stopped answering shows up as a failing unit while the
    host is still healthy enough to say so. Stretching the interval delays that discovery to the
    next cold boot, when nothing works and nobody can reach the box.
  ''
else
  pkgs.runCommand "time-sync-cadence-check" { } ''
    echo "cadence verified on: ${toString (builtins.attrNames hosts)}" > $out
  ''
