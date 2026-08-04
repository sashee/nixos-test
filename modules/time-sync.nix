{ config, lib, pkgs, ... }:

# Time synchronisation: chrony over NTS, plus the time-correction service that makes NTS
# reachable in the first place.
#
# One module rather than two, because the two halves only make sense together. These hosts
# resolve names over DoH and synchronise over NTS, and both are TLS -- so a clock outside
# certificate validity blocks name resolution and time synchronisation simultaneously, and
# neither can recover the other. A Raspberry Pi with no RTC battery is in exactly that state
# on every cold boot.
#
# There are two independent ways out, and the cheap one is tried first:
#
#   chronyd -s       sets the clock from the RTC, or -- when there is no usable RTC, or the RTC
#                    reads EARLIER than the last modification time of chrony's own driftfile,
#                    which is what a dead battery looks like -- steps the clock forward to that
#                    mtime instead. chronyd rewrites the driftfile whenever it computes a new
#                    drift value (at most hourly) and unconditionally on exit, and only ever
#                    while it is disciplining the clock, so the mtime is an instant at which this
#                    host was demonstrably right. No network, no DNS, one stat. It recovers a
#                    host that was merely off for a while; it cannot help one that was off for
#                    longer than a certificate's validity, and being forward-only it can never
#                    drag a good clock backwards.
#   time-correction  dials the DoH providers' PINNED ADDRESSES over HTTPS to resolve an NTS
#                    server's name, then takes an authenticated timestamp from that server --
#                    ignoring certificate dates during both handshakes and re-checking them
#                    against the timestamp afterwards. No name resolution to start with, so it
#                    does not need DNS; no trust in the clock, so it does not need the clock.
#                    This one works however long the host was off.
#
# and then, once either has put the clock inside certificate validity:
#
#   dnscrypt         DoH works, so names resolve.
#   chronyd          resolves the NTS hostnames and takes over. It is authoritative; whatever
#                    time-correction set is only a seed accurate to a minute or so.
#
# time-correction runs once after boot and then every hour, on a timer -- not a retry loop, and
# not only at boot. Two consequences worth stating, because both are the point rather than a
# side-effect:
#
#   * The hourly run is a check, not just a repair. It does the whole DoH + NTS exchange even
#     when the clock is demonstrably fine, so a provider that stopped answering, a pinned
#     address that moved or an expired trust store is discovered while the host is still
#     healthy enough to say so -- instead of at the next cold boot, when nothing works and
#     nobody can reach the box. That is why the program no longer asks the kernel whether the
#     clock is already synchronised and skips the exchange when it is: the skip was the whole
#     failure mode.
#   * It still steps the clock only when it has to. It stands down when the clock, however
#     wrong, already sits inside the validity of every certificate it just checked: TLS works
#     at that point, which is the only thing this program exists to arrange, and stepping would
#     replace an error chrony is about to correct precisely with a whole-second approximation
#     of the same instant. On a host chrony has disciplined that rule always fires, which is
#     why dropping the kernel check costs nothing.
#
# That leans on chrony being able to step a large error, which it can because nixpkgs defaults
# `services.chrony.makestep` to `0.1 3` -- the first three updates step, with no size limit. A
# host that turned makestep off would slew instead, and an error of weeks would take weeks.
#
# It reaches the same NTS servers chrony does, which is the point: bootstrap and steady state
# rest on one set of parties. It gets there by resolving their names through a DoH resolver
# dialled at a pinned address, because that is the one thing on this host that needs neither
# DNS nor a clock. Certificate time checks are deferred on BOTH legs and re-applied against the
# time the NTS server reports -- so a chain that was not valid at that instant is rejected, and
# the build-time floor, applied to each provider's own answer before anything is re-verified
# against it, bounds how far back a once-valid certificate could roll things.
#
# Not covered here, deliberately: nothing removes the synchronised marker if chrony later
# loses all its sources. The marker means "this boot reached synchronisation once", which is
# what its consumers actually want -- a gate that reopened mid-run would make measurements
# vanish rather than make them more correct.
#
# Also gone deliberately: there is no reboot failsafe for "the correction service succeeded
# and chrony still has not synchronised". It used to live here as `unwedgeSeconds`, and the
# spec dropped it. A reboot is a remedy for a wedged resolver and nothing else, the hourly run
# now surfaces the same class of fault as a plain failing unit instead, and an unbounded reboot
# rule is the shape of the 2026-07-27 bootloop that modules/connectivity-watchdog.nix exists to
# avoid repeating.

