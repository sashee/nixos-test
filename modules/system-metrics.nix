{ config, lib, pkgs, ... }:

# Periodically reports this host's own CPU, memory, filesystem usage and NixOS generation to a
# LOCAL monitoring-platform receiver over its unix socket -- the first producer for what was
# until now an empty receiver (upstream's remote iroh transport has not landed).
#
# Not to be confused with modules/monitoring.nix, which reports host *health* outward to a
# Healthchecks URL and alerts on it. This module makes no judgements: it collects numbers and
# stores them, so history exists to look at later.
#
# The receiver only accepts binary OTLP (protobuf, logs signal, Events), so the producer cannot
# be a shell script -- it is a small Rust binary in packages/system-metrics built on the same
# opentelemetry-proto crate the receiver decodes with.

let
  cfg = config.common.systemMetrics;

  excludeArgs = lib.concatMap (t: [ "--exclude-fstype" t ]) cfg.excludeFsTypes;
  resourceArgs =
    lib.concatLists (lib.mapAttrsToList (k: v: [ "--resource-attr" "${k}=${v}" ]) cfg.resourceAttributes);

  collectArgs = [
    "--socket"
    cfg.socketPath
    "--cpu-sample-seconds"
    (toString cfg.cpuSampleSeconds)
  ] ++ excludeArgs ++ resourceArgs;

  # The same invocation the timer runs, on the operator's PATH. `system-metrics --dry-run`
  # prints the batch the next run would send without sending it, which on a headless box
  # reached over the iroh tunnel is the only way to ask "what does it think the disk looks
  # like" without waiting for a tick. Built from collectArgs so the two cannot drift.
  collectCommand = pkgs.writeShellApplication {
    name = "system-metrics";
    text = ''
      exec ${lib.escapeShellArgs ([ (lib.getExe cfg.package) ] ++ collectArgs)} "$@"
    '';
  };
