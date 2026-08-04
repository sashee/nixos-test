# Eval-only guard on the five assertions in modules/time-sync.nix.
#
# Assertions are the only part of that module with no coverage at all. Nothing else in the suite
# ever evaluates it with a bad input: both VM tests configure it correctly by construction, and
# tests/time-sync-deployed.nix reads the units of two hosts that are also configured correctly.
# So an assertion that stopped firing -- an inverted comparison, a predicate that is now
# vacuously true after a refactor, one deleted along with the option it guarded -- would look
# exactly like one that never had to fire.
#
# That matters most for the two whose own failure is silent:
#
#   * `syncedMarker` must be `/run/<directory>/<file>`. chrony-wait declares its parent with
#     `RuntimeDirectory`, which takes ONE path component, so a marker nested any deeper is
#     created somewhere else and the ExecStartPost that writes it fails -- on a unit whose entire
#     output is that file. The predicate is `hasPrefix "/run/"` plus a `splitString` length of
#     exactly 4, which is the kind of off-by-one arithmetic that is wrong the moment nobody is
#     looking at it.
#   * `sample` must not exceed the distinct NTS operators or the DoH resolvers. Its RUNTIME twin
#     in `parse_args` is tested (`a_sample_cannot_exceed_the_distinct_operators` in main.rs), so
#     a host that tripped this would still fail visibly -- once an hour, on every host, forever,
#     instead of at build time. The Nix side is the half with no test.
#
# What is checked is that the predicate is FALSE for a bad input, not that a build throws.
# Reading `config.assertions` is how the NixOS module system itself is tested, it needs no
# `tryEval`, and it costs one `extendModules` per case rather than one full system evaluation --
# which matters here, since this repo's CI has been killed by the evaluator's heap before.
#
# Fails with `throw` during evaluation, so this stays usable from a pure `nix flake check`.
{ pkgs, nixpkgs }:

let
  lib = pkgs.lib;

  # A correctly configured host, and nothing more. system-metrics.nix is in the imports because
  # modules/time-sync.nix reads `config.common.systemMetrics.enable` to point the collector's
  # clock gate at chrony's marker; without it that reference is an undefined option rather than
  # anything to do with the assertions.
  base = nixpkgs.lib.nixosSystem {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [
      ../modules/time-sync.nix
      ../modules/system-metrics.nix
      {
        # A build-time constant, as flake.nix supplies from `nixpkgs.lastModified`. Any plausible
        # value does; nothing here depends on which.
        common.timeSync = {
          enable = true;
          floor = 1785000000;
        };
        fileSystems."/" = {
          device = "/dev/disk/by-label/nixos";
          fsType = "ext4";
        };
        boot.loader.grub.enable = false;
        system.stateVersion = "25.05";
      }
    ];
  };

  # The messages of the assertions that are currently unsatisfied. Not `system.build.toplevel`:
  # this is the list the module system would render into that failure, read directly, so no
  # derivation is instantiated and no unrelated assertion elsewhere in the tree can mask ours.
  failures = system: map (a: a.message) (lib.filter (a: !a.assertion) system.config.assertions);

  # `mkForce` throughout, because every value a case overrides is already defined at normal
  # priority in `base` -- a plain definition would be a merge conflict rather than a bad input.
  cases = [
    {
      name = "floor is unset";
      module = { lib, ... }: { common.timeSync.floor = lib.mkForce null; };
      want = "common.timeSync.floor must be set";
    }
    {
      name = "sample exceeds the distinct operators";
      # lib/nts-servers.nix has four servers across three operators (ptb1 and ptb2 are one), so
      # four is over the line for the operators while still being within the DoH resolver count.
      # Deliberately not a wild number: the interesting boundary is the one the operator field
      # exists to create, not an obviously impossible sample.
      module = { lib, ... }: { common.timeSync.sample = lib.mkForce 4; };
      want = "exceeds either the number of distinct";
    }
    {
      name = "the server list is empty";
      module = { lib, ... }: { common.timeSync.servers = lib.mkForce [ ]; };
      want = "chrony would start with no time source at all";
    }
    {
      name = "a server is not described by lib/nts-servers.nix";
      # chrony would happily use this name; time-correction could not, because it needs the
      # operator that file carries in order to know whether two answers are one source or two.
      module = { lib, ... }: {
        common.timeSync.servers = lib.mkForce [ "time.example.com" ];
      };
      want = "does not describe";
    }
    {
      name = "the synced marker is nested too deep for RuntimeDirectory";
      module = { lib, ... }: {
        common.timeSync.syncedMarker = lib.mkForce "/run/chrony-wait/inner/synchronized";
      };
      want = "must be of the form";
    }
    {
      name = "the synced marker is not under /run";
      # The other half of the same predicate. A marker on a persistent filesystem would survive
      # a reboot, so the gate it feeds would read "synchronised" on a host that has not
      # synchronised since -- the failure modules/system-metrics.nix calls out by name.
      module = { lib, ... }: {
        common.timeSync.syncedMarker = lib.mkForce "/var/lib/chrony-wait/synchronized";
      };
      want = "must be of the form";
    }
  ];

  # The positive control, and it is not a formality: if the base configuration already tripped a
  # time-sync assertion, every case below would find its expected message whatever the predicate
  # did, and the whole file would assert nothing.
  baselineDrift =
    let
      ours = lib.filter (m: lib.hasInfix "common.timeSync" m) (failures base);
    in
    lib.optional (ours != [ ])
      "a correctly configured host already fails a time-sync assertion, so every case below is vacuous: ${toString ours}";

  caseDrift = lib.concatMap (
    c:
    let
      got = failures (base.extendModules { modules = [ c.module ]; });
    in
    lib.optional (!(lib.any (m: lib.hasInfix c.want m) got))
      "${c.name}: no assertion failed with ${builtins.toJSON c.want}; unsatisfied assertions were ${
        if got == [ ] then "none at all" else builtins.toJSON got
      }"
  ) cases;

  errors = baselineDrift ++ caseDrift;
in
if errors != [ ] then
  throw ''
    modules/time-sync.nix no longer refuses configurations it is supposed to refuse.

    ${lib.concatStringsSep "\n  " errors}

    Each of these assertions guards something that fails quietly at runtime rather than loudly
    at build time: a clock with no rollback bound, a quorum that can never be assembled, a chrony
    with no source, a server time-correction cannot attribute to an operator, or a marker file
    written somewhere nothing reads.
  ''
else
  pkgs.runCommand "time-sync-assertions-check" { } ''
    echo "${toString (builtins.length cases)} time-sync assertions verified to fire" > $out
  ''
