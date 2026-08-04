# Eval-only guard on lib/nts-servers.nix -- the list chrony's NTS sources are generated from.
#
# Nothing else exercises this attrset's shape, and every way it can drift fails silently on a
# running host:
#
#   * a hostname containing "pool" is emitted by nixpkgs' chrony module as a `pool` directive
#     rather than `server` (it matches on `hasInfix "pool"`), so chronyd resolves the name to
#     a rotating set instead of one host -- and NTS cookies are bound to a server identity, so
#     the cookie store thrashes while the clock still looks fine;
#   * too few servers, or too few distinct operators, makes "must use multiple servers to
#     detect incorrect servers" unenforceable: chrony cannot outvote a falseticker it has no
#     independent peer for, and four names belonging to one organisation are one source;
#   * a duplicate hostname inflates the apparent source count while adding no independence,
#     which is the same failure wearing a disguise;
#   * an empty or malformed hostname reaches chrony.conf verbatim and chronyd simply never
#     synchronises against it.
#
# Fails with `throw` during evaluation rather than at build time, and reads a source file
# rather than a derivation, so this stays usable from a pure `nix flake check`.
{ pkgs, ntsServers }:

let
  lib = pkgs.lib;

  providers = ntsServers.providers;
  names = builtins.attrNames providers;
  hostnames = ntsServers.hostnames;

  # Deliberately a substring test, not a label test: nixpkgs matches with `hasInfix "pool"`,
  # so "ntppool1.time.nl" trips it even though no DNS label is exactly "pool". Testing
  # anything narrower here would pass entries that nixpkgs then treats as a pool.
  poolDrift = lib.concatMap (
    n:
    lib.optional (lib.hasInfix "pool" providers.${n}.hostname)
      "${n}: hostname ${providers.${n}.hostname} contains \"pool\", which nixpkgs' chrony module turns into a `pool` directive instead of `server`"
  ) names;

  shapeDrift = lib.concatMap (
    n:
    let
      p = providers.${n};
    in
    lib.optional (p.hostname == "") "${n}: empty hostname"
    ++ lib.optional (p.operator or "" == "") "${n}: missing operator, so independence cannot be checked"
    ++ lib.optional (lib.hasPrefix "." p.hostname || lib.hasSuffix "." p.hostname)
      "${n}: malformed hostname ${p.hostname}"
    ++ lib.optional (!(lib.hasInfix "." p.hostname))
      "${n}: hostname ${p.hostname} is not fully qualified"
  ) names;

  duplicateDrift =
    let
      # Counted, not `subtractLists (unique xs) xs`: that removes every occurrence of every
      # name and so is empty whatever the input -- a check that always passes.
      dupes = lib.unique (lib.filter (h: lib.count (x: x == h) hostnames > 1) hostnames);
    in
    lib.optional (dupes != [ ])
      "duplicate hostnames ${toString dupes}: a repeated name adds a source to the count without adding one to the vote";

  countDrift = lib.optional (
    builtins.length names < 4
  ) "only ${toString (builtins.length names)} servers: chrony needs enough independent sources that one falseticker is outvoted rather than merely noticed";

  operatorDrift =
    let
      n = builtins.length ntsServers.operators;
    in
    lib.optional (n < 3)
      "only ${toString n} distinct operators (${toString ntsServers.operators}): servers sharing an operator share their outages and their lies, so they are one source for voting purposes";

  errors = poolDrift ++ shapeDrift ++ duplicateDrift ++ countDrift ++ operatorDrift;
in
if errors != [ ] then
  throw ''
    lib/nts-servers.nix is malformed.

    ${lib.concatStringsSep "\n  " errors}

    These generate services.chrony.servers on every host. No VM test covers the deployed
    values -- tests/nts-sync.nix runs against an impersonated server -- so this eval check is
    the only thing standing between a malformed entry and a host whose time sources are
    quietly not the ones the file appears to configure.
  ''
else
  pkgs.runCommand "nts-servers-check" { } ''
    echo "${toString (builtins.length names)} NTS servers across ${toString (builtins.length ntsServers.operators)} operators verified" > $out
  ''
