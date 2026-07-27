# Eval-only guard on lib/doh-stamps.nix `endpoints` -- the probe targets
# modules/connectivity-fallback.nix takes as its connectivityCheck.endpoints default.
#
# Every connectivity-fallback VM test overrides that option (they need endpoints they can
# actually stand up), so nothing else exercises the default value at all. What breaks
# quietly if it drifts:
#
#   * an unbracketed IPv6 address makes `curl --resolve host:443:2606:4700:4700::1111`
#     parse the address's own colons as the port separator, so the probe fails for a
#     reason that has nothing to do with connectivity -- on a v4-only host that is
#     invisible, because the v4 endpoints answer first and the check reports online;
#   * a bracketed IPv4 address fails the same way in reverse;
#   * losing the ipv4-before-ipv6 ordering costs a v6-less host (the rpi5) a wasted
#     attempt on every check before it reaches a usable endpoint.
#
# Fails with `throw` during evaluation rather than at build time, and reads a source file
# rather than a derivation, so this stays usable from a pure `nix flake check`.
{ pkgs, dohStamps }:

let
  lib = pkgs.lib;

  endpoints = dohStamps.endpoints;
  names = builtins.attrNames endpoints;

  # The check's probe order is `lib.mapAttrsToList` over this attrset, i.e. sorted
  # attribute names -- the same list dnscrypt-proxy's server_names is built from.
  nameDrift =
    let
      want = builtins.attrNames dohStamps.stamps;
    in
    lib.optional (names != want)
      "endpoint names do not match the stamp names: endpoints ${toString names}, stamps ${toString want}";

  bracketed = addr: lib.hasPrefix "[" addr && lib.hasSuffix "]" addr;

  familyDrift = lib.concatMap (
    n:
    let
      e = endpoints.${n};
      isV6 = e.family == "ipv6";
      ok = if isV6 then bracketed e.addr else !(bracketed e.addr);
    in
    lib.optional (!ok) (
      if isV6 then
        "${n}: ipv6 addr must be bracketed for `curl --resolve`, got ${e.addr}"
      else
        "${n}: ipv4 addr must not be bracketed, got ${e.addr}"
    )
    ++ lib.optional (!(lib.elem e.family [ "ipv4" "ipv6" ])) "${n}: unknown family ${e.family}"
    ++ lib.optional (e.hostname == "") "${n}: empty hostname"
  ) names;

  # Per provider, the ipv4 entry must sort ahead of its ipv6 entry. Checked as a property
  # of the sorted name list rather than by re-deriving the naming scheme, so it still
  # holds if the scheme changes.
  orderDrift = lib.concatMap (
    n:
    let
      base = lib.removeSuffix "-ipv6" n;
      v4 = "${base}-ipv4";
      i = lib.lists.findFirstIndex (x: x == n) null names;
      j = lib.lists.findFirstIndex (x: x == v4) null names;
    in
    lib.optional (lib.hasSuffix "-ipv6" n && j != null && i != null && j > i)
      "${v4} must be probed before ${n} (the rpi5 has no global IPv6)"
  ) names;

  # A v4-only host must reach a usable endpoint on the very first attempt.
  firstDrift =
    let
      first = endpoints.${builtins.head names};
    in
    lib.optional (names != [ ] && first.family != "ipv4")
      "the first endpoint probed is ${first.family}; it must be ipv4";

  countDrift = lib.optional (
    builtins.length names < 4
  ) "only ${toString (builtins.length names)} endpoints: the point of the list is that no single operator's outage can make the host tear down its own network";

  errors = nameDrift ++ familyDrift ++ orderDrift ++ firstDrift ++ countDrift;
in
if errors != [ ] then
  throw ''
    lib/doh-stamps.nix endpoints are not usable as connectivity-check probe targets.

    ${lib.concatStringsSep "\n  " errors}

    These are the default for common.connectivityFallback.connectivityCheck.endpoints and
    no VM test covers the default value, so this eval check is the only thing standing
    between a malformed entry and a host that reports itself offline for a reason
    unrelated to connectivity.
  ''
else
  pkgs.runCommand "doh-endpoints-check" { } ''
    echo "${toString (builtins.length names)} probe endpoints verified" > $out
  ''
