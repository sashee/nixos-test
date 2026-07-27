# DoH upstreams for dnscrypt-proxy, as readable components.
#
# Components are the source of truth and the `sdns://` stamps are derived from them
# (lib/doh-stamp-encode.nix). It used to be the other way round -- eight opaque base64
# blobs -- which meant nobody could tell which resolvers were configured without running
# a decoder, and any consumer needing the address or hostname had to decode them.
# modules/connectivity-fallback.nix needs exactly that to probe these upstreams, so the
# data now lives in the form both consumers want, while dnscrypt-proxy still gets the
# stamps it demands (its [static] section accepts nothing else).
#
# Every stamp this repo has used is identical apart from the address and hostname
# (proto 0x02, props 4, no certificate hash, path /dns-query), so nothing is lost.
# tests/doh-stamp-encode.nix asserts the generated stamps still match the eight
# original literals byte for byte.
{ lib }:

let
  enc = import ./doh-stamp-encode.nix { inherit lib; };

  # IPv6 literals are bracketed everywhere they are used as a dial target: inside the
  # stamp, and in `curl --resolve host:443:[addr]`.
  bracket = addr: "[${addr}]";

  # One provider -> two entries, "<name>-ipv4" and "<name>-ipv6". The resulting attribute
  # names match the previous hand-written set exactly, so `server_names` (which is
  # `builtins.attrNames`, i.e. sorted) is unchanged.
  entriesFor =
    name: p:
    {
      "${name}-ipv4" = {
        inherit (p) hostname;
        addr = p.v4;
        family = "ipv4";
      };
    }
    // lib.optionalAttrs (p ? v6) {
      "${name}-ipv6" = {
        inherit (p) hostname;
        addr = bracket p.v6;
        family = "ipv6";
      };
    };
in
rec {
  # Verified reachable over HTTPS from the rpi5 on 2026-07-27: all four answered a DoH
  # query with 200 in 62-128 ms. These are the providers' own well-known anycast
  # addresses, far more stable than a CDN-hosted hostname -- and if one ever does move,
  # DNS breaks outright rather than silently, because these are the box's only resolvers.
  providers = {
    cloudflare = {
      hostname = "cloudflare-dns.com";
      v4 = "1.1.1.1";
      v6 = "2606:4700:4700::1111";
    };
    mullvad = {
      hostname = "base.dns.mullvad.net";
      v4 = "194.242.2.2";
      v6 = "2a07:e340::2";
    };
    quad9 = {
      hostname = "dns10.quad9.net";
      v4 = "9.9.9.10";
      v6 = "2620:fe::10";
    };
    google = {
      hostname = "dns.google";
      v4 = "8.8.8.8";
      v6 = "2001:4860:4860::8888";
    };
  };

  # Escape hatch: a provider that does not fit the uniform shape above -- one publishing a
  # certificate hash, or needing different props or a different path -- can be pasted here
  # verbatim as `name.stamp = "sdns://...";` and is merged into `stamps` untouched. The
  # golden test can only vouch for generated entries, so anything added here is on trust.
  extraStamps = { };

  # { "cloudflare-ipv4" = { hostname; addr; family; }; ... }
  # Consumed by modules/connectivity-fallback.nix (probe targets) and
  # tests/doh-interceptor.nix (the addresses a test must impersonate).
  endpoints = lib.foldl' (acc: name: acc // entriesFor name providers.${name}) { } (
    builtins.attrNames providers
  );

  # What dnscrypt-proxy's [static] section wants: { "<name>" = { stamp = "sdns://..."; }; }
  stamps =
    lib.mapAttrs (_: e: { stamp = enc.mkDohStamp { inherit (e) addr hostname; }; }) endpoints
    // extraStamps;
}