let
  cfg = config.common.timeSync;

  dohStamps = import ../lib/doh-stamps.nix { inherit lib; };
  ntsServers = import ../lib/nts-servers.nix { inherit lib; };

  # "--doh <name>=<hostname>@<addr>[,<addr>]", straight off lib/doh-stamps.nix so the addresses
  # time-correction dials are the same ones dnscrypt-proxy dials and cannot drift. These are
  # only used to RESOLVE: the time itself comes from NTS.
  dohArgs = lib.concatMap (
    name:
    let
      p = dohStamps.providers.${name};
      addresses = [ p.v4 ] ++ lib.optional (p ? v6) p.v6;
    in
    [ "--doh" "${name}=${p.hostname}@${lib.concatStringsSep "," addresses}" ]
  ) (builtins.attrNames dohStamps.providers);

  # "--nts <name>=<hostname>@<operator>" -- the same servers chrony uses in steady state, so
  # bootstrap and steady state rest on one set of parties rather than two. The operator is the
  # unit of agreement: ptbtime1 and ptbtime2 are one organisation and must not be able to form a
  # quorum with each other.
  #
  # Derived from `cfg.servers` rather than straight from lib/nts-servers.nix, so that overriding
  # the server list moves BOTH consumers. A test that pointed chrony at two impersonated servers
  # while time-correction kept dialling the real four would be testing two different
  # configurations at once, and the halves would disagree about what the host is even talking to.
  selected = lib.filterAttrs (_: p: lib.elem p.hostname cfg.servers) ntsServers.providers;

  ntsArgs = lib.concatMap (
    name:
    let
      p = selected.${name};
    in
    [ "--nts" "${name}=${p.hostname}@${p.operator}" ]
  ) (builtins.attrNames selected);

  correctionArgs =
    dohArgs
    ++ ntsArgs
    ++ [
      "--sample"
      (toString cfg.sample)
      "--tolerance"
      (toString cfg.tolerance)
      "--floor"
      (toString cfg.floor)
      "--timeout"
      (toString cfg.timeoutSeconds)
    ];

  # A wrapper named after the binary and preloaded with the unit's own flags, so
  # `time-correction --force --dry-run` on a live host asks exactly what the timed service asks.
  # Same idea as the `system-metrics` wrapper in modules/system-metrics.nix.
  correctionCommand = pkgs.writeShellApplication {
    name = "time-correction";
    text = ''
      exec ${lib.escapeShellArgs ([ (lib.getExe cfg.package) ] ++ correctionArgs)} "$@"
    '';
  };

in

