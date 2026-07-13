{ config, lib, ... }:

{
  options.common.firewall.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Enable the common default-deny inbound firewall.";
  };

  config = lib.mkIf config.common.firewall.enable {
    networking.nftables = {
      enable = true;
      tables."common-firewall-pre" = {
        family = "inet";
        # Log rules must stay separate from the drops: a combined
        # "limit ... log ... drop" rule stops matching (and dropping) once the
        # rate limit is exceeded.
        content = ''
          chain input {
            type filter hook input priority filter - 10; policy accept;
            icmp type echo-request limit rate 30/minute burst 50 packets log prefix "refused ping: "
            icmpv6 type echo-request limit rate 30/minute burst 50 packets log prefix "refused ping: "
            icmp type echo-request drop
            icmpv6 type echo-request drop
          }
        '';
      };
    };

    networking.firewall = {
      enable = true;
      backend = "nftables";
      allowPing = false;
      allowedTCPPorts = [];
      allowedUDPPorts = [];
      # The nftables backend ignores logRefusedConnections (iptables-only), so
      # log by hand. These rules render at the end of the input-allow chain,
      # after every accept, so they see exactly the new connections that fall
      # through to the drop policy. Pings never get here: common-firewall-pre
      # drops them at an earlier hook priority, so it logs them itself above.
      extraInputRules = ''
        limit rate 30/minute burst 50 packets log prefix "refused connection: "
      '';
    };
  };
}
