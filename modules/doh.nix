{ lib, ... }:

let
  doh = import ../lib/doh-stamps.nix { inherit lib; };
in

{
  services.dnscrypt-proxy = {
    enable = true;
    upstreamDefaults = false;
    settings = {
      # Info (1), not the default Notice (2). On 2026-08-08 dnscrypt-proxy stopped answering
      # on 127.0.0.1:53 for four hours while holding two reachable upstreams, and logged
      # NOTHING for the entire window -- the outage was only visible because
      # connectivity-watchdog probes the resolver directly. Info is where the two lines that
      # would have named it live: xtransport.go's "Unable to resolve [%s] using resolver ..."
      # and query_processing.go's SERVFAIL notice.
      #
      # Info is close to free on this host: the per-query call sites are all Debug (0), and
      # the Info sites that could be chatty belong to features that are off here --
      # plugin_forward (no forwarding rules), dnscrypt_certs (dnscrypt_servers = false),
      # plugin_dns64. What is left fires per refresh, i.e. four-hourly, or on errors.
      #
      # Debug is deliberately not the choice: it costs 3-5 lines per query (getOne logs its
      # WP2 candidate for every one), and it cannot be set from here anyway -- config_loader.go
      # silently downgrades log_level 0 to Info unless DEBUG is set in the environment.
      log_level = 1;
      listen_addresses = [
        "127.0.0.1:53"
        "[::1]:53"
      ];
      server_names = builtins.attrNames doh.stamps;
      ipv4_servers = true;
      ipv6_servers = true;
      dnscrypt_servers = false;
      doh_servers = true;
      require_dnssec = false;
      require_nolog = false;
      require_nofilter = true;
      cache = true;
      # Stamps are generated from the readable components in lib/doh-stamps.nix; the
      # props bits they carry are load-bearing here, since require_nofilter below
      # filters the pool on them.
      static = doh.stamps;
      # Answer OS/browser connectivity-check names from a static map so captive
      # portals can be detected and their login pages reached even while the DoH
      # upstreams are blocked. Passed as a Nix path so toJSON copies it to the
      # store (toString would emit the source path and break on the target).
      captive_portals.map_file = ../lib/captive-portals.txt;
    };
  };

  networking = {
    nameservers = lib.mkForce [
      "127.0.0.1"
      "::1"
    ];
    networkmanager.dns = lib.mkDefault "none";
    # NixOS configures no connectivity check by default, so KDE Plasma never
    # detects a portal. Probe detectportal.firefox.com (present in the map above):
    # it is dual-stack (real A and AAAA), so detection works on IPv6-only networks
    # too — captive.apple.com is IPv4-only and would fail there. Its /success.txt
    # returns the body "success\n"; NM does a prefix match, so "success" matches.
    # A redirect/different body flips NM to the "portal" state.
    #
    # This probe must stay on plaintext HTTP: portal detection works precisely because a
    # portal can hijack cleartext. Over HTTPS the interception fails at TLS and NM reports
    # LIMITED/NONE instead of PORTAL, so the login page is never offered. (NM runs on the
    # laptops only; the rpi5's connectivity-fallback deliberately probes nothing at all --
    # it reads local wifi association state, since that is the only thing its setup AP can
    # repair.)
    #
    # Kept on detectportal rather than moved to gstatic after the 2026-07-27 rot incident:
    # gstatic's answers are geo-load-balanced and rotated across three different addresses
    # within an hour when checked, so pinning it in lib/captive-portals.txt would create a
    # fresh instance of that same bug, while Fastly returns a stable dual-stack set.
    networkmanager.settings.connectivity = {
      uri = "http://detectportal.firefox.com/success.txt";
      response = "success";
      interval = 300;
    };
    nftables = {
      enable = true;
      tables."common-doh-egress" = {
        family = "inet";
        content = ''
          chain output {
            type filter hook output priority filter - 10; policy accept;
            ip daddr != 127.0.0.0/8 udp dport 53 reject
            ip daddr != 127.0.0.0/8 tcp dport 53 reject
            ip6 daddr != ::1 udp dport 53 reject
            ip6 daddr != ::1 tcp dport 53 reject
          }
        '';
      };
    };
  };
}