in
{
  options.common.systemMetrics = {
    # Opt-in, unlike most common.* features: it is only useful where a receiver is actually
    # listening, so the hosts that run one turn it on explicitly.
    enable = lib.mkEnableOption "reporting host metrics to a local monitoring-platform receiver";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../packages/system-metrics/package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ../packages/system-metrics/package.nix { }";
      description = "The collector binary to run.";
    };

    socketPath = lib.mkOption {
      type = lib.types.path;
      default = "/run/monitoring-platform/monitoring-platform.sock";
      description = ''
        Unix socket of the receiver. Hosts should wire this from
        `services.monitoring-platform.socketPath` rather than restating the default.
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "monitoring-platform";
      description = ''
        Group the collector joins in order to reach the socket. Membership is the receiver's
        entire access control (its runtime directory is 0750 and group-owned), so this must
        match `services.monitoring-platform.group`.
      '';
    };

    resourceAttributes = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { "device.id" = "rpi5-budapest"; };
      description = ''
        Extra OTLP resource attributes attached to every record, queryable as
        `attr.resource.attributes.<key>`. `service.name` and `host.name` are always sent.
      '';
    };

    excludeFsTypes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = import ../lib/exclude-fs-types.nix;
      description = ''
        Filesystem types not reported as `system.filesystem` measurements. Shared with the
        disk-space health check, so both agree on what counts as a real volume.
      '';
    };

    requireClockSync = lib.mkOption {
      type = lib.types.bool;
      default = config.services.timesyncd.enable;
      defaultText = lib.literalExpression "config.services.timesyncd.enable";
      description = ''
        Skip runs until systemd-timesyncd reports the clock synchronised, by conditioning the
        unit on the `/run/systemd/timesync/synchronized` marker it writes after its first
        successful sync.

        The Pi has no RTC battery, so between boot and the first sync its clock reads somewhere
        near the epoch. That timestamp is non-zero and therefore perfectly conforming, so the
        receiver stores it verbatim -- and the receiver has no retention (its SPEC lists that as
        a non-goal) while its read API sorts and paginates on `event_time`. A few 1970 rows
        would sit at the far end of every query forever. Losing the first sample or two of a
        boot is much the cheaper mistake.

        A skipped run is reported by systemd as a satisfied-condition no-op rather than a
        failure, which is the honest description: nothing is broken, the host just does not yet
        know what time it is. Defaults off where timesyncd is not the time source, since the
        marker would then never appear and the collector would never run at all.
      '';
    };

    cpuSampleSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = ''
        Seconds between the two /proc/stat samples the CPU utilisation is derived from. The
        run blocks for this long, so it is also the floor on the unit's duration.
      '';
    };

    timerConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {
        OnBootSec = "5m";
        OnUnitActiveSec = "15m";
        AccuracySec = "30s";
      };
      description = ''
        systemd timer configuration for the collector.

        15 minutes rather than something finer because the receiver has no retention -- its
        SPEC lists retention and downsampling as non-goals -- so every sample is permanent, and
        on the Pi permanent means on a 29 GB SD card. At ~5 records a run that is roughly 175k
        rows a year; at 5 minutes it would be three times that.

        Deliberately no `Persistent`: a measurement describes the moment it was taken, so
        catching up on samples missed while the host was off would record the present under
        past timestamps.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.group != "";
        message = "common.systemMetrics.group must name the receiver's socket group.";
      }
      {
        # Every tick would fail against a socket nothing is serving: a loud unit that says
        # nothing useful. Only checkable where the receiver's module is in the imports list at
        # all -- on other hosts its options do not exist, hence the `?` guard.
        assertion = !(config.services ? monitoring-platform)
          || config.services.monitoring-platform.enable
          || cfg.socketPath != config.services.monitoring-platform.socketPath;
        message = ''
          common.systemMetrics posts to ${cfg.socketPath}, but
          services.monitoring-platform.enable is false on this host. Enable the receiver, point
          common.systemMetrics.socketPath at another one, or disable common.systemMetrics.
        '';
      }
    ];

    environment.systemPackages = [ collectCommand ];

    systemd.services.system-metrics = {
      description = "Report host measurements to the local monitoring platform";
      # Ordering only, not Requires: the receiver is Type=notify, so After really does mean
      # "the socket is bound and accepting" rather than "the process forked". A run with no
      # receiver up should fail loudly on the timer rather than drag the receiver in.
      after = [ "monitoring-platform.service" "time-sync.target" ];

      # The measured half of "only report once the clock is real"; see requireClockSync. A
      # condition, not a check inside the collector, because systemd already knows how to skip
      # a unit without calling it a failure -- and because the marker is timesyncd's own answer
      # rather than this module guessing at a plausible date.
      unitConfig.ConditionPathExists =
        lib.mkIf cfg.requireClockSync "/run/systemd/timesync/synchronized";

      serviceConfig = {
        Type = "oneshot";
        # The binary directly rather than collectCommand, so `systemctl cat` shows the flags
        # this run was configured with instead of an opaque wrapper path.
        ExecStart = lib.escapeShellArgs ([ (lib.getExe cfg.package) ] ++ collectArgs);

        # The collector needs no identity of its own and no state; the one privilege it does
        # need is membership of the receiver's group, which is what gates the socket.
        DynamicUser = true;
        SupplementaryGroups = [ cfg.group ];

        # Generous next to a cpuSampleSeconds-long run: the point is to kill a run wedged on
        # an unresponsive socket before the next tick, not to police collection speed.
        TimeoutStartSec = "${toString (cfg.cpuSampleSeconds + 60)}s";

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        # NOT `true`: that replaces /home with an empty tmpfs, and this unit walks the mount
        # table -- a separate /home would then be reported as a tmpfs, i.e. dropped by
        # excludeFsTypes, and silently disappear from the results on a healthy host.
        ProtectHome = "read-only";
        # Safe only because tmpfs is in excludeFsTypes; otherwise the per-unit /tmp would be
        # reported as a filesystem that no other process on the host can see.
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        # Hides other processes, which this unit never reads. NOT ProcSubset = "pid": that would
        # hide /proc/meminfo, /proc/stat and /proc/loadavg, i.e. every input it has.
        ProtectProc = "invisible";
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        CapabilityBoundingSet = [ "" ];
        SystemCallFilter = [ "@system-service" ];
        SystemCallArchitectures = "native";
        # Same kernel-enforced local-only guarantee the receiver gives itself: this producer
        # talks to one unix socket and has no business opening a network connection.
        RestrictAddressFamilies = [ "AF_UNIX" ];
      };
    };

    systemd.timers.system-metrics = {
      wantedBy = [ "timers.target" ];
      timerConfig = cfg.timerConfig // { Unit = "system-metrics.service"; };
    };
  };
}
