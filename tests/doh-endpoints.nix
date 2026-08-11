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
#     being absent from the interceptor test's impersonation list;
#   * a provider list in which every hostname is stamped in both families leaves each
#     hostname's dialled address to a race (lib/doh-stamps.nix header), and a
#     single-family network then has no upstream it can rely on -- see guaranteeDrift,
#     which is the only thing in the repo that would notice.
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

  # --- the per-family guarantee ------------------------------------------------------
  #
  # dnscrypt-proxy keeps ONE pinned address per DoH hostname (see the header of
  # lib/doh-stamps.nix), so two stamps sharing a hostname decide by race which address
  # both of them dial. An endpoint is therefore only DEPENDABLY on its own family if no
  # other stamp claims its hostname -- and what the shape of the provider list buys is
  # that enough such endpoints exist in each family.
  #
  # Deliberately NOT "every hostname is unique": cloudflare/mullvad/quad9/google are
  # stamped in both families on purpose, as upside for the day upstream implements
  # DNSCrypt/dnscrypt-proxy#2913. Asserting uniqueness would forbid that; asserting the
  # count below permits it while keeping the property the duals cannot provide.
  #
  # Two, not one, because the floor has to survive one operator's own outage -- the same
  # reasoning as countDrift above, applied per family instead of to the total.
  providers = dohStamps.providers;
  providerNames = builtins.attrNames providers;
  families = [
    "ipv4"
    "ipv6"
  ];

  # Every family every provider stamps for a hostname, so a hostname claimed twice is
  # visible here even if the two claims come from different providers.
  familiesByHost = lib.foldl' (
    acc: p:
    acc
    // {
      ${p.hostname} = (acc.${p.hostname} or [ ]) ++ p.stampFamilies;
    }
  ) { } (lib.attrValues providers);

  soleFor =
    family:
    lib.filter (
      n:
      let
        p = providers.${n};
      in
      lib.elem family p.stampFamilies && familiesByHost.${p.hostname} == [ family ]
    ) providerNames;

  guaranteeDrift = lib.concatMap (
    family:
    let
      sole = soleFor family;
    in
    lib.optional (builtins.length sole < 2) ''
      only ${toString (builtins.length sole)} ${family} endpoint(s) whose hostname is stamped in ${family} alone (${toString sole}): every other ${family} entry shares its hostname with the other family, so which address it dials is decided by a race inside dnscrypt-proxy and a ${family}-only network can end up with no usable upstream at all -- at which point the resolver answers nothing and logs nothing (lib/doh-stamps.nix header). Give at least two providers stampFamilies = [ "${family}" ]''
  ) families;

  # Guards on `stampFamilies` itself, kept apart from everything above because they are
  # what stops lib/doh-stamps.nix from throwing `attribute 'v6' missing` from inside
  # entriesFor -- a message that names neither the file nor the provider at fault. They
  # therefore have to be reported BEFORE anything that forces `endpoints`.
  stampDrift = lib.concatMap (
    n:
    let
      p = providers.${n};
      unknown = lib.subtractLists families (p.stampFamilies or [ ]);
    in
    lib.optional (!(p ? stampFamilies))
      "${n}: no stampFamilies; it decides which families reach dnscrypt-proxy and has no safe default (both families is what collides)"
    ++ lib.optionals (p ? stampFamilies) (
      lib.optional (p.stampFamilies == [ ]) "${n}: stampFamilies is empty, so this provider reaches dnscrypt-proxy not at all"
      ++ lib.optional (unknown != [ ]) "${n}: unknown stampFamilies ${toString unknown}; known families are ${toString families}"
      ++ lib.optional (lib.elem "ipv4" p.stampFamilies && !(p ? v4)) "${n}: stamped ipv4 without a v4 address"
      ++ lib.optional (lib.elem "ipv6" p.stampFamilies && !(p ? v6)) "${n}: stamped ipv6 without a v6 address"
    )
  ) providerNames;

  errors = nameDrift ++ familyDrift ++ suffixDrift ++ countDrift ++ guaranteeDrift;
in
if stampDrift != [ ] then
  throw ''
    lib/doh-stamps.nix providers have a malformed stampFamilies.

    ${lib.concatStringsSep "\n  " stampDrift}

    stampFamilies selects which of a provider's addresses become dnscrypt-proxy stamps.
    Reported on its own, ahead of the endpoint checks below, because entriesFor reads the
    address a family names and would otherwise fail first with an unattributed
    `attribute ... missing`.
  ''
else
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
    ${lib.concatMapStringsSep "\n" (
      family: "echo '${family}: ${toString (builtins.length (soleFor family))} endpoint(s) on an unshared hostname' >> $out"
    ) families}
  ''
