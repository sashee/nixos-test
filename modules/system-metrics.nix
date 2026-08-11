{ config, lib, pkgs, ... }:

# Periodically reports this host's own CPU, memory, filesystem usage and NixOS generation over a
# LOCAL unix socket -- the first producer for what was until now an empty receiver (upstream's
# remote iroh transport has not landed).
#
# Not to be confused with modules/monitoring.nix, which reports host *health* outward to a
# Healthchecks URL and alerts on it. This module makes no judgements: it collects numbers and
# stores them, so history exists to look at later.
#
# The socket it posts to is deliberately not named here. The hosts point it at the on-host
# `mp-collector` (the monitoring-platform input's nix/collector-module.nix), which forwards to
# whichever receiver is configured -- so when the receiver moves off the Pi, the only thing that
# changes is the collector's `forwardTo`. This module, and every other producer, keeps posting to
# the same local socket and needs no edit. Posting straight at a receiver still works and is what
# the defaults below describe.
#
# The wire format only accepts binary OTLP (protobuf, logs signal, Events), so the producer cannot
# be a shell script -- it is a small Rust binary in packages/system-metrics built on the same
# opentelemetry-proto crate the receiver decodes with.

let
  cfg = config.common.systemMetrics;

  # A `common.*` option from a module this host may not import.
  #
  # Load-bearing: this module is imported by configurations that import none of the other
  # `common.*` features -- qemu-graphical is the standing example -- and in Nix a missing option
  # is an evaluation error, not a `false`. The same trap the `config.services ? mp-collector`
  # guards below exist for.
  #
  # Deliberately NOT used for nixpkgs' own options (`services.chrony`, `nix.gc`,
  # `system.autoUpgrade`, ...): those are always present, so a guard there would only turn a
  # typo into a silently disabled feature.
  commonFeature = path: default: lib.attrByPath path default config.common;

  # Units whose state is worth a record, derived from what this host actually enables rather
  # than listed as constants. A hardcoded list rots in the worst possible way: a name that
  # matches no unit reports nulls forever and reads exactly like a healthy unit that happens to
  # be quiet. (The name to get wrong here is the upgrade one -- `nixos-upgrade.service`, not
  # `auto-upgrade.service`, which does not exist.)
  defaultUnits =
    lib.optional config.services.chrony.enable "chronyd.service"
    ++ lib.optional config.services.dnscrypt-proxy.enable "dnscrypt-proxy.service"
    ++ lib.optionals (commonFeature [ "irohSsh" "enable" ] false) [
      "iroh-ssh.service"
      "iroh-ssh-failsafe.service"
    ]
    ++ lib.optionals (commonFeature [ "connectivityFallback" "enable" ] false) [
      "connectivity-fallback-check.service"
      "connectivity-fallback-setup.service"
      "connectivity-fallback-dnsmasq.service"
      "connectivity-fallback-portal.service"
    ]
    ++ lib.optional (commonFeature [ "connectivityWatchdog" "enable" ] false)
      "connectivity-watchdog.service"
    ++ lib.optional (commonFeature [ "timeSync" "enable" ] false) "time-correction.service"
    ++ map (name: "restic-backups-${name}.service")
      (lib.attrNames (commonFeature [ "restic" "backups" ] { }))
    ++ lib.optional config.nix.gc.automatic "nix-gc.service"
    ++ lib.optional config.system.autoUpgrade.enable "nixos-upgrade.service"
    # Both hops of the measurement path. The receiver earns its place: if it dies the collector
    # buffers and these records arrive late, so its unit state is recoverable evidence. The
    # producer does not -- see the `units` option description.
    ++ lib.optional (config.services ? mp-collector && config.services.mp-collector.enable)
      "mp-collector.service"
    ++ lib.optional
      (config.services ? monitoring-platform && config.services.monitoring-platform.enable)
      "monitoring-platform.service";

  # Timers where a stopped schedule is invisible until something else goes wrong. Deliberately
  # not every timer on the host: 11 of them at this cadence would be more rows per year than the
  # entire rest of the batch, and `logrotate`/`tmpfiles-clean`/`zpool-trim` failing is either
  # harmless or (for zpool-trim on a host with no pools) meaningless.
  defaultTimers =
    lib.optional config.system.autoUpgrade.enable "nixos-upgrade.timer"
    ++ lib.optional config.nix.gc.automatic "nix-gc.timer"
    ++ lib.optional (commonFeature [ "connectivityWatchdog" "enable" ] false)
      "connectivity-watchdog.timer"
    ++ lib.optional (commonFeature [ "timeSync" "enable" ] false) "time-correction.timer"
    ++ lib.optional config.services.fstrim.enable "fstrim.timer";

  excludeArgs = lib.concatMap (t: [ "--exclude-fstype" t ]) cfg.excludeFsTypes;
  resourceArgs =
    lib.concatLists (lib.mapAttrsToList (k: v: [ "--resource-attr" "${k}=${v}" ]) cfg.resourceAttributes);
  unitArgs = lib.concatMap (u: [ "--unit" u ]) cfg.units;
  timerArgs = lib.concatMap (t: [ "--timer" t ]) cfg.timers;

  collectArgs = [
    "--socket"
    cfg.socketPath
    "--cpu-sample-seconds"
    (toString cfg.cpuSampleSeconds)
    "--sysfs-root"
    cfg.sysfsRoot
    "--hwmon-root"
    cfg.hwmonRoot
    "--profiles-dir"
    cfg.profilesDir
    "--success-dir"
    cfg.successDir
    "--journal-window-seconds"
    (toString cfg.journalWindowSeconds)
    "--flake-input"
    cfg.flakeLock.input
    # systemd's own tools rather than a PATH lookup: the unit runs with no PATH worth trusting,
    # and `systemctl` from a different systemd than PID 1 is a class of bug worth designing out.
    "--systemctl"
    "${config.systemd.package}/bin/systemctl"
    "--journalctl"
    "${config.systemd.package}/bin/journalctl"
  ]
  ++ lib.optionals (cfg.flakeLock.path != null) [ "--flake-lock" cfg.flakeLock.path ]
  ++ lib.optionals cfg.smart.enable [ "--smartctl" (lib.getExe' cfg.smart.package "smartctl") ]
  ++ lib.optionals cfg.irohFailsafe.enable [
    "--iroh-failsafe-marker"
    cfg.irohFailsafe.marker
    "--failsafe-rule-tag"
    cfg.irohFailsafe.ruleTag
    "--nft"
    (lib.getExe' cfg.tools.nftables "nft")
  ]
  ++ excludeArgs ++ resourceArgs ++ unitArgs ++ timerArgs;

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
        Unix socket to post to. Hosts should wire this from
        `services.mp-collector.socketPath` (the on-host forwarding collector) or from
        `services.monitoring-platform.socketPath` (a receiver on this host) rather than
        restating either default.

        The default is still the receiver's socket, because that is the only endpoint that
        exists on a host importing nothing else. Wiring it to the collector instead is what
        makes the receiver's location a property of one option on one service -- see the
        module header, and [](#opt-common.systemMetrics.viaCollector).
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "monitoring-platform";
      description = ''
        Group this producer joins in order to reach the socket. Membership is the entire
        access control at either end (both runtime directories are 0750 and group-owned), so
        this must match whichever service owns
        [](#opt-common.systemMetrics.socketPath) -- `services.mp-collector.group` or
        `services.monitoring-platform.group`.
      '';
    };

    viaCollector = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      default = config.services ? mp-collector
        && config.services.mp-collector.enable
        && cfg.socketPath == config.services.mp-collector.socketPath;
      defaultText = lib.literalExpression
        "the on-host mp-collector is enabled and socketPath is its socket";
      description = ''
        Whether this producer posts through the on-host clock-correcting collector rather
        than straight at a receiver.

        Derived rather than set, and read-only, because it is not a policy -- it is a fact
        about where [](#opt-common.systemMetrics.socketPath) points. Anything that has to
        behave differently on the two paths (today: the clock gate below, and
        `modules/time-sync.nix`, which would otherwise re-arm it) reads this, so pointing the
        socket somewhere else cannot leave a stale assumption behind.

        The `?` guard is load-bearing: on a host that does not import the collector module
        the option does not exist, and reading it would be an evaluation error rather than a
        `false`.
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

    syncedMarker = lib.mkOption {
      type = lib.types.path;
      default = "/run/systemd/timesync/synchronized";
      description = ''
        The path whose existence means "the clock is synchronised".

        Which daemon owns the clock decides this, so it is an option rather than a constant:
        systemd-timesyncd writes the default path itself, while chrony writes nothing of the
        kind and `modules/time-sync.nix` points this at the marker its chrony-wait unit
        creates. Getting it wrong in either direction is silent -- a marker that never appears
        stops the collector forever, and one that appears too early puts pre-sync timestamps
        into a store that cannot delete them.
      '';
    };

    requireClockSync = lib.mkOption {
      type = lib.types.bool;
      default = !cfg.viaCollector && config.services.timesyncd.enable;
      defaultText = lib.literalExpression
        "!config.common.systemMetrics.viaCollector && config.services.timesyncd.enable";
      description = ''
        Skip runs until the clock is reported synchronised, by conditioning the unit on
        [](#opt-common.systemMetrics.syncedMarker).

        The Pi has no RTC battery, so between boot and the first sync its clock reads somewhere
        near the epoch. That timestamp is non-zero and therefore perfectly conforming, so the
        receiver stores it verbatim -- and the receiver has no retention (its SPEC lists that as
        a non-goal) while its read API sorts and paginates on `event_time`. A few 1970 rows
        would sit at the far end of every query forever. Losing the first sample or two of a
        boot is much the cheaper mistake.

        A skipped run is reported by systemd as a satisfied-condition no-op rather than a
        failure, which is the honest description: nothing is broken, the host just does not yet
        know what time it is.

        **Off by default once [](#opt-common.systemMetrics.viaCollector) holds**, because then
        it is no longer the cheaper mistake: the collector exists precisely to make the
        pre-sync window recoverable. It holds a batch stamped against an unsynchronised clock,
        rewrites the timestamps once the offset is known, and flushes marked
        `mp.clock.uncertain` if sync never arrives at all -- so the samples this gate would
        throw away are preserved and correctly dated instead. Keeping both would leave the
        correction path dead code on the one host that needs it. It is still an ordinary
        option: a host can set it back to `true`.

        Where it does apply, the default follows timesyncd only because that is the stock NixOS
        time source. It is not "off unless timesyncd": `modules/time-sync.nix` turns it back on
        when chrony owns the clock, which it must, since enabling chrony forces
        `services.timesyncd.enable` to false and would otherwise switch this gate off on
        precisely the host that needs it.
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

    sysfsRoot = lib.mkOption {
      type = lib.types.path;
      default = "/sys";
      description = "Root of sysfs, under which the zram devices are found.";
    };

    hwmonRoot = lib.mkOption {
      type = lib.types.path;
      default = "${cfg.sysfsRoot}/class/hwmon";
      defaultText = lib.literalExpression ''"''${config.common.systemMetrics.sysfsRoot}/class/hwmon"'';
      description = ''
        Directory of hwmon chips to sweep for `system.sensor`.

        Separate from [](#opt-common.systemMetrics.sysfsRoot) so a VM test can point it at a
        fixture tree without also redirecting the zram sweep, which has real devices to read in
        a guest. A QEMU guest has essentially no hwmon at all, so without a fixture
        `system.sensor` is a record no test could assert anything about -- and the sweep's real
        subject is exactly the shapes a guest lacks: chips without a `_label`, two chips sharing
        a `name`, and the `_alarm` spellings.
      '';
    };

    profilesDir = lib.mkOption {
      type = lib.types.path;
      default = "/nix/var/nix/profiles";
      description = "Directory whose `system-*-link` entries are counted as `generation.count`.";
    };

    successDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/common-monitoring";
      description = ''
        Directory of `<unit>.last-success` markers, reported as
        `system.unit.last_success_seconds_ago`.

        Written by `modules/monitoring.nix` from the monitored unit's own `OnSuccess=`, which is
        what makes it different from `active_enter_seconds_ago`: a run that failed never touches
        the marker, while a failing unit keeps refreshing its activation timestamp. "Last
        succeeded" is therefore not derivable from unit state, and is the one field the health
        report has that nothing else does.
      '';
    };

    flakeLock = {
      path = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = "/etc/nixos/flake.lock";
        description = ''
          Deployed `flake.lock`, read for the `common_*` fields of `system.host`. Null leaves
          them null, which is what a VM test that has no `/etc/nixos` gets.

          Reports what the lock says, not what the running system was built from: a
          `--override-input common ...` build leaves the lock untouched. Same property the
          Healthchecks report has always had.
        '';
      };

      input = lib.mkOption {
        type = lib.types.str;
        default = "common";
        description = ''
          `flake.lock` node whose locked revision is reported. Matches
          [](#opt-common.monitoring.flakeLock.input) so the two never disagree about which input
          "common" means.
        '';
      };
    };

    units = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = defaultUnits;
      defaultText = lib.literalMD "the units of whichever `common.*` features this host enables";
      description = ''
        Units reported as `system.unit`. Units that are failing or restart-looping are always
        reported whether they are listed here or not, so this list is about units whose *health*
        matters even while they look fine.

        Derived from the host's own configuration rather than hardcoded: a name that matches no
        unit produces a record of nulls, which is indistinguishable from a healthy unit that
        happens to be idle.

        `system-metrics.service` is deliberately absent. A `Type=oneshot` unit is `activating`
        until its ExecStart exits, so the producer observing itself would report `activating` on
        every single run -- and its real failure mode, not running at all, is already visible as
        a gap in the timestamps.
      '';
    };

    timers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = defaultTimers;
      defaultText = lib.literalMD "the timers of whichever `common.*` features this host enables";
      description = ''
        Timers reported as `system.timer`, carrying only `next_elapse_seconds_until` -- "is this
        still scheduled". When it last ran is already `active_enter_seconds_ago` on the service
        the timer triggers, so recording it here too would be one fact in two places.
      '';
    };

    journalWindowSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 900;
      description = ''
        How far back the `system.journal` counts reach. Should match the collection interval:
        the producer holds no state, so there is no journal cursor to resume from and the window
        is simply `now - this`. A message landing on the boundary may be counted twice or missed,
        which is tolerable for a count in a way it would never be for log text.
      '';
    };

    smart = {
      enable = lib.mkEnableOption ''
        reporting SMART health as `system.drive`.

        Off by default because it is the one collector that cannot run inside this unit's
        sandbox as it stands: smartctl needs raw access to the block device, so enabling this
        drops `PrivateDevices`, grants `CAP_SYS_RAWIO` and allows block devices through
        `DeviceAllow`. Worth it on a laptop with an NVMe whose wear level is the only warning
        you get; pointless on the Pi, whose SD card exposes no SMART at all
      '';

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.smartmontools;
        defaultText = lib.literalExpression "pkgs.smartmontools";
        description = "Package providing `smartctl`.";
      };
    };

    irohFailsafe = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = commonFeature [ "irohSsh" "enable" ] false;
        defaultText = lib.literalExpression "config.common.irohSsh.enable";
        description = ''
          Report `system.iroh_failsafe`: whether the failsafe has opened port 22, and when it
          last engaged.

          "Port 22 open" is the presence of the failsafe's tagged rule in the firewall -- there
          is no static 22-accept, so that tag is the only thing that ever opens it. Reading the
          rule set needs `CAP_NET_ADMIN`, which enabling this grants.
        '';
      };

      marker = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/iroh-ssh-failsafe/last-engaged";
        description = "Marker `modules/iroh-ssh.nix` refreshes while the failsafe holds port 22 open.";
      };

      ruleTag = lib.mkOption {
        type = lib.types.str;
        default = "iroh-ssh-failsafe";
        description = "Comment the failsafe tags its runtime nftables rule with.";
      };
    };

    tools = {
      nftables = lib.mkOption {
        type = lib.types.package;
        default = pkgs.nftables;
        defaultText = lib.literalExpression "pkgs.nftables";
        description = "Package providing `nft`, used to read the firewall's input-allow chain.";
      };

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
        on the Pi permanent means on a 29 GB SD card.

        Measured cost, taken from the Pi's own store: 4382 rows over 8.18 days at ~610 bytes a
        row on disk, i.e. the five-record batch this producer started with came to roughly 200k
        rows a year. A batch is now closer to 40 records -- sensors, watched units, timers -- so
        budget on the order of 1.3M rows and ~800 MB a year, against 16 GB free. Halving the
        interval doubles both.

        If that becomes the binding constraint, the cheapest saving is per-record cadence rather
        than a slower timer: `system.drive` changes on the scale of days and is sampled 96 times
        a day purely because it shares this schedule.

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
        message = "common.systemMetrics.group must name the socket's owning group.";
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
      {
        # The same trap one hop earlier, and the likelier one now that the hosts point at the
        # collector: importing collector-module.nix and wiring socketPath from it, but never
        # setting `enable`. Same `?` guard, same reason.
        assertion = !(config.services ? mp-collector)
          || config.services.mp-collector.enable
          || cfg.socketPath != config.services.mp-collector.socketPath;
        message = ''
          common.systemMetrics posts to ${cfg.socketPath}, but services.mp-collector.enable is
          false on this host. Enable the collector, point common.systemMetrics.socketPath at a
          receiver directly, or disable common.systemMetrics.
        '';
      }
      {
        # Membership of the wrong group leaves the socket unreachable and every tick failing,
        # which is loud but says nothing about the cause. Checked against whichever service the
        # producer resolved to, so a half-moved wiring (collector socket, receiver group) is a
        # build error rather than a runtime one.
        assertion = !cfg.viaCollector || cfg.group == config.services.mp-collector.group;
        message = ''
          common.systemMetrics posts through the collector at ${cfg.socketPath} but joins the
          group "${cfg.group}", while that socket is owned by
          "${config.services.mp-collector.group}". Access is the mode on the containing runtime
          directory, so every run would fail on permissions. Wire common.systemMetrics.group
          from services.mp-collector.group.
        '';
      }
    ];

    environment.systemPackages = [ collectCommand ];

    systemd.services.system-metrics = {
      description = "Report host measurements to the local monitoring platform";
      # Ordering only, not Requires: both the collector and the receiver are Type=notify, so
      # After really does mean "the socket is bound and accepting" rather than "the process
      # forked". A run with nothing listening should fail loudly on the timer rather than drag
      # a service in.
      #
      # Both hops are named regardless of which one this host posts to. Ordering against a unit
      # that does not exist is a no-op -- the same idiom the collector module uses for the time
      # daemons it must precede -- so naming both costs nothing and misses neither topology.
      after = [
        "mp-collector.service"
        "monitoring-platform.service"
        "time-sync.target"
      ];

      # The measured half of "only report once the clock is real"; see requireClockSync. A
      # condition, not a check inside the collector, because systemd already knows how to skip
      # a unit without calling it a failure -- and because the marker is timesyncd's own answer
      # rather than this module guessing at a plausible date.
      unitConfig.ConditionPathExists = lib.mkIf cfg.requireClockSync cfg.syncedMarker;

      serviceConfig = {
        Type = "oneshot";
        # The binary directly rather than collectCommand, so `systemctl cat` shows the flags
        # this run was configured with instead of an opaque wrapper path.
        ExecStart = lib.escapeShellArgs ([ (lib.getExe cfg.package) ] ++ collectArgs);

        # The collector needs no identity of its own and no state; the one privilege it does
        # need is membership of the receiver's group, which is what gates the socket.
        #
        # systemd-journal is the second: a DynamicUser unit sees only its own logs, so without
        # it `system.journal` would count this unit's own messages and nothing else -- zero on
        # every healthy run, which reads exactly like a quiet host.
        DynamicUser = true;
        SupplementaryGroups = [ cfg.group "systemd-journal" ];

        # Generous next to a cpuSampleSeconds-long run: the point is to kill a run wedged on
        # an unresponsive socket before the next tick, not to police collection speed.
        TimeoutStartSec = "${toString (cfg.cpuSampleSeconds + 60)}s";

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        # Reading the firewall's rule set is a privileged operation even though it changes
        # nothing; smartctl needs to issue device commands. Both are granted only when the
        # record that needs them is switched on, so the default sandbox is unchanged.
        CapabilityBoundingSet =
          lib.optional cfg.irohFailsafe.enable "CAP_NET_ADMIN"
          ++ lib.optional cfg.smart.enable "CAP_SYS_RAWIO";
        AmbientCapabilities =
          lib.optional cfg.irohFailsafe.enable "CAP_NET_ADMIN"
          ++ lib.optional cfg.smart.enable "CAP_SYS_RAWIO";
        # NOT `true`: that replaces /home with an empty tmpfs, and this unit walks the mount
        # table -- a separate /home would then be reported as a tmpfs, i.e. dropped by
        # excludeFsTypes, and silently disappear from the results on a healthy host.
        ProtectHome = "read-only";
        # Safe only because tmpfs is in excludeFsTypes; otherwise the per-unit /tmp would be
        # reported as a filesystem that no other process on the host can see.
        PrivateTmp = true;
        # smartctl talks to the block device directly, and a private /dev has no block devices
        # in it at all -- so with SMART on, the sweep would scan nothing and quietly report no
        # drives on a host that has them.
        PrivateDevices = !cfg.smart.enable;
        DeviceAllow = lib.mkIf cfg.smart.enable [ "block-* r" ];
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
        SystemCallFilter = [ "@system-service" ];
        SystemCallArchitectures = "native";
        # Same kernel-enforced local-only guarantee the receiver gives itself: this producer
        # talks to unix sockets -- the receiver's, and the system bus that `systemctl show`
        # goes through -- and has no business opening a network connection. AF_NETLINK is what
        # nft needs to read the rule set, and is only allowed where that record is on.
        RestrictAddressFamilies = [ "AF_UNIX" ] ++ lib.optional cfg.irohFailsafe.enable "AF_NETLINK";
      };
    };

    systemd.timers.system-metrics = {
      wantedBy = [ "timers.target" ];
      timerConfig = cfg.timerConfig // { Unit = "system-metrics.service"; };
    };
  };
}
