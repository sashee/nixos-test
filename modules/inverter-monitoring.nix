{ config, lib, pkgs, ... }:

# Polls a Voltronic-protocol solar inverter over a USB serial adapter and reports it over the
# same LOCAL unix socket every other producer posts to. Sibling of modules/system-metrics.nix:
# same receiver, same wire format (binary OTLP, logs signal, Events), same reason for being a
# Rust binary rather than a shell script.
#
# The difference that shapes this module is the lifecycle. system-metrics is a Type=oneshot on a
# timer; this is a long-running service, because finding the port costs tens of seconds of
# probing and the unit answers a fixed four-command cycle every minute. So the unit restarts on
# exit rather than being triggered, and -- unlike its sibling -- it CAN be watched by
# system-metrics' own `system.unit` record, since a long-running service that is `active` means
# something (see the `units` option there for why a oneshot cannot be).
#
# Two things this unit needs that the sibling's sandbox forbids outright, and that are the whole
# reason the hardening block below is not a copy of it: the character devices under /dev/ttyUSB*,
# and membership of the group that owns them.

let
  cfg = config.common.inverterMonitoring;

  pollArgs = [
    "--socket"
    cfg.socketPath
    "--dev-dir"
    cfg.devDir
    "--serial-by-path-dir"
    cfg.serialByPathDir
    "--serial-by-id-dir"
    cfg.serialByIdDir
    "--state-dir"
    cfg.stateDir
    "--interval-seconds"
    (toString cfg.intervalSeconds)
    "--static-refresh-seconds"
    (toString cfg.staticRefreshSeconds)
    "--bms-listen-seconds"
    (toString cfg.bmsListenSeconds)
    "--response-timeout-seconds"
    (toString cfg.responseTimeoutSeconds)
    "--discovery-window-seconds"
    (toString cfg.discoveryWindowSeconds)
  ]
  ++ lib.concatLists
    (lib.mapAttrsToList (k: v: [ "--resource-attr" "${k}=${v}" ]) cfg.resourceAttributes);

  # The same invocation the unit runs, on the operator's PATH, with `--once --dry-run` as the
  # obvious thing to type. On a headless box reached over the iroh tunnel that is the only way
  # to ask "what does the inverter say right now" without reading it back out of the store a
  # minute later -- and it works while the service is running, because it opens its own port.
  #
  # It does NOT work while the service holds the port: TIOCEXCL is exactly the protection that
  # makes this fail loudly rather than interleave half-frames with the daemon. Stop the unit
  # first; the error says so.
  pollCommand = pkgs.writeShellApplication {
    name = "inverter-monitoring";
    text = ''
      exec ${lib.escapeShellArgs ([ (lib.getExe cfg.package) ] ++ pollArgs)} "$@"
    '';
  };
