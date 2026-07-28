# Eval-only guard on lib/doh-stamps.nix `endpoints` -- the components every DoH consumer
# in this repo is built from: dnscrypt-proxy's `sdns://` stamps (via
# lib/doh-stamp-encode.nix) and the addresses tests/doh-interceptor.nix has to impersonate.
#
# Nothing else exercises this attrset's shape. What breaks quietly if it drifts:
#
#   * an unbracketed IPv6 address is encoded into the stamp as-is, so dnscrypt-proxy dials
#     an address it cannot parse -- and on a v4-only host (the rpi5) that is invisible,
#     because the v4 resolvers answer and DNS keeps working;
#   * a bracketed IPv4 address fails the same way in reverse;
#   * a name whose "-ipv4"/"-ipv6" suffix disagrees with its `family` makes every consumer
#     that reads the suffix instead of the field -- and the sorted `server_names` order
#     dnscrypt-proxy is handed -- describe the wrong address family (see suffixDrift);
#   * a key set that diverges from `stamps` means an endpoint reaching dnscrypt-proxy while
#     being absent from the interceptor test's impersonation list.
#
# Fails with `throw` during evaluation rather than at build time, and reads a source file
# rather than a derivation, so this stays usable from a pure `nix flake check`.
{ pkgs, dohStamps }:

let
  lib = pkgs.lib;

  endpoints = dohStamps.endpoints;
  names = builtins.attrNames endpoints;

  # `server_names` is `lib.mapAttrsToList` over this attrset, i.e. sorted attribute names.
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
        "${n}: ipv6 addr must be bracketed everywhere it is used as a dial target, got ${e.addr}"
      else
        "${n}: ipv4 addr must not be bracketed, got ${e.addr}"
    )
    ++ lib.optional (!(lib.elem e.family [ "ipv4" "ipv6" ])) "${n}: unknown family ${e.family}"
    ++ lib.optional (e.hostname == "") "${n}: empty hostname"
  ) names;

  # The per-provider ipv4-before-ipv6 ordering is deliberately NOT asserted directly:
  # under the current naming scheme it cannot fail. Names are "<provider>-ipv4" and
  # "<provider>-ipv6", `mapAttrsToList` orders by sorted name, and '4' < '6' -- so a check
  # comparing the two indices would be testing the ASCII table, and would report success
  # while proving nothing.
  #
  # What any suffix-derived reasoning actually rests on is the suffix and the `family`
  # field agreeing. An entry named "cloudflare-ipv4" carrying family = "ipv6" is a v6
  # target that every reader of the name takes for a v4 one. familyDrift above only catches
  # that when the bracketing is wrong too, and a copy-paste that moves a whole entry gets
  # the bracketing right.
  suffixDrift = lib.concatMap (
    n:
    let
      e = endpoints.${n};
    in
    lib.optional (!(lib.hasSuffix "-${e.family}" n))
      "${n}: name suffix disagrees with family ${e.family}; every suffix-derived reader relies on the two matching"
  ) names;

  countDrift = lib.optional (
    builtins.length names < 4
  ) "only ${toString (builtins.length names)} endpoints: the point of the list is that no single operator's outage leaves this host without DNS";

  errors = nameDrift ++ familyDrift ++ suffixDrift ++ countDrift;
in
if errors != [ ] then
  throw ''
    lib/doh-stamps.nix endpoints are malformed.

    ${lib.concatStringsSep "\n  " errors}

    These generate dnscrypt-proxy's stamps and the addresses tests/doh-interceptor.nix
    impersonates, and no test covers the deployed values, so this eval check is the only
    thing standing between a malformed entry and a host whose resolvers are quietly not
    the ones the file appears to configure.
  ''
else
  pkgs.runCommand "doh-endpoints-check" { } ''
    echo "${toString (builtins.length names)} DoH endpoints verified" > $out
  ''
