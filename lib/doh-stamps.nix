# DoH upstreams for dnscrypt-proxy, as readable components.
#
# Components are the source of truth and the `sdns://` stamps are derived from them
# (lib/doh-stamp-encode.nix). It used to be the other way round -- eight opaque base64
# blobs -- which meant nobody could tell which resolvers were configured without running
# a decoder, and any consumer needing the address or hostname had to decode them
# (tests/doh-interceptor.nix needs exactly that). So the data now lives in the form its
# readers want, while dnscrypt-proxy still gets the stamps it demands (its [static]
# section accepts nothing else).
#
# Every stamp this repo has used is identical apart from the address and hostname
# (proto 0x02, props 4, no certificate hash, path /dns-query), so nothing is lost.
# tests/doh-stamp-encode.nix asserts the generated stamps still match the eight
# original literals byte for byte.
#
# ONE ADDRESS PER HOSTNAME is the constraint that shapes the list below, and it is
# dnscrypt-proxy's, not ours. A stamp's pinned address is not kept on the server entry:
# fetchDoHServerInfo stores it in a process-wide map keyed by the HOSTNAME
# (`saveCachedIP(host, ip, -1*time.Second)`, a single-element list, so it replaces), and
# the dialer only ever consults `loadCachedIPs(host)`. serversInfo.refresh() then probes
# the servers concurrently, one goroutine each. So two stamps sharing a hostname race for
# one slot, the winner decides the address BOTH of them dial, and the race is re-run at
# startup and at every cert_refresh_delay (four-hourly).
#
# What that costs, in the order it was learned:
#
#   * a "<name>-ipv4" entry can dial the v6 address and vice versa, so the family in a
#     name is a label, not a promise;
#   * on a single-family network each shared hostname is a coin flip, so the live pool can
#     reach ZERO -- and with no usable server dnscrypt-proxy does not SERVFAIL. Its
#     processIncomingQuery returns an empty response and the UDP/TCP listeners send
#     nothing, leaving a resolver that is active, holding 127.0.0.1:53, logging nothing
#     and answering nothing until the next refresh. That is the 2026-08-08 outage in
#     modules/doh.nix, and CI reproduced it on 2026-08-11 (rpi5-x86-doh-upstream: three
#     "-ipv4" servers dialing v6 literals, 60 digs timed out, the interceptor logged not
#     one upstream request).
#
# Upstream declines to fix it: DNSCrypt/dnscrypt-proxy#2913 (closed same day, no comments)
# asked for exactly the missing behaviour -- try every address pinned for a host -- and
# discussion #2914 has an independent report of the same coin flip, "either all four
# servers are declared as reachable, or just two IPv4 ones, or just one IPv4, or none".
# The maintainer's suggested workaround does not apply here: ipv4_servers/ipv6_servers are
# SourceIPv4/SourceIPv6 internally and filter SOURCE LISTS, while loadSources appends
# [static] entries unconditionally. #1861 (2021, fixed by stripping a port from the key)
# confirms the per-hostname key is deliberate.
#
# Hence `stampFamilies` on each provider below, and the count guard in
# tests/doh-endpoints.nix.
#
# There is deliberately no escape hatch for pasting a hand-written `sdns://` literal
# alongside the generated ones. A provider that does not fit the uniform shape -- one
# publishing a certificate hash, or needing different props or a different path -- has to
# be taught to lib/doh-stamp-encode.nix, because a pasted stamp would reach dnscrypt-proxy
# via `stamps` while being absent from `endpoints`: not golden-tested and not impersonated
# by tests/doh-interceptor.nix. Both eval guards (tests/doh-stamp-encode.nix and
# tests/doh-endpoints.nix) pin the full key set of `stamps`, so they reject such an entry
# anyway.
{ lib }:

let
  enc = import ./doh-stamp-encode.nix { inherit lib; };

  # IPv6 literals are bracketed everywhere they are used as a dial target, starting with
  # the stamp itself. tests/doh-endpoints.nix pins that.
  bracket = addr: "[${addr}]";

  # One provider -> one entry per STAMPED family, "<name>-ipv4" and/or "<name>-ipv6".
  #
  # `stampFamilies` is not the same question as "which addresses does this provider have":
  # every provider below carries both, because `providers` also feeds modules/time-sync.nix
  # (which dials the addresses itself, one after another, and so is unaffected by the
  # collision described in the header). Only dnscrypt-proxy's stamp set is family-limited,
  # and only because a hostname it sees twice cannot keep two addresses.
  entriesFor =
    name: p:
    lib.optionalAttrs (lib.elem "ipv4" p.stampFamilies) {
      "${name}-ipv4" = {
        inherit (p) hostname;
        addr = p.v4;
        family = "ipv4";
      };
    }
    // lib.optionalAttrs (lib.elem "ipv6" p.stampFamilies) {
      "${name}-ipv6" = {
        inherit (p) hostname;
        addr = bracket p.v6;
        family = "ipv6";
      };
    };
