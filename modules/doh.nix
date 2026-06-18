{ lib, ... }:

let
  dohStamps = import ../lib/doh-stamps.nix;
in

{
  services.dnscrypt-proxy = {
    enable = true;
    upstreamDefaults = false;
    settings = {
      listen_addresses = [
        "127.0.0.1:53"
        "[::1]:53"
      ];
      server_names = builtins.attrNames dohStamps;
      ipv4_servers = true;
      ipv6_servers = true;
      dnscrypt_servers = false;
      doh_servers = true;
      require_dnssec = false;
      require_nolog = false;
      require_nofilter = true;
      cache = true;
      static = dohStamps;
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
    # detects a portal. Probe captive.apple.com (present in the map above, with
    # stable Apple IPs); NM does a prefix match on the body, so use Apple's full
    # success page. A redirect/different body flips NM to the "portal" state.
    networkmanager.settings.connectivity = {
      uri = "http://captive.apple.com/hotspot-detect.html";
      response = "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>";
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
