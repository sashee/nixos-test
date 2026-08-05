{ config, lib, pkgs, ... }:

let
  cfg = config.common.irohSsh;

  pkg = pkgs.callPackage ../packages/iroh-ssh/package.nix { };

  secretPath = "${cfg.credentialDirectory}/iroh-secret";

  # Eval-time gate for the failsafe, same as connectivity-fallback: runtime
  # nft inserts only make sense when this host runs the nftables firewall.
  firewallManaged = config.networking.firewall.enable && config.networking.nftables.enable;

  # Marks the failsafe's runtime rule so open/close/monitoring all find it
  # unambiguously in `nft list chain inet nixos-fw input-allow`.
  failsafeComment = "iroh-ssh-failsafe";

  # Where the failsafe records the last time it held port 22 open (epoch
  # seconds). Read by modules/monitoring.nix's check_iroh_ssh so an engagement
  # that recovered between monitoring runs is still reported. Created via
  # StateDirectory on the failsafe unit.
  failsafeStateDir = "/var/lib/iroh-ssh-failsafe";

  # The canonical connect ticket: endpoint id only, no relay urls. Derived from
  # the secret alone (see packages/iroh-ssh/src/bin/iroh-ssh-ticket.rs), so it is
  # exactly the ticket operators distribute -- which is why the failsafe probes
  # this and nothing else. Published by the listener itself (ExecStartPre below),
  # so it always names the endpoint the running listener answers on. Readable
  # only by root (the failsafe) and the listener's own user; nothing else needs
  # it, and `sudo cat` is how an operator reads it.
  ticketPath = "/run/iroh-ssh/ticket";

  ticketScript = pkgs.writeShellApplication {
    name = "iroh-ssh-publish-ticket";
    runtimeInputs = [ pkg pkgs.coreutils ];
    text = ''
      # Written atomically: the failsafe reads this on a timer and must never
      # observe a half-written ticket. The trap matters because the derivation
      # can fail (an unreadable or malformed credential) between mktemp and mv,
      # which would otherwise litter the runtime directory on every retry. A
      # failure leaves the previous ticket in place, which is the fail-safe
      # outcome: a stale ticket with nothing answering on it reads as down.
      # Mode is left at mktemp's 0600 -- see ticketPath above.
      tmp="$(mktemp '${ticketPath}.XXXXXX')"
      trap 'rm -f "$tmp"' EXIT
      iroh-ssh-ticket > "$tmp"
      mv -f "$tmp" '${ticketPath}'
    '';
  };

  failsafeScript = pkgs.writeShellApplication {
    name = "iroh-ssh-failsafe";
    runtimeInputs = [ pkg pkgs.nftables pkgs.coreutils pkgs.gnugrep pkgs.gnused ];
    text = ''
      probe_interval=${toString cfg.failsafe.probeIntervalSeconds}
      recheck_interval=${toString cfg.failsafe.recheckIntervalSeconds}
      down=0

      # Liveness is a functional probe, not unit-state inspection: dial the
      # canonical ticket and expect sshd's banner back. Four bytes of "SSH-"
      # prove discovery, the QUIC handshake, the local forward, and sshd
      # answering — so a missing credential, a crash loop, a blocked relay,
      # unresolvable discovery, and a dead sshd all read as the same thing:
      # not ready. Nothing here depends on the listener's implementation at
      # all: the ticket is derived from the secret by unit wiring, never parsed
      # out of the listener's output, so the listener could be swapped for
      # stock dumbpipe unchanged.
      #
      # Probing the id-only ticket is the point, not an accident. It is what
      # operators hold, and it exercises discovery — the path a ticket with a
      # baked-in relay url would skip, hiding exactly the failure that leaves
      # a distributed ticket unresolvable.
      probe_ok() {
        # No file means the listener has not started with a provisioned
        # credential this boot, which correctly reads as not-ready.
        ticket="$(cat '${ticketPath}' 2>/dev/null || true)"
        [ -n "$ticket" ] || return 1
        # sshd speaks first, so nothing needs to be sent. head's early close
        # SIGPIPEs the connect tool — guard the pipeline; timeout bounds it.
        banner="$(timeout 15 iroh-ssh-connect "$ticket" </dev/null 2>/dev/null | head -c 4 || true)"
        [ "$banner" = "SSH-" ]
      }

      port_is_open() {
        # Capture instead of grep -q: an early-exit grep can SIGPIPE nft and
        # turn a found match into a non-zero pipeline under pipefail.
        [ -n "$(nft list chain inet nixos-fw input-allow | grep -F '${failsafeComment}' || true)" ]
      }

      record_engaged() {
        # Wall-clock on purpose (unlike the iteration-counted downtime below):
        # this timestamp only orders reports against monitoring's last run, it
        # never feeds the open/close decision. Refreshed on every down
        # iteration, not just on insert, so an engagement overlapping a
        # monitoring run still shows activity after that run's start and gets
        # reported by the next one.
        tmp="$(mktemp '${failsafeStateDir}/last-engaged.XXXXXX')"
        date +%s > "$tmp"
        mv -f "$tmp" '${failsafeStateDir}/last-engaged'
      }

      open_port() {
        record_engaged
        if ! port_is_open; then
          nft insert rule inet nixos-fw input-allow tcp dport 22 accept comment '"${failsafeComment}"'
          echo "iroh-ssh tunnel not answering for $down seconds: opened port 22"
        fi
      }

      close_port() {
        # Delete by handle; `nft -a` prints one rule per line with its handle.
        nft -a list chain inet nixos-fw input-allow \
          | sed -En 's/.*comment "${failsafeComment}".*# handle ([0-9]+)$/\1/p' \
          | while read -r handle; do
              nft delete rule inet nixos-fw input-allow handle "$handle"
              echo "iroh-ssh tunnel answering: closed port 22"
            done
      }

      # Two-rate loop: while probes succeed there is one iroh connection per
      # probe_interval (hourly by default); a failure switches to the fast
      # recheck_interval so the delaySeconds window is actually measurable
      # and a recovered tunnel closes port 22 promptly. The first probe runs
      # right away, so a credential-less boot (a missing ticket file, no
      # traffic) opens port 22 delaySeconds after boot, not an hour later.
      # Counting iterations is monotonic by construction: wall-clock jumps
      # (NTP, tests warping `date -s`) must not trip the failsafe early, so
      # no `date` arithmetic here.
      while true; do
        if probe_ok; then
          down=0
          close_port
          sleep "$probe_interval"
        else
          down=$((down + recheck_interval))
          if [ "$down" -ge ${toString cfg.failsafe.delaySeconds} ]; then
            # Re-checked every recheck while down: a firewall reload
            # atomically replaces the nixos-fw table, silently dropping the
            # runtime rule.
            open_port
          fi
          sleep "$recheck_interval"
        fi
      done
    '';
  };
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

        Rotate by pointing this at a *new* directory rather than overwriting the
        blob in place (docs/rpi5-rescue.md): the switch is then a reviewable
        config change that restarts the listener as a side effect, the old
        credential stays on disk, and reverting the commit converges the host
        back to the identity whose ticket the operator still holds.
      '';
    };

    failsafe = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Open firewall port 22 while the iroh tunnel has not been ready for
          delaySeconds (missing credential, crash loop, unreachable relay), so
          the operator can still ssh in over the local network and repair
          remote management; close it again as soon as the tunnel is ready.
          Only active when this host runs the nftables firewall.

          Readiness is measured on the operator's own connect path: the
          canonical id-only ticket, dialed through endpoint-id discovery. A
          discovery outage therefore also reads as not-ready -- correctly, since
          a distributed ticket is unresolvable then too, but it does make the
          failsafe fate-shared with n0 DNS (see delaySeconds).
        '';
      };

      delaySeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 900;
        description = ''
          Continuous not-ready seconds before port 22 is opened. Must exceed
          the self-healing window of a lost relay race at boot: a relay-less
          ticket makes probes depend on n0 DNS discovery, and dns.iroh.link
          serves not-found with a 600s negative TTL that LAN resolvers cache
          (observed ~11 min outage on the rpi5, 2026-07-18).
        '';
      };

      probeIntervalSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3600;
        description = ''
          Seconds between tunnel probes while the last probe succeeded. Each
          probe dials the host's own listener over iroh with an ephemeral
          key, so this is the steady-state relay traffic cadence.
        '';
      };

      recheckIntervalSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = ''
          Seconds between probes after a failure: measures the delaySeconds
          window, and bounds how quickly an engaged failsafe closes port 22
          once the tunnel answers again.
        '';
      };
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
        # Publish the canonical ticket the failsafe probes. Deliberately part of
        # *this* unit rather than a service of its own: it then derives the
        # ticket from the very credential the listener is about to load, so the
        # two can never name different endpoint ids. A blob written without a
        # restart therefore leaves the ticket matching the running listener and
        # the probe keeps succeeding -- rotation moves both or neither, which is
        # what makes a half-finished rotation harmless instead of pinning port 22
        # open forever against a healthy tunnel.
        #
        # ExecStartPre, so the ticket exists before the endpoint binds or waits
        # on a relay: a freshly provisioned host is probeable at once and a lost
        # relay race at boot cannot change what gets probed. The derivation is
        # offline by construction (a pure function of the key, no reactor -- see
        # iroh-ssh-ticket.rs), so nothing here needs the network.
        ExecStartPre = lib.getExe ticketScript;
        # RuntimeDirectoryPreserve keeps the ticket readable while the listener
        # is down, which is exactly when an operator is sshed in over the
        # failsafe's port-22 opening wanting to read it. Note that preserve plus
        # DynamicUser makes systemd put the real directory at
        # /run/private/iroh-ssh behind a 0700 root:root gate, with
        # /run/iroh-ssh a symlink into it -- so the ticket is root-only however
        # the mode below is set, and RuntimeDirectoryMode is belt-and-braces.
        # This unit's UMask=0077 leaves the file itself at 0600.
        RuntimeDirectory = "iroh-ssh";
        RuntimeDirectoryMode = "0700";
        RuntimeDirectoryPreserve = "yes";
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

    # Failsafe: while the tunnel is not ready, the host would be unreachable
    # for exactly the repairs that need it, so after delaySeconds of downtime
    # port 22 opens to the local network (sshd itself is key-only) and closes
    # the moment the tunnel is ready again. Runs as root (nft needs
    # CAP_NET_ADMIN); ordered after nftables.service because the nixos-fw
    # table must exist before rules can be inserted (see connectivity-fallback
    # for the full rationale on both the ordering and why the rule must live
    # in nixos-fw's own input-allow chain).
    systemd.services.iroh-ssh-failsafe = lib.mkIf (cfg.failsafe.enable && firewallManaged) {
      description = "Open firewall port 22 while the iroh SSH tunnel is down";
      wantedBy = [ "multi-user.target" ];
      # Deliberately *not* ordered after iroh-ssh.service, even though that is
      # what publishes the ticket this probes: the listener waits for
      # network-online.target, and the failsafe is the one thing that must run
      # when networking is broken. A missing ticket already reads as not-ready,
      # and at recheckIntervalSeconds against delaySeconds a few early failed
      # probes at boot cost nothing.
      after = [ "nftables.service" ];
      serviceConfig = {
        ExecStart = lib.getExe failsafeScript;
        Restart = "always";
        RestartSec = 5;
        StateDirectory = "iroh-ssh-failsafe";
      };
    };
  };
}
