{ config, lib, pkgs, ... }:

# Passively reads the battery BMS on a USB serial adapter and reports it over the same LOCAL unix
# socket every other producer posts to. Sibling of modules/inverter-monitoring.nix: same receiver,
# same wire format (binary OTLP, logs signal, Events), same daemon lifecycle, same sandbox shape.
#
# The two differences that shape this module:
#
# 1. It never writes to the port, so it needs no write access to anything. The BMS auto-pushes
#    (protocol.md §1); there is no command set and nothing to ask.
# 2. It shares the `/dev/ttyUSB*` pool with inverter-monitoring, and both units start at boot. A
#    tty has one input queue and read(2) is destructive, so two readers get an arbitrary split of
#    the bytes rather than a copy each -- measured on the Pi, two readers over one 12s window got
#    1079 and 441 bytes and a corrupt frame each. The producers take an advisory flock on the device
#    node before they configure or read the line, which is what makes them safe to run together;
#    see packages/bms-monitoring/src/port.rs for why flock and TIOCEXCL are both there. Nothing in
#    this module arbitrates between them, and nothing needs to.
#
# There is no state directory, unlike the sibling. The inverter remembers which port answered so the
# next start probes it first; this producer has nothing to remember worth the file, because its
# probe is a passive listen -- a wrong guess costs a few seconds and touches nothing.

let
  cfg = config.common.bmsMonitoring;

  listenArgs = [
    "--socket"
    cfg.socketPath
    "--dev-dir"
    cfg.devDir
    "--serial-by-path-dir"
    cfg.serialByPathDir
    "--serial-by-id-dir"
    cfg.serialByIdDir
    "--interval-seconds"
    (toString cfg.intervalSeconds)
    "--settings-interval-seconds"
    (toString cfg.settingsIntervalSeconds)
    "--listen-seconds"
    (toString cfg.listenSeconds)
    "--frame-timeout-seconds"
    (toString cfg.frameTimeoutSeconds)
    "--discovery-window-seconds"
    (toString cfg.discoveryWindowSeconds)
  ]
  ++ lib.concatLists
    (lib.mapAttrsToList (k: v: [ "--resource-attr" "${k}=${v}" ]) cfg.resourceAttributes);

  # The same invocation the unit runs, on the operator's PATH, with `--once --dry-run` as the
  # obvious thing to type. On a headless box reached over the iroh tunnel that is the only way to
  # ask "what does the pack say right now" without reading it back out of the store a minute later.
  #
  # It does NOT work while the service holds the port, and says so rather than interleaving
  # half-frames with the daemon: the flock is what makes a second copy report the port busy. Stop
  # the unit first.
  listenCommand = pkgs.writeShellApplication {
    name = "bms-monitoring";
    text = ''
      exec ${lib.escapeShellArgs ([ (lib.getExe cfg.package) ] ++ listenArgs)} "$@"
    '';
  };
