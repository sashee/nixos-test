{ config, lib, pkgs, ... }:

# Time synchronisation: chrony over NTS, plus the boot-time rough clock that makes NTS
# reachable in the first place.
#
# One module rather than two, because the two halves only make sense together. These hosts
# resolve names over DoH and synchronise over NTS, and both are TLS -- so a clock outside
# certificate validity blocks name resolution and time synchronisation simultaneously, and
# neither can recover the other. A Raspberry Pi with no RTC battery is in exactly that state
# on every cold boot.
#
# The order out of that deadlock is:
#
#   rough-time  dials the DoH providers' PINNED ADDRESSES over HTTPS, ignoring certificate
#               dates during the handshake and re-checking them against the Date the server
#               reported. No name resolution, so it does not need DNS; no trust in the clock,
#               so it does not need the clock. Sets a rough time and exits.
#   dnscrypt    now that the clock is inside certificate validity, DoH works, so names resolve.
#   chronyd     resolves the NTS hostnames and takes over. It is authoritative; whatever
#               rough-time set is only a seed accurate to a minute or so.
#
# rough-time asks the kernel (STA_UNSYNC) before touching anything, so on a host whose clock
# is already disciplined -- a laptop with a working RTC, or any warm reboot where chrony got
# there first -- it is a no-op.
#
# It reaches the same NTS servers chrony does, which is the point: bootstrap and steady state
# rest on one set of parties. It gets there by resolving their names through a DoH resolver
# dialled at a pinned address, because that is the one thing on this host that needs neither
# DNS nor a clock. Certificate time checks are deferred on BOTH legs and re-applied against the
# time the NTS server reports -- so a chain that was not valid at that instant is rejected, and
# the build-time floor bounds how far back a once-valid certificate could roll things.
#
# Not covered here, deliberately: nothing removes the synchronised marker if chrony later
# loses all its sources. The marker means "this boot reached synchronisation once", which is
# what its consumers actually want -- a gate that reopened mid-run would make measurements
# vanish rather than make them more correct.

let
  cfg = config.common.timeSync;

  dohStamps = import ../lib/doh-stamps.nix { inherit lib; };
  ntsServers = import ../lib/nts-servers.nix { inherit lib; };

  # "--doh <name>=<hostname>@<addr>[,<addr>]", straight off lib/doh-stamps.nix so the addresses
  # rough-time dials are the same ones dnscrypt-proxy dials and cannot drift. These are only
  # used to RESOLVE: the time itself comes from NTS.
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
  # while rough-time kept dialling the real four would be testing two different configurations
  # at once, and the halves would disagree about what the host is even talking to.
  selected = lib.filterAttrs (_: p: lib.elem p.hostname cfg.servers) ntsServers.providers;

  ntsArgs = lib.concatMap (
    name:
    let
      p = selected.${name};
    in
    [ "--nts" "${name}=${p.hostname}@${p.operator}" ]
  ) (builtins.attrNames selected);

  roughTimeArgs =
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
  # `rough-time --force --dry-run` on a live host asks exactly what the boot service asks.
  # Same idea as the `system-metrics` wrapper in modules/system-metrics.nix.
  roughTimeCommand = pkgs.writeShellApplication {
    name = "rough-time";
    text = ''
      exec ${lib.escapeShellArgs ([ (lib.getExe cfg.package) ] ++ roughTimeArgs)} "$@"
    '';
  };
in

{
  options.common.timeSync = {
    # Opt-in like the other common.* modules, so a host that has not been thought about does
    # not silently acquire a service that sets its clock from an HTTP header.
    enable = lib.mkEnableOption "chrony over NTS plus the boot-time rough clock";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../packages/rough-time/package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ../packages/rough-time/package.nix { }";
      description = "The rough-clock binary the boot service runs.";
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
        Per-connection connect and read timeout. Every address is dialled in parallel, so this
        is roughly the whole run's duration when a provider is unreachable rather than a cost
        per address -- which matters on a v4-only host, where every IPv6 endpoint times out.
      '';
    };

    restartSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = ''
        Delay between attempts at the rough clock. It retries until it succeeds: there is no
        useful terminal state, because a host that never learns the time never gets DNS either.

        Also keeps the unit clear of systemd's start rate limit, which would otherwise stop
        retrying after five attempts -- at 30s the default window of five starts in ten
        seconds can never fill.
      '';
    };

    servers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ntsServers.hostnames;
      defaultText = lib.literalExpression "(import ../lib/nts-servers.nix { inherit lib; }).hostnames";
      description = ''
        The NTS servers chrony synchronises against. Hostnames, resolved through this host's
        own DoH resolver once the rough clock has made that possible.
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
          lib/doh-stamps.nix, so the rough clock could never assemble a quorum.
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

          chrony would use it, but rough-time could not: it needs the operator that file carries,
          because the operator is what decides whether two answers count as one source or two.
          Add the host there rather than only here.
        '';
      }
    ];

    environment.systemPackages = [ roughTimeCommand ];

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
      # what clears the bit. Without it chronyd synchronises perfectly and the kernel still
      # reports the clock as unsynchronised forever -- which would make rough-time step the
      # clock from an HTTP header on every boot despite chrony already having it right, and
      # would make `timedatectl` report NTPSynchronized=no on a host that is synchronised.
      # Confirmed by tests/nts-sync.nix, whose "stands down once something has synchronised"
      # subtest fails outright with the nixpkgs default.
      #
      # Nothing here needs a trimmed RTC. The Pi has no RTC battery at all, and what the
      # laptop needs is that the next boot starts close to correct -- which an 11-minute copy
      # gives, and which tests/boot-clock.nix asserts by checking the RTC is read in the
      # initrd, not by checking its precision.
      enableRTCTrimming = false;
      extraConfig = ''
        minsources ${toString cfg.minSources}
        rtcsync
      '';
    };

    systemd.services.rough-time = {
      description = "Establish a rough system clock from the DoH providers";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      # Before chronyd: chronyd needs DNS, DNS needs DoH, DoH needs a plausible clock. This is
      # ordering only, not a dependency -- if the rough clock never succeeds, chronyd should
      # still be running and trying, because an RTC-equipped host may not need this at all.
      before = [ "chronyd.service" ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.escapeShellArgs ([ (lib.getExe cfg.package) ] ++ roughTimeArgs);
        # Retry until the clock is set. RemainAfterExit so a success is visible in
        # `systemctl status` for the rest of the boot rather than looking like a dead unit.
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = cfg.restartSeconds;

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