in
rec {
  # These are the providers' own well-known anycast addresses, far more stable than a
  # CDN-hosted hostname -- and if one ever does move, DNS breaks outright rather than
  # silently, because these are the box's only resolvers.
  #
  # The first four were verified reachable over HTTPS from the rpi5 on 2026-07-27: all
  # answered a DoH query with 200 in 62-128 ms. The four single-family ones were verified
  # over IPv4 on 2026-08-11 (200 in 121-250 ms, and each resolved doubleclick.net, i.e.
  # unfiltered -- which modules/doh.nix's require_nofilter and the props = 4 in
  # lib/doh-stamp-encode.nix both assert). Their IPv6 addresses are current AAAA records
  # as of the same date but NOT reachability-verified: neither a GitHub runner nor the
  # machine that added them has IPv6 egress. If one of them is wrong, the v6-only
  # guarantee below is the thing that quietly is not there, so re-check them from a
  # v6-capable host and record the date here.
  #
  # `stampFamilies` -- which families reach dnscrypt-proxy, per the header. The split is
  # the whole point of the list's shape and not a preference:
  #
  #   * cloudflare/mullvad/quad9/google are stamped in BOTH families and so collide, one
  #     address slot per hostname. They are kept dual anyway: on a dual-stack network
  #     either address works, and if upstream ever implements DNSCrypt/dnscrypt-proxy#2913
  #     they become eight usable entries with no change here.
  #   * dns4eu/odvr are stamped v4 ONLY and digitalgesellschaft/wikimedia v6 ONLY, so each
  #     of those hostnames appears in exactly one stamp and nothing can overwrite its
  #     pinned address. That is what makes "at least two upstreams work on a single-family
  #     network" true rather than probable, and it is what stops the pool reaching zero --
  #     the state in which dnscrypt-proxy answers nothing at all (see the header).
  #     tests/doh-endpoints.nix counts these, so the guarantee cannot be edited away by
  #     accident.
  providers = {
    cloudflare = {
      hostname = "cloudflare-dns.com";
      v4 = "1.1.1.1";
      v6 = "2606:4700:4700::1111";
      stampFamilies = [
        "ipv4"
        "ipv6"
      ];
    };
    mullvad = {
      hostname = "base.dns.mullvad.net";
      v4 = "194.242.2.2";
      v6 = "2a07:e340::2";
      stampFamilies = [
        "ipv4"
        "ipv6"
      ];
    };
    quad9 = {
      hostname = "dns10.quad9.net";
      v4 = "9.9.9.10";
      v6 = "2620:fe::10";
      stampFamilies = [
        "ipv4"
        "ipv6"
      ];
    };
    google = {
      hostname = "dns.google";
      v4 = "8.8.8.8";
      v6 = "2001:4860:4860::8888";
      stampFamilies = [
        "ipv4"
        "ipv6"
      ];
    };
    # DNS4EU (EU-funded, "unfiltered" profile -- the other joindns4.eu hostnames are the
    # filtering ones, so the hostname is load-bearing).
    dns4eu = {
      hostname = "unfiltered.joindns4.eu";
      v4 = "86.54.11.100";
      v6 = "2a13:1001::86:54:11:100";
      stampFamilies = [ "ipv4" ];
    };
    # CZ.NIC's ODVR.
    odvr = {
      hostname = "odvr.nic.cz";
      v4 = "193.17.47.1";
      v6 = "2001:148f:ffff::1";
      stampFamilies = [ "ipv4" ];
    };
    # Digitale Gesellschaft (CH).
    digitalgesellschaft = {
      hostname = "dns.digitale-gesellschaft.ch";
      v4 = "185.95.218.42";
      v6 = "2a05:fc84::42";
      stampFamilies = [ "ipv6" ];
    };
    # Wikimedia DNS. Answers general queries, but is published for reaching Wikimedia
    # projects, so it is the entry to replace first if a better-fitting v6 operator turns
    # up. Swapping in a second address of an operator already listed would not work: same
    # hostname, same collision.
    wikimedia = {
      hostname = "wikimedia-dns.org";
      v4 = "185.71.138.138";
      v6 = "2001:67c:930::1";
      stampFamilies = [ "ipv6" ];
    };
  };

  # { "cloudflare-ipv4" = { hostname; addr; family; }; ... }
  # Consumed by tests/doh-interceptor.nix (the addresses a test must impersonate) and,
  # via `stamps` below, by modules/doh.nix.
  endpoints = lib.foldl' (acc: name: acc // entriesFor name providers.${name}) { } (
    builtins.attrNames providers
  );

  # What dnscrypt-proxy's [static] section wants: { "<name>" = { stamp = "sdns://..."; }; }
  # Generated from `endpoints` alone, so the two key sets are identical by construction --
  # which is what tests/doh-endpoints.nix asserts and tests/doh-interceptor.nix relies on.
  stamps = lib.mapAttrs (_: e: { stamp = enc.mkDohStamp { inherit (e) addr hostname; }; }) endpoints;
}