in
{
  options.common.bmsMonitoring = {
    # Opt-in, like the sibling producers: only useful where a BMS is actually cabled up.
    enable = lib.mkEnableOption "listening to a USB-attached BMS and reporting it to a local monitoring-platform receiver";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../packages/bms-monitoring/package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ../packages/bms-monitoring/package.nix { }";
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

        Posting through the collector is also what makes the clock question go away. This service
        starts at boot and stamps records a minute later, and the Pi has no RTC -- so without the
        collector in the path its first samples would carry a timestamp months in the past. The
        collector holds them, rewrites the timestamps once the offset is known, and flushes them
        marked `mp.clock.uncertain` if sync never arrives.
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "monitoring-platform";
      description = ''
        Group this producer joins in order to reach the socket. Membership is the entire access
        control at either end (both runtime directories are 0750 and group-owned), so this must
        match whichever service owns [](#opt-common.bmsMonitoring.socketPath).
      '';
    };

    serialGroup = lib.mkOption {
      type = lib.types.str;
      default = "dialout";
      description = ''
        Group owning `/dev/ttyUSB*`. The unit runs as a `DynamicUser`, so this is how it gets at
        the port at all -- the `DeviceAllow` below only narrows what the cgroup permits, it grants
        nothing.

        It is also what makes the port lock work as intended. `TIOCEXCL` is bypassed by
        `CAP_SYS_ADMIN`, and this unit has an empty `CapabilityBoundingSet`, so an opener from this
        sandbox is subject to it -- which is the case that matters, since the other opener is the
        sibling producer in an identical sandbox.
      '';
    };

    devDir = lib.mkOption {
      type = lib.types.path;
      default = "/dev";
      description = ''
        Directory the `ttyUSB*` device nodes live in, and the source of truth for which adapters
        exist.

        Enumerating the devices rather than one of the `/dev/serial` link directories is
        deliberate. A device node exists per device; a udev link does not. `by-id` is built from the
        USB descriptors, and a chip that reports no serial number yields a name derived from vendor
        and product alone -- so two adapters of the same serial-less model produce one
        byte-identical name and collide onto a single symlink. This fleet has exactly that adapter
        on the inverter (a CH340, `1a86:7523`), which is reason enough not to key on that directory.
      '';
    };

    serialByPathDir = lib.mkOption {
      type = lib.types.path;
      default = "/dev/serial/by-path";
      description = ''
        Directory of per-port serial device names. This is what a device is *keyed* by: the
        `bms.device` resource attribute matches on it.

        by-path names the physical USB socket, so it is unique whatever the chip says about itself,
        and stable across reboots -- which `ttyUSB<N>` is not, those numbers being handed out in
        enumeration order.

        A device may have more than one link here: this fleet's Pi publishes both
        `platform-xhci-hcd.0-usb-0:1:1.0-port0` and a `-usbv2-` twin for the same port. The producer
        collapses those by taking the lexicographically smallest, so the plain form wins and the key
        cannot flip between boots.
      '';
    };

    serialByIdDir = lib.mkOption {
      type = lib.types.path;
      default = "/dev/serial/by-id";
      description = ''
        Directory of descriptor-derived serial device names, reported as `bms.device_name`.

        Reported, never matched on -- see [](#opt-common.bmsMonitoring.devDir) for why it cannot be
        an identity. It is here because it is the name a human reading a query recognises
        (`usb-FTDI_FT232R_USB_UART_BG00Q7OM-if00-port0`) where a bus path is not.

        Re-read every cycle rather than resolved once at startup: where two adapters collide on one
        name, udev re-picks the owner on any event touching either of them, and a name remembered
        from before such a move would go on naming the adapter next door.
      '';
    };

    intervalSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = ''
        Seconds between realtime measurements, per
        spec/features/bms-monitoring/bms-monitoring.md.

        Every measurement is one permanent status row plus one per present cell, and the receiver
        has no retention: at this cadence a 16-cell pack is ~8.9M rows a year. That is a deliberate
        cost. The pack-level aggregates cannot say *which* cell is drifting, and by the time a
        divergence shows up in the average the answer matters -- so the per-cell rows are the point
        of monitoring a battery rather than an accident of the schema. If the SD card becomes the
        binding constraint, this option is the first lever and it is linear.
      '';
    };

    settingsIntervalSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 86400;
      description = ''
        Seconds between settings measurements. 24 hours per the spec, plus one at startup.

        The frame is nearly static, so consecutive rows are a configuration-change audit trail: the
        value is not any single row but the diff between two of them. Worth the daily 17 rows for
        the case where somebody changes a protection limit with the phone app and nothing else
        records that they did.
      '';
    };

    listenSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = ''
        How long each candidate port is listened to before it is rejected.

        Must exceed the ~6.7s frame cycle measured on the hardware, or a healthy BMS can miss its
        own window; ten seconds is the spec's value and leaves margin for one lost burst. Nothing is
        ever written to the port, so this is the whole of the probe -- and it is why a wrong guess
        is cheap here where the inverter's probe has to send `QID` at a device whose command set is
        unknown.

        Paid per candidate, so startup on a host with several adapters is a multiple of it.
      '';
    };

    frameTimeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = ''
        How long to wait for a frame before counting the measurement silent. Three consecutive
        silent measurements end the run.

        Cannot be small: frames arrive every ~6.7s, so a timeout picked by intuition fires between
        two healthy bursts. At the default, the port is declared dead only after ~90 seconds of
        complete silence -- over thirteen missed cycles -- which is the intended distance between
        "a burst was lost to noise" and "the adapter is gone".
      '';
    };

    discoveryWindowSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = ''
        How long to keep retrying discovery at startup before giving up and exiting.

        Covers two races, both of which resolve in seconds. The first is udev: this unit starts at
        boot and the adapter is enumerated a few seconds in. The second is
        [](#opt-common.inverterMonitoring.enable), which starts at the same moment and may be
        holding the port this producer wants while it probes it -- losing that coin toss without a
        window means exiting and sitting out a full
        [](#opt-common.bmsMonitoring.restartSec) with a healthy pack on the other end of the cable.
        Candidate order is shuffled, so a later sweep is unlikely to contend the same way.

        Deliberately not a reconnect loop: a port that was found and then lost is the fatal case
        and stays fatal.
      '';
    };

    restartSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 900;
      description = ''
        Seconds before systemd restarts the unit after it exits. 15 minutes per
        spec/features/bms-monitoring/bms-monitoring.md.

        Only reached for the failures the producer treats as fatal -- no BMS found, an I/O error on
        the port, or three consecutive measurements that saw no frame. A frame that fails its sum8
        does not come here: it is discarded, `link_frames_discarded` moves, and the loop continues.
        Fifteen minutes of darkness is the right price for "the adapter is gone" and much too high a
        one for a flipped bit -- especially on this line, where the interleaved RS485 traffic
        guarantees a steady supply of bytes that are not frames.
      '';
    };

    resourceAttributes = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { "site" = "budapest"; };
      description = ''
        Extra OTLP resource attributes attached to every record, queryable as
        `attr.resource.attributes.<key>`. `service.name`, `host.name`, `boot_id` and the `bms.device`
        port name are always sent.

        There is no pack identity to send alongside them, and that is a property of the protocol
        rather than an omission: the `0x03` device-info frame is never pushed and this producer never
        sends a request, so there is no serial number, model or firmware version to be had. If a
        deployment has more than one pack, this option is where a distinguishing label goes.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.group != "";
        message = "common.bmsMonitoring.group must name the socket's owning group.";
      }
      {
        # The same trap the sibling producers guard: wiring socketPath from a service that is not
        # enabled leaves every measurement failing against a socket nothing is serving. Only
        # checkable where the collector's module is imported at all, hence the `?`.
        assertion = !(config.services ? mp-collector)
          || config.services.mp-collector.enable
          || cfg.socketPath != config.services.mp-collector.socketPath;
        message = ''
          common.bmsMonitoring posts to ${cfg.socketPath}, but services.mp-collector.enable is
          false on this host. Enable the collector, point common.bmsMonitoring.socketPath at a
          receiver directly, or disable common.bmsMonitoring.
        '';
      }
      {
        assertion = !(config.services ? mp-collector)
          || cfg.socketPath != config.services.mp-collector.socketPath
          || cfg.group == config.services.mp-collector.group;
        message = ''
          common.bmsMonitoring posts through the collector at ${cfg.socketPath} but joins the group
          "${cfg.group}", while that socket is owned by
          "${config.services.mp-collector.group}". Access is the mode on the containing runtime
          directory, so every measurement would fail on permissions. Wire
          common.bmsMonitoring.group from services.mp-collector.group.
        '';
      }
      {
        # The listen window has to outlast the frame cycle, or discovery rejects a healthy pack.
        # Measured at ~6.7s on the hardware; 7 is the smallest integer that clears it.
        assertion = cfg.listenSeconds >= 7;
        message = ''
          common.bmsMonitoring.listenSeconds is ${toString cfg.listenSeconds}, which is shorter than
          the BMS's ~6.7s frame cycle (spec/features/bms-monitoring/protocol.md §2). Discovery would
          reject a healthy pack for saying nothing. Use at least 7; the spec's value is 10.
        '';
      }
      {
        assertion = cfg.frameTimeoutSeconds >= cfg.listenSeconds;
        message = ''
          common.bmsMonitoring.frameTimeoutSeconds (${toString cfg.frameTimeoutSeconds}) is shorter
          than listenSeconds (${toString cfg.listenSeconds}): a port good enough to attach to would
          then be declared silent while monitoring it.
        '';
      }
    ];

    environment.systemPackages = [ listenCommand ];

    systemd.services.bms-monitoring = {
      description = "Listen to the USB-attached BMS and report it to the local monitoring platform";
      wantedBy = [ "multi-user.target" ];

      # Ordering only. Both hops are named whichever one this host posts to -- ordering against a
      # unit that does not exist is a no-op -- and neither is a Requires: a receiver that is down is
      # a transient the producer logs and rides out, not a reason to refuse to start.
      #
      # Deliberately NOT ordered against inverter-monitoring. The two contend for the same ports and
      # the flock is what resolves that; an ordering would only make the loser's wait deterministic
      # without making it shorter, and it would tie two units together that have no dependency.
      after = [ "mp-collector.service" "monitoring-platform.service" ];

      # A [Unit] setting, NOT [Service] -- systemd parses the file per-section and silently ignores
      # an unknown key, which on the sibling produced "Unknown key 'StartLimitIntervalSec' in
      # section [Service], ignoring" on its first real deploy and left the default rate limit in
      # force.
      #
      # Without it, systemd's default (5 starts in 10s) parks the unit in `failed` permanently after
      # a run of fast exits -- the exact scenario this service is designed to survive, and a silent
      # one.
      unitConfig.StartLimitIntervalSec = 0;

      serviceConfig = {
        ExecStart = lib.escapeShellArgs ([ (lib.getExe cfg.package) ] ++ listenArgs);

        # Always, not on-failure: a clean exit is not a state this producer has. Anything that ends
        # the process is something restartSec should be waited out for.
        Restart = "always";
        RestartSec = cfg.restartSec;

        DynamicUser = true;
        SupplementaryGroups = [ cfg.group cfg.serialGroup ];

        # NOT true: a private /dev has no /dev/ttyUSB* and no /dev/serial/by-path at all, so
        # discovery would find nothing on every host that has a BMS. The device cgroup below is what
        # narrows the access this opens back up -- setting DeviceAllow at all switches the policy
        # from "everything" to "these plus the standard pseudo-devices".
        PrivateDevices = false;
        # `r` rather than `rw`: this producer only ever listens, and the cgroup is where that can be
        # enforced rather than merely intended. Note it does not stop the flock or the termios call,
        # both of which work on a read-only fd.
        DeviceAllow = [ "char-ttyUSB r" ];

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
        # itself: this producer speaks to one unix socket and one tty, and has no business opening a
        # network connection.
        RestrictAddressFamilies = [ "AF_UNIX" ];
      };
    };
  };
}
