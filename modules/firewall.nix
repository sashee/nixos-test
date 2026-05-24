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
        content = ''
          chain input {
            type filter hook input priority filter - 10; policy accept;
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
    };
  };
}
