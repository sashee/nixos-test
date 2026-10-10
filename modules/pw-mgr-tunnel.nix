{ config, lib, pkgs, ... }:

let
  cfg = config.common.pwMgrTunnel;

  pkg = pkgs.callPackage ../packages/iroh-ssh/package.nix { };

  secretPath = "${cfg.credentialDirectory}/iroh-secret";

  # Lifted from modules/monitoring-platform-tunnel.nix: the same binary forwarding to
  # the same kind of target, so the same threat model.
  hardening = {
    NoNewPrivileges = true;
    CapabilityBoundingSet = "";
    SystemCallFilter = [ "@system-service" "~@resources" ];
    SystemCallArchitectures = "native";
    MemoryDenyWriteExecute = true;
    ProcSubset = "pid";
    # AF_NETLINK: iroh's network monitor watches route/interface changes.
    # AF_UNIX: both the forwarded socket and glibc NSS lookups via nscd.
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
in
{
  options.common.pwMgrTunnel = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Expose the password manager's backend socket over an iroh endpoint: the
        "iroh path" of pw-mgr's backend/SPEC.md §3.1, and the only way its browsers
        reach it. The far end is a local shim on the device the browser runs on --
        socat in front of `iroh-uds-connect` on a laptop, iroh-webview-app on Android
        -- so the backend sees plain HTTP on `localhost` or `*.localhost`, which is a
        secure context and so lets WebAuthn and WebCrypto work.

        This authenticates nobody: anyone holding the endpoint id can open the pipe.
        The backend does the authenticating (passkeys; setup tokens for a new
        device), and its vault contents are end-to-end encrypted in the browser.
        The endpoint id is an address, not a credential.

        Only the server half lives here. Unlike the monitoring platform's tunnel,
        nothing on this host dials it.
      '';
    };

    credentialDirectory = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Directory containing the systemd-creds-encrypted iroh secret key that gives
        this endpoint its identity. Required when enabled; left unset so a host
        cannot silently forget it.

        Must not be the directory any other iroh endpoint on the host uses. Rotate by
        pointing at a *new* directory rather than overwriting in place, for the
        reasons in modules/iroh-ssh.nix -- and note that rotating changes the
        endpoint id, so every device's saved ticket has to be replaced.
      '';
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.enable || cfg.credentialDirectory != null;
          message = "common.pwMgrTunnel.credentialDirectory must be set when the pw-mgr tunnel is enabled.";
        }
        {
          assertion = !cfg.enable || config.services.pw-mgr.enable;
          message = "common.pwMgrTunnel is enabled but services.pw-mgr is not, so there is no socket to expose.";
        }
        {
          # The same reason as modules/monitoring-platform-tunnel.nix gives: every
          # listener answers the same ALPN, so two endpoints sharing a secret share an
          # endpoint id and a dialer could not tell sshd, the receiver and the vault
          # apart -- and they would publish over each other in discovery.
          assertion =
            let
              others =
                lib.optional (config.common ? irohSsh && config.common.irohSsh.enable)
                  config.common.irohSsh.credentialDirectory
                ++ lib.optional (config.common ? mpTunnel && config.common.mpTunnel.server.enable)
                  config.common.mpTunnel.server.credentialDirectory;
            in
            !cfg.enable || !(lib.elem cfg.credentialDirectory others);
          message = ''
            common.pwMgrTunnel.credentialDirectory is also used by another iroh endpoint on
            this host (common.irohSsh or common.mpTunnel.server), so both would load the
            same secret and answer on the same endpoint id. Give the pw-mgr tunnel its own
            directory (e.g. /etc/credentials/pw-mgr-tunnel) and its own generated key.
          '';
        }
      ];
    }

    (lib.mkIf cfg.enable {
      # `iroh-ssh-generate-secret` and `iroh-ssh-ticket` are how the blob and the
      # ticket every device saves get made.
      environment.systemPackages = [ pkg ];

      systemd.services.pw-mgr-tunnel = {
        description = "Password manager reachability over iroh";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        # Advisory only: the socket is dialed lazily, once per incoming stream, so the
        # backend may restart underneath this unit without it noticing.
        after = [ "network-online.target" "pw-mgr.service" ];
        # Skip (instead of crash-loop) until the operator provisions the blob.
        unitConfig.ConditionPathExists = [ secretPath ];
        serviceConfig = hardening // {
          ExecStart = "${lib.getExe' pkg "iroh-uds-listen"} ${config.services.pw-mgr.socketPath}";
          LoadCredentialEncrypted = [ "iroh-secret:${secretPath}" ];
          # No state of its own, so nothing here needs a fixed uid. The group it joins
          # is the backend's, whose socket directory mode is the actual access control.
          DynamicUser = true;
          SupplementaryGroups = [ config.services.pw-mgr.group ];
          Restart = "always";
          RestartSec = 5;
        };
      };
    })
  ];
}
