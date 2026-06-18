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
    };
  };

  networking = {
    nameservers = lib.mkForce [
      "127.0.0.1"
      "::1"
    ];
    networkmanager.dns = lib.mkDefault "none";
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