in
{
  options.common.inverterMonitoring = {
    # Opt-in, like systemMetrics: it is only useful where an inverter is actually cabled up.
    enable = lib.mkEnableOption "polling a USB-attached inverter and reporting it to a local monitoring-platform receiver";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../packages/inverter-monitoring/package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ../packages/inverter-monitoring/package.nix { }";
      description = "The producer binary to run.";
    };

    socketPath = lib.mkOption {
      type = lib.types.path;
      default = "/run/monitoring-platform/monitoring-platform.sock";
      description = ''
        Unix socket to post to. Hosts should wire this from `services.mp-collector.socketPath`
        rather than restating it, for the same reason
        [](#opt-common.systemMetrics.socketPath) says so: it makes the receiver's location a
        property of one option on one service.

        Posting through the collector is also what makes the clock question go away. This
        service starts at boot and stamps a record a minute, and the Pi has no RTC -- so
        without the collector in the path its first samples would carry a timestamp months in
        the past, in a receiver whose SPEC lists retention as a non-goal. The collector holds
        them, rewrites the timestamps once the offset is known, and flushes them marked
        `mp.clock.uncertain` if sync never arrives. There is deliberately no
        `requireClockSync`-style gate here: it would throw away exactly the samples the
        collector exists to preserve.
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "monitoring-platform";
      description = ''
        Group this producer joins in order to reach the socket. Membership is the entire access
        control at either end (both runtime directories are 0750 and group-owned), so this must
        match whichever service owns [](#opt-common.inverterMonitoring.socketPath).
      '';
    };

    serialGroup = lib.mkOption {
      type = lib.types.str;
      default = "dialout";
      description = ''
        Group owning `/dev/ttyUSB*`. The unit runs as a `DynamicUser`, so this is how it gets
        read/write on the port at all -- the `DeviceAllow` below only narrows what the cgroup
        permits, it grants nothing.
      '';
    };

    devDir = lib.mkOption {
      type = lib.types.path;
      default = "/dev";
      description = ''
        Directory the `ttyUSB*` device nodes live in, and the source of truth for which
        adapters exist.

        Enumerating the devices rather than one of the `/dev/serial` link directories is
        deliberate. A device node exists per device; a udev link does not. `by-id` is built from
        the USB descriptors, and a chip that reports no serial number yields a name derived from
        vendor and product alone -- so two adapters of the same serial-less model produce one
        byte-identical name and collide onto a single symlink. This fleet's inverter is exactly
        that: a CH340 (`1a86:7523`) with an empty serial descriptor. Enumerating `by-id` would
        find one candidate for two devices.
      '';
    };

    serialByPathDir = lib.mkOption {
      type = lib.types.path;
      default = "/dev/serial/by-path";
      description = ''
        Directory of per-port serial device names. This is what a device is *keyed* by: the
        remembered-device hint, the `inverter.device` resource attribute and the probe ordering
        all match on it.

        by-path names the physical USB socket, so it is unique whatever the chip says about
        itself, and stable across reboots -- which `ttyUSB<N>` is not, those numbers being handed
        out in enumeration order. The cost is that moving the cable to a different socket
        invalidates the hint, which is one slow start, once.

        A device may have more than one link here: this fleet's Pi publishes both
        `platform-xhci-hcd.0-usb-0:1:1.0-port0` and a `-usbv2-` twin for the same port. The
        producer collapses those by taking the lexicographically smallest, so the plain form wins
        and the key cannot flip between boots.
      '';
    };

    serialByIdDir = lib.mkOption {
      type = lib.types.path;
      default = "/dev/serial/by-id";
      description = ''
        Directory of descriptor-derived serial device names, reported as
        `inverter.device_name`.

        Reported, never matched on -- see [](#opt-common.inverterMonitoring.devDir) for why it
        cannot be an identity. It is here because it is the name a human reading a query
        recognises (`usb-FTDI_FT232R_USB_UART_BG00Q7OM-if00-port0`) where a bus path is not.

        Re-read every cycle rather than resolved once at startup. Where two adapters collide on
        one name, udev re-picks the owner on any event touching either of them -- the coldplug
        backlog at boot, or the `udevadm trigger` a rebuild runs -- and a name remembered from
        before such a move would go on naming the adapter next door for the life of the process.
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/inverter-monitoring";
      description = ''
        Where the last-connected device is remembered, so the next start probes it first
        instead of walking every port. Losing this file costs a slower start and nothing else.
      '';
    };

    intervalSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = ''
        Seconds between poll cycles.

        Every cycle is one permanent row: the receiver has no retention, so a minute's cadence
        is ~525k rows a year from this one device, against the ~1.3M a year the 15-minute
        system-metrics batch produces. That is why the whole cycle is ONE record rather than
        one per subsystem -- ten records a minute would have been ~5.3M rows and roughly 3 GB a
        year on a 29 GB SD card. If the store becomes the binding constraint, this option is
        the first lever and it is linear.
      '';
    };

    staticRefreshSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3600;
      description = ''
        Seconds between re-reads of the five identity commands.

        protocol.md says these cannot change while the unit is powered, so in the ordinary case
        this changes nothing. Its value is the case that is not ordinary: a unit swapped behind
        the same adapter otherwise keeps reporting under the old serial number until something
        restarts the service.
      '';
    };

    bmsListenSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = ''
        How long each candidate port is listened to before anything is written to it.

        The inverter is half-duplex and never speaks unsolicited, so a port that says something
        first is something else on the bus -- on this host, the battery BMS. Worth the wall
        clock: the alternative is writing `QID` at a device whose command set is unknown. Note
        this is paid per candidate, so startup on a host with several adapters is a multiple of
        it.
      '';
    };

    responseTimeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = ''
        Deadline for one response frame.

        Cannot be small: at 2400 baud a byte is 4.17ms, so the 110-byte `QPIGS` frame is ~460ms
        of wire time before the device has even finished speaking. A timeout picked by
        intuition fires mid-frame and makes a healthy unit look mute.
      '';
    };

    discoveryWindowSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = ''
        How long to keep retrying discovery at startup before giving up and exiting.

        Covers the boot race, and nothing else. The adapter is enumerated by udev a few seconds
        into boot -- on the Pi, `ch341` binds about nine seconds in -- which is close enough to
        this unit's own start to lose sometimes. Losing it without this window means exiting and
        sitting out a full [](#opt-common.inverterMonitoring.restartSec) with an inverter that
        was plugged in the whole time.

        Deliberately not a reconnect loop: a port that was found and then lost is the fatal case
        and stays fatal.
      '';
    };

    restartSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 900;
      description = ''
        Seconds before systemd restarts the unit after it exits. 15 minutes per
        spec/features/inverter-monitoring/inverter-monitoring.md.

        Only reached for the failures the producer treats as fatal -- no inverter found, an I/O
        error on the port, or three consecutive cycles that read nothing. A bad CRC or a
        command that times out does not come here: it nulls its fields, moves
        `link_discarded_frames`, and the loop continues. Fifteen minutes of darkness is the
        right price for "the adapter is gone" and much too high a one for a flipped bit.
      '';
    };

    resourceAttributes = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { "site" = "budapest"; };
      description = ''
        Extra OTLP resource attributes attached to every record, queryable as
        `attr.resource.attributes.<key>`. `service.name`, `host.name`, `boot_id` and the
        `inverter.*` identity read off the unit itself are always sent.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.group != "";
        message = "common.inverterMonitoring.group must name the socket's owning group.";
      }
      {
        # The same trap systemMetrics guards: wiring socketPath from a service that is not
        # enabled leaves every cycle failing against a socket nothing is serving. Only checkable
        # where the collector's module is imported at all, hence the `?`.
        assertion = !(config.services ? mp-collector)
          || config.services.mp-collector.enable
          || cfg.socketPath != config.services.mp-collector.socketPath;
        message = ''
          common.inverterMonitoring posts to ${cfg.socketPath}, but services.mp-collector.enable
          is false on this host. Enable the collector, point
          common.inverterMonitoring.socketPath at a receiver directly, or disable
          common.inverterMonitoring.
        '';
      }
      {
        assertion = !(config.services ? mp-collector)
          || cfg.socketPath != config.services.mp-collector.socketPath
          || cfg.group == config.services.mp-collector.group;
        message = ''
          common.inverterMonitoring posts through the collector at ${cfg.socketPath} but joins
          the group "${cfg.group}", while that socket is owned by
          "${config.services.mp-collector.group}". Access is the mode on the containing runtime
          directory, so every cycle would fail on permissions. Wire
          common.inverterMonitoring.group from services.mp-collector.group.
        '';
      }
    ];

    environment.systemPackages = [ pollCommand ];

    systemd.services.inverter-monitoring = {
      description = "Poll the USB-attached inverter and report it to the local monitoring platform";
      wantedBy = [ "multi-user.target" ];

      # Ordering only. Both hops are named whichever one this host posts to -- ordering against
      # a unit that does not exist is a no-op -- and neither is a Requires: a receiver that is
      # down is a transient the producer logs and rides out, not a reason to refuse to start.
      after = [ "mp-collector.service" "monitoring-platform.service" ];

      # A [Unit] setting, NOT [Service] -- systemd parses the file per-section and silently
      # ignores an unknown key, so putting it below logged
      # "Unknown key 'StartLimitIntervalSec' in section [Service], ignoring" on the first real
      # deploy and left the default rate limit in force.
      #
      # Without it, systemd's default (5 starts in 10s) parks the unit in `failed` permanently
      # after a run of fast exits -- the exact scenario this service is designed to survive, and
      # a silent one. With RestartSec at 15 minutes the limit could never legitimately be
      # reached anyway, so this only matters when restartSec is turned down.
      unitConfig.StartLimitIntervalSec = 0;

      serviceConfig = {
        ExecStart = lib.escapeShellArgs ([ (lib.getExe cfg.package) ] ++ pollArgs);

        # Always, not on-failure: a clean exit is not a state this producer has. Anything that
        # ends the process is something restartSec should be waited out for.
        Restart = "always";
        RestartSec = cfg.restartSec;

        StateDirectory = "inverter-monitoring";
        StateDirectoryMode = "0700";

        DynamicUser = true;
        SupplementaryGroups = [ cfg.group cfg.serialGroup ];

        # NOT true: a private /dev has no /dev/ttyUSB* and no /dev/serial/by-id at all, so
        # discovery would find nothing on every host that has an inverter. The device cgroup
        # below is what narrows the access this opens back up -- setting DeviceAllow at all
        # switches the policy from "everything" to "these plus the standard pseudo-devices".
        PrivateDevices = false;
        DeviceAllow = [ "char-ttyUSB rw" ];

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallFilter = [ "@system-service" ];
        SystemCallArchitectures = "native";
        CapabilityBoundingSet = [ ];
        # The same kernel-enforced local-only guarantee the rest of the measurement path gives
        # itself: this producer speaks to one unix socket and one tty, and has no business
        # opening a network connection.
        RestrictAddressFamilies = [ "AF_UNIX" ];
      };
    };
  };
}