{
  options.common.timeSync = {
    # Opt-in like the other common.* modules, so a host that has not been thought about does
    # not silently acquire a service that steps its clock.
    enable = lib.mkEnableOption "chrony over NTS plus the periodic time-correction service";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../packages/time-correction/package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ../packages/time-correction/package.nix { }";
      description = "The clock-correction binary the timed service runs.";
    };

    floor = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      example = 1785491804;
      description = ''
        Unix timestamp below which a reported time is refused, as a bound on how far back the
        clock can be rolled.

        Retroactive certificate validation proves a chain was valid at the claimed time, not
        that the claimed time is now -- so someone holding a once-valid certificate for two
        providers could otherwise name a date inside its old validity window and step this
        clock backwards into it, where stale certificates and revocations all look current.
        A floor turns that into a forward-only error.

        Has no sensible default: it must be a build-time constant, and nothing inside a module
        knows when the build happened. Set it from flake.nix, where `nixpkgs.lastModified` is
        in scope -- the same value tests/restic.nix already uses as a clock base.
      '';
    };

    sample = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = ''
        How many NTS operators to ask. All of them must answer and agree, so this is also the
        number that would have to be compromised at once to move the clock.

        Each is asked through a different DoH resolver, so a single compromised resolver cannot
        sit in the path of every answer either -- it could point one lookup at a host it
        controls, but that host would still need a certificate for the NTS server's name.
      '';
    };

    tolerance = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = ''
        How far apart two providers' answers may be and still count as agreeing, in seconds.

        Generous on purpose. The answer only has to land inside certificate validity, which has
        days of slack; tightening this buys no accuracy -- chrony provides that -- and only
        makes a boot fail over ordinary skew between two operators.
      '';
    };

    timeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = ''
        Per-connection connect and read timeout, and it is paid per address rather than once
        per run. The chosen provider pairs are dialled concurrently, but within a pair every
        address is tried in turn on both the DoH and the NTS leg -- so a network that
        BLACKHOLES one family, dropping silently rather than answering ENETUNREACH, waits out
        this timeout on each of them before the family that works is reached. Budget for that
        rather than for one timeout: the unit's `TimeoutStartSec` below is sized on the same
        arithmetic.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "1h";
      example = "30m";
      description = ''
        How often the time-correction service runs, as a systemd time span. It also runs once
        shortly after every boot; see [](#opt-common.timeSync.bootDelay).

        The cadence is not only about how quickly a wrong clock is corrected. Each run does the
        whole DoH + NTS exchange even when the clock is fine, so it is also the only thing on
        this host that regularly proves those two paths still work -- a provider that stopped
        answering or a pinned address that moved shows up as a failing unit while the host is
        still healthy, rather than at the next cold boot when nothing works at all.
      '';
    };

    bootDelay = lib.mkOption {
      type = lib.types.str;
      default = "1min";
      description = ''
        How long after boot the first run happens, as a systemd time span.

        Short, because on an RTC-less host nothing else can put the clock inside certificate
        validity once the persisted last-known-good time is too old -- but not zero, because the
        unit waits for `network-online.target` anyway and firing before there is any chance of
        an address only spends a run on a failure.
      '';
    };

    servers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ntsServers.hostnames;
      defaultText = lib.literalExpression "(import ../lib/nts-servers.nix { inherit lib; }).hostnames";
      description = ''
        The NTS servers chrony synchronises against. Hostnames, resolved through this host's
        own DoH resolver once the correction service has made that possible.
      '';
    };

    minSources = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = ''
        How many sources must agree before chrony will adjust the clock (`minsources`).

        chrony's own default is 1, which would let a single reachable server -- lying,
        misconfigured, or impersonated -- set the time unchallenged. That is the failure the
        spec's "must use multiple servers to detect incorrect servers" is about, and this is
        the directive that enforces it.
      '';
    };

    syncedMarker = lib.mkOption {
      type = lib.types.path;
      default = "/run/chrony-wait/synchronized";
      description = ''
        Path created once chrony reports the clock synchronised, for units that must not run
        before then. The chrony analogue of systemd-timesyncd's
        `/run/systemd/timesync/synchronized`, which chrony does not provide: nixpkgs' chrony
        module creates only `chronyd.service`, and `time-sync.target` is reached when chronyd
        *starts*, not when it has synchronised -- so ordering against that target proves
        nothing.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.floor != null;
        message = ''
          common.timeSync.floor must be set: it is the bound on how far backwards a
          compromised provider could roll this clock. Set it from flake.nix to
          `nixpkgs.lastModified`, which is a build-time constant.
        '';
      }
      {
        assertion =
          cfg.sample <= builtins.length (lib.unique (lib.mapAttrsToList (_: p: p.operator) selected))
          && cfg.sample <= builtins.length (builtins.attrNames dohStamps.providers);
        message = ''
          common.timeSync.sample (${toString cfg.sample}) exceeds either the number of distinct
          NTS operators reachable from common.timeSync.servers or the number of DoH resolvers in
          lib/doh-stamps.nix, so the correction service could never assemble a quorum.
        '';
      }
      {
        assertion = cfg.servers != [ ];
        message = ''
          common.timeSync.servers is empty; chrony would start with no time source at all.
        '';
      }
      {
        assertion =
          lib.all (h: lib.any (p: p.hostname == h) (lib.attrValues ntsServers.providers)) cfg.servers;
        message = ''
          common.timeSync.servers names a host that lib/nts-servers.nix does not describe:
          ${toString (lib.subtractLists (lib.mapAttrsToList (_: p: p.hostname) ntsServers.providers) cfg.servers)}

          chrony would use it, but time-correction could not: it needs the operator that file
          carries, because the operator is what decides whether two answers count as one source
          or two. Add the host there rather than only here.
        '';
      }
      {
        # chrony-wait declares its directory with `RuntimeDirectory`, which takes a single
        # component under /run -- so a marker nested any deeper is created in the wrong place
        # and the ExecStartPost that writes it fails. Checked rather than documented because
        # the failure is a touch into a directory that does not exist, on a unit whose entire
        # output is that file.
        assertion =
          lib.hasPrefix "/run/" (toString cfg.syncedMarker)
          && builtins.length (lib.splitString "/" (toString cfg.syncedMarker)) == 4;
        message = ''
          common.timeSync.syncedMarker (${toString cfg.syncedMarker}) must be of the form
          /run/<directory>/<file>: chrony-wait creates its parent with RuntimeDirectory, which
          takes one path component, so anything deeper is created somewhere else and the marker
          is never written.
        '';
      }
    ];

    environment.systemPackages = [ correctionCommand ];

    services.chrony = {
      enable = true;
      enableNTS = true;
      # Must be set explicitly. The nixpkgs default is networking.timeServers, i.e. the NixOS
      # pool, which does not speak NTS -- and enableNTS appends ` nts` to every server line
      # with no assertion, so the default silently produces a configuration that can never
      # synchronise.
      servers = cfg.servers;
      # nixpkgs defaults this to true, which emits `rtcfile` + `rtcautotrim`: chronyd measures
      # the RTC's drift and trims it. That is the more accurate way to keep an RTC, and it is
      # the wrong trade here, because it is mutually exclusive with `rtcsync` -- and `rtcsync`
      # is the only thing that makes chronyd tell the KERNEL the clock is synchronised.
      #
      # On Linux `rtcsync` works by having the kernel copy the system time to the RTC every 11
      # minutes, and the kernel only does that while `STA_UNSYNC` is clear, so enabling it is
      # what clears the bit. Two things follow, and the first is the one that matters here: the
      # RTC is kept current, so on a host that has one the next boot starts close to correct and
      # `chronyd -s` has a good value to read. The second is that `timedatectl` reports
      # NTPSynchronized=yes rather than no on a host that is in fact synchronised.
      #
      # Nothing here needs a trimmed RTC. The Pi has no RTC battery at all, and what the
      # laptop needs is that the next boot starts close to correct -- which an 11-minute copy
      # gives, and which tests/boot-clock.nix asserts by checking the RTC is read in the
      # initrd, not by checking its precision.
      enableRTCTrimming = false;
      # Spec: "must write the last known good time regularly and bump the time forward to this
      # persisted value on boot". Both halves are chronyd's own, which is why no unit of ours
      # implements either.
      #
      # Writing: the nixpkgs module emits `driftfile /var/lib/chrony/chrony.drift`, and
      # chrony.conf(5) says that file "is written only on an update of the local clock", at most
      # once per the directive's `interval` (default 3600s). So its mtime is a timestamp at which
      # this host was demonstrably synchronised -- not merely running -- refreshed hourly.
      #
      # Bumping: `-s` sets the clock from the RTC, and per chronyd(8), "if the last modification
      # time of the drift file is later than both the current time and the RTC time, the system
      # time will be set to it to restore the time when chronyd was previously stopped. This is
      # useful on computers that have no RTC or the RTC is broken" -- i.e. the Pi. Forward-only,
      # so it can never move a good clock backwards, and it needs no network at all, which is
      # what makes it the cheap half of the recovery described at the top of this file.
      #
      # The `interval` argument is left at chrony's default because the nixpkgs module hardcodes
      # the directive with no way to pass one. An hour matches this module's own correction
      # cadence, so nothing here needs to change it. It CAN be changed, though: chrony's parser
      # takes the last `driftfile` line, and `extraConfig` lands after the module's, so a second
      # line overrides rather than duplicates. tests/nts-sync.nix does exactly that to make the
      # write observable inside a test run -- a tempo change, not a mechanism change. Deployed
      # hosts have no reason to.
      extraFlags = [ "-s" ];
      extraConfig = ''
        minsources ${toString cfg.minSources}
        rtcsync
      '';
    };

    # Timed rather than triggered by a target, and monotonic rather than calendar-based.
    #
    # `OnCalendar=hourly` + `Persistent=true` is the obvious shape and is wrong here in a way
    # that matters: `Persistent` decides whether a run was missed by comparing a stored wall-clock
    # timestamp against the current clock, and a wildly wrong clock is precisely the state this
    # unit exists to fix. A host booting at the systemd epoch would see every hour since the stamp
    # as missed, fire immediately, then step its own clock forward and see them missed again.
    # Monotonic timers ask the kernel how long this boot has been running, which no clock error can
    # distort -- so "after boot, then every hour" comes out exactly as the spec states it, and
    # every boot is guaranteed one run rather than one that may or may not be considered due.
    #
    # `Persistent` is also meaningless on a monotonic timer, so its absence here is not an
    # oversight: catch-up is inherent, since the count restarts from this boot.
    systemd.timers.time-correction = {
      description = "Run the time-correction service after boot and every ${cfg.interval}";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = cfg.bootDelay;
        OnUnitActiveSec = cfg.interval;
        AccuracySec = "1m";
        Unit = "time-correction.service";
      };
    };

    systemd.services.time-correction = {
      description = "Correct the system clock from an authenticated NTS timestamp";
      # No `wantedBy`: the timer's OnBootSec is the boot run. Starting it from a target as well
      # would run it twice on every boot and reset the hourly count from the later of the two.
      #
      # network-online.target rather than network.target alone, and this is load-bearing now that
      # nothing retries. `network.target` does not mean an address exists, which is why the boot
      # attempt "usually fails on a cold boot" -- true and harmless while a failed run was retried
      # every 30s, and a wasted hour now that the next attempt is the timer's.
      wants = [ "network-online.target" ];
      after = [ "network.target" "network-online.target" ];
      # Deliberately NOT ordered against chronyd, though the temptation is obvious: chronyd
      # needs DNS, DNS needs DoH, DoH needs a plausible clock, so `Before=chronyd.service`
      # reads like the right thing. It buys much less than it costs.
      #
      # What it would buy: chrony's retry for a `server` name it could not resolve is
      # 7 * 2^n seconds with n clamped to [2,9] (chrony 4.8 ntp_sources.c:114-116, 670-672) --
      # 28s, 56s, 112s, ... 3584s -- and n resets only on a successful resolve. Ordering
      # chronyd after this unit means its FIRST resolve happens with a usable clock, so it
      # never enters that backoff.
      #
      # Why that is not worth it: it would hold chronyd back through a full DoH + NTS exchange on
      # every boot of every host -- and the exchange now happens unconditionally, even where the
      # clock is already fine, so that delay would be paid on the laptop too. It would also
      # postpone `chronyd -s`, which is the half of the recovery that needs no network and is
      # therefore the half most likely to be the one that works. Worse, the boot run waits for
      # `network-online.target`, so the ordering would make chronyd wait for the network as well.
      #
      # The consequence, accepted knowingly: on an RTC-less cold boot where the persisted
      # last-known-good time is too stale to help, chrony's first synchronisation is gated by its
      # own 28s retry floor rather than by this unit. tests/time-correction.nix pins that
      # chronyd runs regardless of whether this unit succeeds.

      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.escapeShellArgs ([ (lib.getExe cfg.package) ] ++ correctionArgs);
        # No Restart= and no RemainAfterExit. The spec makes any error fail the run, and the
        # timer owns the next attempt -- so a failure has to be a plain terminal failure that
        # `systemctl status` and the journal report, rather than a unit perpetually mid-retry.
        # RemainAfterExit would additionally make the timer's next trigger a no-op on a unit
        # still "active" from its last success.

        # Well above any exchange that could still succeed, and that matters more than it used to.
        # systemd's default is 90s, and the program's own worst case can exceed it: every address
        # of every chosen provider is tried in turn, so a network that BLACKHOLES one family --
        # dropping silently rather than answering ENETUNREACH -- pays the full
        # [](#opt-common.timeSync.timeoutSeconds) per address on both the DoH and the NTS leg.
        # While the unit retried every 30s, being killed at 90s cost one attempt; now it costs an
        # hour, and reads in the journal as a failure of the providers rather than of the ceiling.
        # Still far below the interval, so a run can never overlap its successor.
        TimeoutStartSec = "5min";

        # Setting the clock is the entire point, so unlike every other hardened unit in this
        # repo ProtectClock must stay off and CAP_SYS_TIME must survive the bounding set.
        ProtectClock = false;
        AmbientCapabilities = [ "CAP_SYS_TIME" ];
        CapabilityBoundingSet = [ "CAP_SYS_TIME" ];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
        SystemCallArchitectures = "native";
        # @clock is not in @system-service and is exactly what this needs.
        SystemCallFilter = [ "@system-service" "@clock" ];
      };
    };

    systemd.services.chrony-wait = {
      description = "Wait for chrony to synchronise the clock";
      after = [ "chronyd.service" ];
      requires = [ "chronyd.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Bounded rather than `waitsync 0`, which waits forever and would leave a unit that can
        # never be reported as failed. On timeout systemd retries, so an unsynchronised host
        # keeps trying without ever pretending to have succeeded.
        ExecStart = "${lib.getExe' config.services.chrony.package "chronyc"} waitsync 60 0 0 1";
        ExecStartPost = "${pkgs.coreutils}/bin/touch ${cfg.syncedMarker}";
        Restart = "on-failure";
        RestartSec = 10;
        RuntimeDirectory = baseNameOf (dirOf cfg.syncedMarker);
        # The marker is this unit's entire output; the default would delete it the moment the
        # oneshot's process exits. Same reasoning as the watchdog marker in
        # modules/connectivity-watchdog.nix.
        RuntimeDirectoryPreserve = true;
      };
    };

    # Point the metrics clock gate at chrony's marker. Without this it keeps following
    # services.timesyncd.enable, which enabling chrony forces to false -- so the gate would
    # silently switch itself off exactly on the host that needs it, and the RTC-less Pi would
    # go back to writing 1970-dated rows into a store with no retention.
    common.systemMetrics = lib.mkIf config.common.systemMetrics.enable {
      requireClockSync = lib.mkDefault true;
      syncedMarker = lib.mkDefault cfg.syncedMarker;
    };
  };
}
