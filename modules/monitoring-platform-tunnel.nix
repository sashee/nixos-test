{ config, lib, pkgs, ... }:

let
  cfg = config.common.mpTunnel;

  pkg = pkgs.callPackage ../packages/iroh-ssh/package.nix { };

  secretPath = "${cfg.server.credentialDirectory}/iroh-secret";
  ticketPath = "${cfg.client.credentialDirectory}/iroh-ticket";

  # The client's socket lives in a systemd-provisioned RuntimeDirectory, which
  # is named rather than pathed -- so the directory the option implies has to be
  # recovered from the path, and constrained to a shape RuntimeDirectory= can
  # actually express (see the assertion below).
  clientRuntimeDir = builtins.dirOf cfg.client.socketPath;
  clientRuntimeName = builtins.baseNameOf clientRuntimeDir;

  # Shared by both halves: same binary, same threat model, and nothing either
  # one does needs more than the other. Lifted from modules/iroh-ssh.nix, which
  # runs the same crate against a TCP target.
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
  options.common.mpTunnel = {
    # Two independent halves rather than one switch: they are the two ends of
    # one pipe, and the whole point of building it is that they stop sharing a
    # host. Today the rpi5 enables both.
    server = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Expose a local unix socket -- by default the monitoring platform's --
          over an iroh endpoint, so a collector elsewhere can reach it without
          an inbound port.

          This authenticates nobody: anyone holding the endpoint id can open the
          pipe. What is behind the socket does the authenticating, which for the
          monitoring platform is the API key its receiver already requires
          (SPEC.md §13). The endpoint id is an address, not a credential.
        '';
      };

      credentialDirectory = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Directory containing the systemd-creds-encrypted iroh secret key that
          gives this endpoint its identity. Required when enabled; left unset so
          a host cannot silently forget it.

          Must not be the directory {option}`common.irohSsh.credentialDirectory`
          uses. Rotate by pointing at a *new* directory rather than overwriting
          in place, for the reasons in modules/iroh-ssh.nix.
        '';
      };

      forwardTo = lib.mkOption {
        type = lib.types.str;
        default = config.services.monitoring-platform.socketPath;
        defaultText = lib.literalExpression "config.services.monitoring-platform.socketPath";
        description = ''
          The unix socket incoming streams are forwarded to. Wired from the
          receiver's own option rather than restating its default, so the two
          cannot drift apart.
        '';
      };

      forwardToGroup = lib.mkOption {
        type = lib.types.str;
        default = config.services.monitoring-platform.group;
        defaultText = lib.literalExpression "config.services.monitoring-platform.group";
        description = ''
          Group to join in order to reach {option}`forwardTo`. Not tidiness: the
          receiver's socket sits in a 0750 group-owned RuntimeDirectory, and that
          mode is the actual access control (SPEC.md §8.1).
        '';
      };
    };

    client = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Serve a local unix socket that forwards over iroh to the endpoint named
          by an encrypted ticket. Whatever connects to it reaches the far side's
          socket and needs to know nothing about iroh.
        '';
      };

      credentialDirectory = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Directory containing the systemd-creds-encrypted `iroh-ticket`: the
          address to dial, as printed by `iroh-ssh-ticket`. Required when enabled.

          Encrypted despite being public, because that is what makes moving the
          far side a credential swap: re-encrypt this blob with the new host's
          ticket and restart, with no change to this configuration at all.
        '';
      };

      socketPath = lib.mkOption {
        type = lib.types.path;
        default = "/run/mp-tunnel/upstream.sock";
        description = ''
          Where the tunnel listens. The socket is mode 0660 inside a 0750
          directory owned by the `mp-tunnel` group, so reaching it means joining
          that group -- the same arrangement the receiver's own socket uses.

          Must be one level under /run: the directory is provisioned by
          RuntimeDirectory=, which names a directory rather than taking a path.
        '';
      };
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.server.enable || cfg.server.credentialDirectory != null;
          message = "common.mpTunnel.server.credentialDirectory must be set when the monitoring-platform tunnel server is enabled.";
        }
        {
          assertion = !cfg.client.enable || cfg.client.credentialDirectory != null;
          message = "common.mpTunnel.client.credentialDirectory must be set when the monitoring-platform tunnel client is enabled.";
        }
        {
          # Two endpoints sharing a secret share an endpoint id, and both
          # listeners answer the same ALPN -- so a dialer could not say whether
          # it reached sshd or the receiver's socket, and the two would publish
          # over each other in discovery. Directories rather than blobs, because
          # that is the unit rotation moves.
          assertion =
            !(cfg.server.enable && (config.common ? irohSsh) && config.common.irohSsh.enable)
            || cfg.server.credentialDirectory != config.common.irohSsh.credentialDirectory;
          message = ''
            common.mpTunnel.server.credentialDirectory and common.irohSsh.credentialDirectory
            are the same directory, so both iroh endpoints on this host would load the same
            secret and answer on the same endpoint id. Give the tunnel its own directory
            (e.g. /etc/credentials/mp-tunnel/server) and its own generated key.
          '';
        }
        {
          assertion = !cfg.client.enable || clientRuntimeDir == "/run/${clientRuntimeName}";
          message = ''
            common.mpTunnel.client.socketPath is "${cfg.client.socketPath}", whose directory
            is not a single level under /run. The directory is created by RuntimeDirectory=,
            which names one, so the socket must live at /run/<name>/<file>.
          '';
        }
      ];
    }

    (lib.mkIf (cfg.server.enable || cfg.client.enable) {
      # `iroh-ssh-generate-secret` and `iroh-ssh-ticket` are how both blobs get
      # made; an operator provisioning this host needs them on PATH whether or
      # not the ssh tunnel is also enabled.
      environment.systemPackages = [ pkg ];
    })

    (lib.mkIf cfg.server.enable {
      systemd.services.mp-tunnel-server = {
        description = "Monitoring platform reachability over iroh";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        # The receiver's socket is not socket-activated, so it appears when the
        # service starts. Advisory only: the far side is dialed lazily, once per
        # incoming stream, so the receiver may restart underneath this unit
        # without it noticing.
        after = [ "network-online.target" "monitoring-platform.service" ];
        # Skip (instead of crash-loop) until the operator provisions the blob.
        unitConfig.ConditionPathExists = [ secretPath ];
        serviceConfig = hardening // {
          ExecStart = "${lib.getExe' pkg "iroh-uds-listen"} ${cfg.server.forwardTo}";
          LoadCredentialEncrypted = [ "iroh-secret:${secretPath}" ];
          # No state of its own, so nothing here needs a fixed uid. The group it
          # joins to reach the receiver is a real one, which is what matters.
          DynamicUser = true;
          SupplementaryGroups = [ cfg.server.forwardToGroup ];
          Restart = "always";
          RestartSec = 5;
        };
      };
    })

    (lib.mkIf cfg.client.enable {
      # A real user and group, not DynamicUser, for two reasons that both bite
      # hard. The socket has to be reachable by another service, and a dynamic
      # group exists only at runtime -- so the forwardToGroup assertion in the
      # collector's own module (it reads config.users.groups) fails at eval. And a dynamic
      # user's RuntimeDirectory can end up behind /run/private, a 0700 root:root
      # gate that no group membership gets through.
      users.users.mp-tunnel = {
        isSystemUser = true;
        group = "mp-tunnel";
        description = "Monitoring platform tunnel";
      };
      users.groups.mp-tunnel = { };

      systemd.services.mp-tunnel-client = {
        description = "Local socket forwarding to the monitoring platform over iroh";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        unitConfig.ConditionPathExists = [ ticketPath ];
        serviceConfig = hardening // {
          ExecStart = "${lib.getExe' pkg "iroh-uds-connect"} ${cfg.client.socketPath}";
          LoadCredentialEncrypted = [ "iroh-ticket:${ticketPath}" ];
          User = "mp-tunnel";
          Group = "mp-tunnel";
          # Left unpreserved on purpose, unlike iroh-ssh's: there is no artifact
          # here worth reading while the unit is down, and letting systemd take
          # the directory away means a restart cannot leave a stale socket inode
          # for the next start to reason about.
          RuntimeDirectory = clientRuntimeName;
          RuntimeDirectoryMode = "0750";
          Restart = "always";
          RestartSec = 5;
        };
      };
    })
  ];

  # Deliberately absent: any ordering between these units and mp-collector.
  # The collector starts with DefaultDependencies=false and Before= the time
  # daemons, so a dependency on a network-online unit closes an ordering cycle
  # through sysinit.target (see the note on testNodeCollectorApiKey in
  # flake.nix). It needs none: a socket that is missing or refusing is a
  # delivery failure it already buffers and retries through -- which it must do
  # regardless, since neither half of this tunnel can work before the clock is
  # set and relay TLS starts verifying.
}
