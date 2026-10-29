# The "iroh path" of backend/SPEC.md §3.1 in sashee/e2ee-store, for one app built on it: an iroh
# endpoint forwarding to the app's backend socket. Every app runs the same backend behind the same
# kind of socket, so only the names differ; each app's tunnel is a one-line module applying this
# (modules/pw-mgr-tunnel.nix, modules/media-store-tunnel.nix).
#
#   app:         the app's module and instance name: services.<app>, <app>.service, <app>-tunnel.service
#   option:      the option set under `common`, e.g. "pwMgrTunnel"
#   title:       what the app is, for the option descriptions, e.g. "the password manager"
#   description: the unit's Description=
{ app, option, title, description }:
{ config, lib, pkgs, ... }:

let
  cfg = config.common.${option};

  backend = config.services.${app};

  pkg = pkgs.callPackage ../packages/iroh-ssh/package.nix { };

  secretPath = "${cfg.credentialDirectory}/iroh-secret";

  # Every e2ee-store app's tunnel, this one included: the secrets of all of them have to differ.
  appTunnels = [ "pwMgrTunnel" "mediaStoreTunnel" ];

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
  options.common.${option} = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Expose the backend socket of ${title} (${app}) over an iroh endpoint: the
        "iroh path" of backend/SPEC.md §3.1 in sashee/e2ee-store (the backend ${app}
        runs on), and the only way its browsers reach it. The far end is a local shim
        on the device the browser runs on -- socat in front of `iroh-uds-connect` on a
        laptop, iroh-webview-app on Android -- so the backend sees plain HTTP on
        `localhost` or `*.localhost`, which is a secure context and so lets WebAuthn
        and WebCrypto work.

        This authenticates nobody: anyone holding the endpoint id can open the pipe.
        The backend does the authenticating (passkeys; setup tokens for a new
        device), and what it stores is end-to-end encrypted in the browser.
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
          message = "common.${option}.credentialDirectory must be set when the ${app} tunnel is enabled.";
        }
        {
          assertion = !cfg.enable || backend.enable;
          message = "common.${option} is enabled but services.${app} is not, so there is no socket to expose.";
        }
        {
          # The same reason as modules/monitoring-platform-tunnel.nix gives: every
          # listener answers the same ALPN, so two endpoints sharing a secret share an
          # endpoint id and a dialer could not tell sshd, the receiver and the apps
          # apart -- and they would publish over each other in discovery.
          assertion =
            let
              others =
                lib.optional (config.common ? irohSsh && config.common.irohSsh.enable)
                  config.common.irohSsh.credentialDirectory
                ++ lib.optional (config.common ? mpTunnel && config.common.mpTunnel.server.enable)
                  config.common.mpTunnel.server.credentialDirectory
                ++ map (other: config.common.${other}.credentialDirectory) (lib.filter
                  (other: other != option && config.common ? ${other} && config.common.${other}.enable)
                  appTunnels);
            in
            !cfg.enable || !(lib.elem cfg.credentialDirectory others);
          message = ''
            common.${option}.credentialDirectory is also used by another iroh endpoint on
            this host (common.irohSsh, common.mpTunnel.server or another app's tunnel), so
            both would load the same secret and answer on the same endpoint id. Give the
            ${app} tunnel its own directory (e.g. /etc/credentials/${app}-tunnel) and its own
            generated key.
          '';
        }
      ];
    }

    (lib.mkIf cfg.enable {
      # `iroh-ssh-generate-secret` and `iroh-ssh-ticket` are how the blob and the
      # ticket every device saves get made.
      environment.systemPackages = [ pkg ];

      systemd.services."${app}-tunnel" = {
        inherit description;
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        # Advisory only: the socket is dialed lazily, once per incoming stream, so the
        # backend may restart underneath this unit without it noticing.
        after = [ "network-online.target" "${app}.service" ];
        # Skip (instead of crash-loop) until the operator provisions the blob.
        unitConfig.ConditionPathExists = [ secretPath ];
        serviceConfig = hardening // {
          ExecStart = "${lib.getExe' pkg "iroh-uds-listen"} ${backend.socketPath}";
          LoadCredentialEncrypted = [ "iroh-secret:${secretPath}" ];
          # No state of its own, so nothing here needs a fixed uid. The group it joins
          # is the backend's, whose socket directory mode is the actual access control.
          DynamicUser = true;
          SupplementaryGroups = [ backend.group ];
          Restart = "always";
          RestartSec = 5;
        };
      };
    })
  ];
}
