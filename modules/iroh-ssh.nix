{ config, lib, pkgs, ... }:

let
  cfg = config.common.irohSsh;

  pkg = pkgs.callPackage ../packages/iroh-ssh/package.nix { };

  secretPath = "${cfg.credentialDirectory}/iroh-secret";
in
{
  options.common.irohSsh = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to expose the local sshd over an iroh tunnel.";
    };

    credentialDirectory = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Directory containing the systemd-creds-encrypted iroh secret key.
        Required when enabled; left unset so a host cannot silently forget it.
      '';
    };

  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.credentialDirectory != null;
        message = "common.irohSsh.credentialDirectory must be set when the iroh SSH tunnel is enabled (or set common.irohSsh.enable = false).";
      }
    ];

    # Access is via the tunnel; port 22 stays closed in the default-deny firewall.
    services.openssh.enable = lib.mkDefault true;
    services.openssh.openFirewall = lib.mkDefault false;

    # For the client side (`iroh-ssh-connect` in an ssh ProxyCommand) and for
    # generating the key (`iroh-ssh-generate-secret`).
    environment.systemPackages = [ pkg ];

    systemd.services.iroh-ssh = {
      description = "SSH reachability over iroh";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      # Skip (instead of crash-loop) until the operator provisions the blob.
      unitConfig.ConditionPathExists = [ secretPath ];
      serviceConfig = {
        # The listener reads the key from $CREDENTIALS_DIRECTORY/iroh-secret,
        # which systemd populates from the encrypted blob below, and forwards to
        # the local sshd (the binary's built-in 127.0.0.1:22 default). The
        # (public) connect ticket lands in the journal; the secret never touches argv.
        ExecStart = "${lib.getExe' pkg "iroh-ssh-listen"}";
        # Remote-access lifeline: come back even after a clean exit.
        Restart = "always";
        RestartSec = 5;
        # The key is a systemd-creds-encrypted blob on disk (create with
        # `systemd-creds encrypt --name=iroh-secret …`); systemd decrypts it
        # into $CREDENTIALS_DIRECTORY at runtime. Encrypted at rest; never in git/the store.
        LoadCredentialEncrypted = [ "iroh-secret:${secretPath}" ];
        DynamicUser = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        SystemCallFilter = [ "@system-service" "~@resources" ];
        SystemCallArchitectures = "native";
        MemoryDenyWriteExecute = true;
        ProcSubset = "pid";
        # AF_NETLINK: iroh's network monitor watches route/interface changes.
        # AF_UNIX: glibc NSS lookups go through the nscd socket on NixOS.
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_NETLINK" "AF_UNIX" ];
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        RemoveIPC = true;
        KeyringMode = "private";
        UMask = "0077";
      };
    };
  };
}
