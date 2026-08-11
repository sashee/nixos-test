# The ceiling should stay above the sum of the waits inside the test, so a slow run fails on the
# subtest that was slow rather than on the global deadline.
{ nixpkgs, pkgs, stateVersion, machineModule, dohStamps, ntsServers, globalTimeout ? 1200 }:

# The whole time chain, on the real host config: correction service -> DNS -> chrony over NTS.
#
# tests/time-correction.nix covers the correction service itself -- its quorum, floor and deferred
# certificate checks -- against controlled DoH resolvers and NTS servers. This covers what
# happens after it, and it is the only place the bootstrap deadlock is actually reproduced
# rather than described:
#
#   the machine boots with its clock years out, so DoH's TLS cannot validate and no name
#   resolves; time-correction reaches the DoH providers by pinned address, resolves an NTS server
#   through them, takes an authenticated timestamp from it and corrects the clock; DNS starts
#   working; chronyd resolves the NTS hostnames itself and synchronises over NTS-KE.
#
# Nothing about the machine is reconfigured to make that work. It runs the deployed chrony
# config against real NTS servers, resolving real hostnames through the real dnscrypt-proxy.
# What the test owns is the other end: two chronyd NTS servers with a certificate the machine
# trusts, and a DoH interceptor that answers the NTS hostnames with their addresses.
#
# Two servers rather than one, both correct to begin with, because the falseticker subtest
# needs a second source to disagree with -- skewing one of them afterwards is what turns
# "multiple servers" from a configuration detail into something observable.
#
# IPv4-only, deliberately, and it is worth saying why rather than leaving it to be re-discovered.
# The spec says "everything should work in IPv6-only networks and IPv4-only networks as well",
# and this node's interceptor answers AAAA with NODATA while the DoH v6 addresses are routed
# `unreachable` -- so nothing here crosses a v6 socket. What that leaves uncovered is only
# chronyd's own NTS-KE and NTPv4 over IPv6, because the two legs either side of it are covered
# elsewhere and both are the halves this repo actually writes:
#
#   * dnscrypt-proxy over IPv6 only, by the dedicated `ipv6Client` node in tests/doh-upstream.nix,
#     which makes the v4 upstreams unreachable and asserts resolution still works;
#   * time-correction over IPv6 only, by three subtests in tests/time-correction.nix -- a v4-only
#     host, a v6-only host, and an NTS server reachable only over IPv6, which is the case that
#     caught the program asking for A records alone.
#
# chronyd reaches its sources by hostname through the system resolver, and nothing in
# modules/time-sync.nix says anything about address families, so the remaining gap is upstream
# chrony's socket handling rather than this repo's configuration of it. Closing it would cost a
# fifth VM in one of the slowest checks in the suite (four VMs, a real reboot and several chrony
# synchronisations, 2400s of headroom on the TCG aarch64 runner -- tests/time-correction.nix runs
# six). If the v6 path ever does break, it breaks in chrony and this is the note that says where
# to start.

let
  lib = nixpkgs.lib;

  # The subset of lib/nts-servers.nix this test points at. Two, because `minsources 2` needs
  # two selectable sources: a third unreachable name would only add resolution delay, and the
  # deployed list is guarded at eval time by tests/nts-servers.nix instead.
  #
  # Selected by role rather than named here (see tests/nts-fixtures.nix): the two must be under
  # different operators or the falseticker and disagreement subtests would be one vote arguing
  # with itself.
  roles = import ./nts-fixtures.nix { inherit lib ntsServers; };
  good = roles.good;
  liar = roles.stale;
  goodHost = good.hostname;
  liarHost = liar.hostname;

  # One certificate for both servers, SAN'd for both names, so which node answers which
  # hostname is a routing decision rather than a certificate one.
  ntsCert = import ./test-cert.nix { inherit pkgs; } {
    name = "nts";
    sans = [ goodHost liarHost ];
  };

  # A chronyd serving NTS from its own clock. `local stratum 10` is what makes an island with
  # no upstream a usable reference instead of a server that refuses to answer until it has
  # synchronised something itself.
  #
  # `upstream` is what keeps the two servers agreeing with each other. Measured without it,
  # two independent QEMU guests sat 576ms apart while each advertised +/-285us of confidence,
  # so their intervals never overlapped and the machine's `minsources 2` correctly refused to
  # believe either -- a property of running two VM clocks, not of anything under test. Chaining
  # the second server to the first gives the pair one clock, which is what a real host sees
  # from four servers that are all actually right. The falseticker subtest severs the chain
  # deliberately.
  #
  # Chaining alone is not enough, though, and the 2026-08-10 rpi5-x86 run is why the source line
  # below is written by hand. On chrony's defaults the chained server polls its upstream every 64
  # seconds and may step only three times ever, so it holds the pair together only as well as its
  # frequency estimate -- and these guests run on `clocksource=acpi_pm` (nixpkgs
  # test-instrumentation.nix), whose rate wanders with host load. That run put the pair 91ms apart
  # while each still advertised +/-360us, so `minsources 2` again found no overlap and the machine
  # never synchronised:
  #
  #   machine # chronyd: Can't synchronise: no majority (no agreement among 2 sources)
  #   ^x time.cloudflare.com  10  6  77  13  -313ms[ -313ms] +/-  356us
  #   ^x nts.netnod.se        10  6  77  14  -222ms[ -222ms] +/-  359us
  #
  # 91ms over the 160s since its last step is ~570ppm of uncorrected rate, and what the machine
  # allows is the sum of those two error bars: ~0.7ms. So the residual has to be held under
  # roughly a thousandth of what the defaults were holding, and only two things do that:
  #
  #   * `minpoll -2` (250ms), which bounds the residual at wander x poll interval -- ~143us at
  #     the rate above, ~5x inside the budget -- and, just as importantly, gives chronyd ~240
  #     samples a minute instead of one, which is what collapses the regression error it had
  #     after three noisy samples on a fresh drift file. `maxpoll 0` because chrony enables a
  #     sub-second interval only while the round trip stays under 10ms (chrony.conf(5)), so under
  #     load this degrades to 1s polls -- ~570us, still inside -- rather than back to 64s.
  #   * `makestep <threshold> -1`, an unlimited number of steps, for the state that produced the
  #     91ms in the first place: once the default `limit 3` is spent a large excursion can only be
  #     slewed, and chronyd sat on it for 150s across six polls. With no limit it is stepped away
  #     at the next poll instead.
  #
  # Neither can be expressed through the nixpkgs module: `serverOption` is an enum of
  # iburst/offline with nowhere to put a poll interval, and `makestep.limit` is
  # `types.ints.positive`, so -1 is not a value it accepts. Hence `servers = [ ]`,
  # `makestep.enable = false`, and both lines written out below.
  #
  # `local activate` is the third part, and it is about the DRIVER rather than about either
  # clock: it is what makes the wait for `Leap status ... Normal` on the chained node mean
  # anything. A bare `local` reference is eligible the moment chronyd starts (`activate` defaults
  # to 0.0 and `waitunsynced` to 0), so that node reports Normal off its own clock without having
  # exchanged a packet with anyone -- in the run above the wait returned in 0.19s, two seconds
  # BEFORE the node first selected its upstream and before the 0.87s step that followed, so the
  # driver moved on while the pair had never agreed about anything. With `activate` the local
  # reference stays inert until the root distance has once dropped below the threshold, which
  # cannot happen without a real exchange.
  #
  # Only on the chained node: the unchained one has no upstream, could never satisfy it, and
  # would then never serve at all. It does not disturb the falseticker subtest either, because
  # activation is a one-shot latch ("for the first time") -- after that subtest steps this node
  # three hours forward, chronyd resets to unsynchronised and the local reference comes straight
  # back.
  #
  # The gate this buys is real but loose: it catches "never reached its upstream", not "reached it
  # and is 91ms out", because nothing chronyd reports about ITSELF can show the latter -- it
  # believed it was holding the upstream to microseconds while it was 91ms off. The only competent
  # observer of that is the machine, and its view is already in wait_synced's failure dump.
  mkNtsServer = upstream: { ... }: {
    virtualisation.memorySize = 512;
    networking.firewall.enable = false;

    services.chrony = {
      enable = true;
      servers = [ ];
      makestep.enable = false;
      extraConfig = ''
        local stratum 10${lib.optionalString (upstream != null) " activate 0.1"}
        allow all
        ntsserverkey ${ntsCert.keyFile}
        ntsservercert ${ntsCert.certFile}
        # No helper processes: one chronyd in a 512 MB VM has nothing to hand work to, and
        # the helpers only complicate what the journal shows when NTS-KE fails.
        ntsprocesses 0
      ''
      # Plain NTP for the intra-test chain: NTS is what the MACHINE must use, and making the
      # servers authenticate to each other would only test the harness. See the header above for
      # where the poll interval and the step limit come from.
      + lib.optionalString (upstream != null) ''
        server ${upstream} iburst minpoll -2 maxpoll 0
        makestep 0.0001 -1
      '';
    };
    system.stateVersion = stateVersion;
  };

  # chrony's drift file, and so the persisted last-known-good time `chronyd -s` reads. The path
  # is the nixpkgs chrony module's (`${services.chrony.directory}/chrony.drift`), restated here
  # because the driver has to stat and touch it and there is no option exposing it.
  driftFile = "/var/lib/chrony/chrony.drift";

  # One ordered list of (hostname, node) drives both the argv slots the interceptor reads and
  # the addresses the dohpeer node passes, so a hostname cannot end up pointed at the other
  # server's address by an argv index edited on one side only.
  dnsOrder = [
    { host = goodHost; node = "ntsgood"; }
    { host = liarHost; node = "ntsliar"; }
  ];
  mappingExpr =
    "{"
    + lib.concatStringsSep ", " (lib.imap0 (i: e: "\"${e.host}\": ARGS[${toString i}]") dnsOrder)
    + "}";

  interceptor = import ./doh-interceptor.nix {
    inherit pkgs dohStamps;
    name = "nts-sync";
    readyFile = "/tmp/fake-doh-ready";
    # Answers the two NTS hostnames with the addresses passed as argv, and anything else with
    # NXDOMAIN. Same shape as the relay impersonation in tests/iroh-ssh.nix: the machine's
    # resolver configuration is untouched, it simply gets different answers.
    respond = ''
      def respond(query, meta):
          name, qtype, _, _ = read_question(query)
          mapping = ${mappingExpr}
          if name not in mapping:
              return nxdomain(query)
          if qtype != 1:
              # The machine is v4-only here; answering AAAA with NODATA rather than NXDOMAIN
              # keeps getaddrinfo from treating the name as absent altogether.
              return nodata(query)
          return a(query, mapping[name])
    '';
  };
in

nixpkgs.lib.nixos.runTest {
  name = "nts-sync";
  hostPkgs = pkgs;
  skipTypeCheck = true;

  # Ceiling, not a wait: four VMs, a reboot, and several chrony synchronisations, all under
  # TCG emulation on the KVM-less aarch64 runner.
  inherit globalTimeout;

  # Four nodes rather than six, so the margin here is wider than the run that forced this -- but
  # the reboots re-roll it, and a lost backdoor is unrecoverable. See the file.
  defaults = import ./slow-tcg-node.nix;

  nodes.dohpeer = { nodes, ... }: {
    networking = {
      hostName = "dohpeer";
      firewall.enable = false;
    };
    virtualisation.memorySize = 512;
    systemd.services.fake-doh = interceptor.mkService {
      args = map (e: nodes.${e.node}.networking.primaryIPAddress) dnsOrder;
    };
    system.stateVersion = stateVersion;
  };

  nodes.ntsgood = { ... }: {
    imports = [ (mkNtsServer null) ];
    networking.hostName = "ntsgood";
  };

  # Tracks ntsgood, so the two agree closely enough for the machine to form a majority. The
  # falseticker subtest cuts the link and steps this clock.
  nodes.ntsliar = { nodes, ... }: {
    imports = [ (mkNtsServer nodes.ntsgood.networking.primaryIPAddress) ];
    networking.hostName = "ntsliar";
  };

  nodes.machine = { lib, ... }: {
    imports = [ machineModule ];

    networking.hostName = "nts-sync-test";

    common.autoUpgrade.enable = lib.mkForce false;
    common.monitoring.enable = lib.mkForce false;
    common.irohSsh.enable = lib.mkForce false;

    # The clock goes back to 2001 and forward again repeatedly below, and nix-gc.timer is
    # Persistent, so a forward jump past a missed OnCalendar fires a store-wide delete in the
    # middle of a subtest. Same reasoning and remedy as tests/restic.nix.
    nix.gc.automatic = lib.mkForce false;

    # And fstrim.timer for the same reason: `OnCalendar=weekly` and on by default, so every
    # forward jump crosses a weekly boundary and fires it again until back-to-back starts trip
    # systemd's start limit and leave the unit failed. Not observed failing here -- it was
    # tests/time-correction.nix that caught it -- but this test jumps the clock the same way, so
    # it is latent rather than absent.
    services.fstrim.enable = lib.mkForce false;

    # mkForce: the shared test-node layer switches time sync off on every node (see
    # testNodeTimeSyncOff in flake.nix), and here it is the thing under test.
    common.timeSync = {
      enable = lib.mkForce true;
      servers = lib.mkForce [ goodHost liarHost ];
      # Well below any date this test uses, so the floor never masks a different failure --
      # tests/time-correction.nix is where the floor itself is exercised.
      floor = lib.mkForce 1000000000;
      # Nothing here exercises an unreachable provider, so the short timeout that keeps
      # tests/time-correction.nix brisk buys nothing.
      timeoutSeconds = 10;
      # The correction service is driven by hand throughout: several subtests park the clock in
      # 2001 for a minute or more at a stretch, and a timed run landing in the middle of one
      # would step the clock back out from under it. `bootDelay` past the end of the run leaves
      # the timer installed and deployed-shaped while giving the driver sole control of when the
      # unit actually runs.
      bootDelay = "3h";
    };

    # The ONE thing about chrony this node changes, and it changes a tempo rather than a
    # mechanism: how often chronyd rewrites its drift file, which is the persisted last-known-good
    # time the spec's "must write ... regularly" is about.
    #
    # chrony's default interval is 3600s and the nixpkgs module emits `driftfile <path>` with no
    # way to pass one, so observing a periodic write on the deployed cadence would need an hour of
    # guest time. `interval 1` makes it every clock update instead, so the write becomes visible
    # in seconds. Everything else about the mechanism -- the path, the trigger, the fact that
    # chronyd can write there at all under the unit's hardening -- is exactly as deployed.
    #
    # A second `driftfile` line is an override rather than a duplicate: chrony's parser does
    # `Free(drift_file); drift_file = Strdup(path)` and takes `interval` from whichever line came
    # last (chrony 4.8 conf.c:1771-1789). mkAfter, because the nixpkgs module interpolates
    # `extraConfig` at the END of chrony.conf and our own module contributes `minsources` and
    # `rtcsync` to it -- so this has to be the last definition to be the last line.
    services.chrony.extraConfig = lib.mkAfter ''
      driftfile ${driftFile} interval 1
    '';

    # Both CAs: the DoH interceptor's, so dnscrypt-proxy and time-correction accept it, and the NTS
    # servers', so chrony's NTS-KE does. Nothing else about the node changes.
    security.pki.certificateFiles = [ interceptor.caFile ntsCert.caFile ];

    system.stateVersion = stateVersion;
  };

  testScript = ''
    doh_ipv4 = ${builtins.toJSON interceptor.dohIpv4}
    doh_ipv6 = ${builtins.toJSON interceptor.dohIpv6}
    MARKER = "/run/chrony-wait/synchronized"
    # The one question that decides whether this host has a resolver at all: an NTS hostname,
    # asked of dnscrypt-proxy on the loopback address modules/doh.nix binds. Named once because
    # it is asked in both directions -- wait_dns waits for it to succeed, and "with the clock
    # years out" asserts it fails -- and a subtly different question on the two sides would let
    # them disagree about what "DNS works" means.
    RESOLVE = "${pkgs.dig}/bin/dig +short +time=3 +tries=1 @127.0.0.1 ${goodHost} | grep -q ."

    start_all()

    dohpeer.wait_for_unit("fake-doh.service")
    dohpeer.succeed(
        "${pkgs.coreutils}/bin/timeout 60 ${pkgs.bash}/bin/bash -c "
        "'until test -e /tmp/fake-doh-ready; do sleep 0.2; done'"
    )
    ntsgood.wait_for_unit("chronyd.service")
    ntsliar.wait_for_unit("chronyd.service")
    # The pair must agree before the machine is asked to believe them, or it will refuse for
    # a reason that has nothing to do with what any subtest is checking.
    ntsliar.wait_until_succeeds(
        "${pkgs.chrony}/bin/chronyc tracking | grep -q 'Leap status.*Normal'", timeout=180
    )
    machine.wait_for_unit("multi-user.target")

    with subtest("no reboot failsafe is installed"):
        # The spec asks for no reboot failsafe, and this is the guard against one appearing:
        # several subtests below leave this host deliberately unsynchronised for a minute or more
        # at a stretch, and a unit whose job was to reboot an unsynchronised host would fire in
        # the middle of them -- taking the machine down for a reason the failing subtest would not
        # name.
        #
        # Asserted name-agnostically, since a guard against one particular unit name is a guard
        # against nothing. A unit that reboots an unsynchronised host has to find out that the
        # host is unsynchronised, and the only two things here that know are the correction
        # service and the marker chrony-wait writes -- so anything ordered off either of them is
        # the shape being guarded against, whatever it is called. Not asserted by enumerating
        # units that invoke `reboot`: connectivity-watchdog and connectivity-fallback legitimately
        # do, and an allowlist of those would make this subtest fail whenever an unrelated module
        # gained a reboot.
        def pullers(unit, prop):
            # One property per call with --value: `systemctl show -p NAME` omits properties whose
            # value is empty unless --all is passed, so asking for several at once and matching on
            # the output silently tests nothing when one of them is unset.
            return machine.succeed(
                f"systemctl show -p {prop} --value {unit}"
            ).split()

        assert pullers("time-correction.service", "TriggeredBy") == ["time-correction.timer"]
        for prop in ["WantedBy", "RequiredBy", "BoundBy"]:
            assert pullers("time-correction.service", prop) == [], (
                f"something now pulls in the correction service via {prop}: "
                f"{pullers('time-correction.service', prop)}"
            )
        # chrony-wait is wantedBy multi-user.target and that is all it may be.
        assert pullers("chrony-wait.service", "WantedBy") == ["multi-user.target"]
        for prop in ["RequiredBy", "BoundBy", "TriggeredBy"]:
            assert pullers("chrony-wait.service", prop) == [], (
                f"something now keys off the sync marker via {prop}: "
                f"{pullers('chrony-wait.service', prop)}"
            )

    def peer_ip(node):
        return node.wait_until_succeeds(
            "${pkgs.iproute2}/bin/ip -j -4 addr show dev eth1 "
            "| ${pkgs.jq}/bin/jq -r '.[0].addr_info[] | select(.prefixlen==24) | .local' "
            "| ${pkgs.gnugrep}/bin/grep .",
            timeout=120,
        ).strip()

    def connect_upstream():
        # Runtime routes, so they are gone after the reboot below -- which is what makes the
        # post-reboot phase start from the same "no DNS at all" state a real cold boot does.
        via = peer_ip(dohpeer)
        for ip in doh_ipv4:
            machine.succeed(f"${pkgs.iproute2}/bin/ip route replace {ip}/32 via {via} dev eth1")
        for ip in doh_ipv6:
            machine.succeed(f"${pkgs.iproute2}/bin/ip -6 route replace unreachable {ip}/128")

    def wait_dns(timeout=120):
        # DNS is a PRECONDITION of every chrony wait in this file, not a part of it: chronyd
        # reaches its sources by hostname through dnscrypt-proxy, so a host with no resolver
        # simply has no sources and `chronyc waitsync` counts to sixty with refid 00000000.
        # Waited on separately so that failure reports itself in two minutes as "DNS did not
        # come back" instead of as a ten-minute chrony timeout with the cause a subtest away.
        machine.wait_until_succeeds(RESOLVE, timeout=timeout)

    def clock(node=None):
        return int((node or machine).succeed("date +%s").strip())

    def chrony_conf():
        # Read out of the unit rather than from a fixed path: the nixpkgs module passes the file
        # as an -f argument from the store, so there is nothing in /etc to read and the store
        # path changes with the config.
        return machine.succeed(
            "systemctl cat chronyd.service | grep -o '/nix/store/[^ ]*chrony.conf' "
            "| head -1 | xargs cat"
        )

    def rtc():
        # hwclock prints an ISO-8601 instant and has no epoch output of its own, so `date` does
        # the conversion. --noadjfile with --utc, so this never depends on /etc/adjtime existing.
        return int(machine.succeed(
            'date -d "$(${pkgs.util-linux}/bin/hwclock --show --utc --noadjfile)" +%s'
        ).strip())

    def align_rtc():
        # Copy the system clock to the RTC, and settle the drift file's mtime with it.
        #
        # Called wherever the driver moves the clock, because `chronyd -s` reads both on every
        # start (spec: bump forward to the last known good time) and would otherwise undo the move.
        # RTC_Initialise does one of two things: set the clock FROM THE RTC in either direction --
        # `hwclock -s` semantics, chrony 4.8 rtc_linux.c:1016 steps on any offset over a second --
        # or, when the RTC reads earlier than the drift file's mtime, step the clock FORWARD to
        # that mtime instead (rtc.c:98-108).
        #
        # Leaving the RTC alone is not the neutral choice, it is an unrealistic one. `date -s` does
        # not touch the RTC, so these nodes would sit with a live emulated RTC pinned near the
        # present (tomorrow 10:00, lib/test-rtc-base.nix) while the system clock is parked in 2001
        # -- a state no real host is in. The Pi has no RTC at all, and the laptop's is kept current
        # by `rtcsync`, which has the kernel copy the system time to it every 11 minutes. This is
        # that copy, done on demand.
        machine.succeed("${pkgs.util-linux}/bin/hwclock --systohc --utc --noadjfile")
        machine.succeed("touch ${driftFile}")
        # The staging has to have worked. A read-only or unimplemented emulated RTC would leave it
        # at the present, and every subtest that depends on the parked clock would then fail
        # somewhere further along with no hint that the RTC was the cause.
        drift = clock() - rtc()
        assert abs(drift) < 60, f"the RTC did not follow the clock: it is {drift}s off"

    def set_clock(when):
        # chronyd is stopped first because a running one would fight the step -- it is tracking
        # real sources and would pull the clock back toward them, so a subtest that needs the
        # host to sit at a chosen time cannot leave it running.
        #
        # NOT because the step would kill it: chronyd logs "Backward time jump detected!" and
        # carries on, same MainPID either side, which the "a clock step under a running chronyd"
        # subtest asserts. Believing otherwise would make the retry loops below unsafe.
        machine.succeed("systemctl stop chronyd.service || true")
        machine.succeed(f"date -s '{when}'")
        # dnscrypt-proxy has to be restarted across ANY step, and a BACKWARD one is what makes
        # it mandatory rather than tidy. Its upstream re-probe is scheduled on the WALL clock
        # (jedisct1/go-clocksmith, ten seconds after a failed probe), so a step back by three
        # days parks the next probe three days out: the process stays active and silent, every
        # name stops resolving, and nothing in the guest ever recovers on its own. That is how
        # the 2026-08-07 CI run failed -- ten minutes of `refid 00000000` at the end of "the
        # restore is forward-only", whose restore steps the clock back three days.
        #
        # Here rather than at the call sites, because a step is exactly when it is needed and
        # the one call site that had it by hand was not the one that broke. Not in the deployed
        # configuration: on a real host time-correction steps a stale clock FORWARD, which only
        # makes the re-probe fire early, and dnscrypt-proxy keeps answering from the servers it
        # already has.
        machine.succeed("systemctl restart dnscrypt-proxy.service")
        align_rtc()

    def resync(dns=True):
        # Drop everything chrony knows and make it start over, so a subtest cannot pass on a
        # measurement taken before it changed anything.
        machine.succeed("rm -f " + MARKER)
        machine.succeed("systemctl stop chrony-wait.service || true")
        machine.succeed("systemctl reset-failed chrony-wait.service || true")
        # Before the restart, not after: chronyd runs with `-s`, so the start it is about to do
        # reads the RTC and the drift file. The correction service moves the SYSTEM clock and
        # nothing else -- setting the RTC is not its job, and on the Pi there is no RTC to set --
        # so without this the restart below would find a stale RTC and step the clock straight back
        # to where the correction service just rescued it from. In production `rtcsync` closes that
        # gap within 11 minutes; here it has to be closed on demand. See align_rtc.
        align_rtc()
        # `dns=False` only for the subtests that park the clock outside the DoH certificates'
        # validity on purpose, where an unresolvable host is the state under test rather than a
        # fault. Everywhere else a resolver has to be there before chronyd is asked to find one.
        if dns:
            wait_dns()
        machine.succeed("systemctl restart chronyd.service")
        machine.succeed("systemctl start --no-block chrony-wait.service")

    def wait_synced(timeout):
        # Every wait for the sync marker goes through here, so a timeout anywhere in the file
        # reports the same evidence. Written once because the first version of this dump existed
        # on ONE of the five waits, and the run that failed timed out on one of the other four.
        #
        # Every command is `|| true` and every read is a succeed() that cannot fail: this runs
        # with an exception in flight, and a failing command here would replace the real failure
        # with itself. (Same reason chrony_conf() is inlined rather than called.)
        try:
            machine.wait_for_file(MARKER, timeout=timeout)
        except Exception:
            machine.log("RESOLVES:\n" + machine.succeed("${pkgs.dig}/bin/dig +short @127.0.0.1 ${goodHost} || true"))
            machine.log("DNSCRYPT:\n" + machine.succeed("journalctl -b -u dnscrypt-proxy -o cat --no-pager | tail -40 || true"))
            machine.log("DNSCRYPTUNIT:\n" + machine.succeed("systemctl status dnscrypt-proxy.service --no-pager || true"))
            machine.log("SOURCES:\n" + machine.succeed("${pkgs.chrony}/bin/chronyc -N sources -v || true"))
            machine.log("CHRONYD:\n" + machine.succeed("journalctl -u chronyd -o cat --no-pager | tail -40 || true"))
            machine.log("CONF:\n" + machine.succeed("systemctl cat chronyd.service | grep -o '/nix/store/[^ ]*chrony.conf' | head -1 | xargs cat || true"))
            ntsgood.log("SERVERJOURNAL:\n" + ntsgood.succeed("journalctl -u chronyd -o cat --no-pager | tail -40 || true"))
            ntsgood.log("SERVERPORTS:\n" + ntsgood.succeed("${pkgs.iproute2}/bin/ss -lntu | head -20 || true"))
            raise

    with subtest("nothing has synchronised yet"):
        # The precondition the whole run rests on: this host comes up with no reachable time
        # source, so the marker chrony-wait writes must be absent until something fixes the clock.
        #
        # What the marker is FOR is deliberately not asserted here, and the split is what keeps
        # this test host-agnostic. That the metrics collector's ConditionPathExists is this marker
        # is a claim about rendered units, made for every deployed host by
        # tests/time-sync-deployed.nix; that systemd actually holds a unit back on such a
        # condition and releases it is covered against a real time source by
        # tests/system-metrics.nix. Neither needs this host -- which matters because
        # anya-feher-laptop deploys time sync and no collector at all, so a collector assertion
        # here would be an assertion about a feature that host does not have.
        machine.fail(f"test -e {MARKER}")

    with subtest("with the clock years out, nothing resolves"):
        # The deadlock the correction service exists to break, demonstrated rather than assumed.
        # set_clock restarts dnscrypt-proxy, which is what makes the failure below deterministic
        # rather than a race with whatever the resolver had already cached or already dialled.
        set_clock("2001-01-01 00:00:00")
        connect_upstream()
        machine.fail(RESOLVE)

    with subtest("the correction service breaks the deadlock and chrony takes over"):
        machine.succeed("systemctl reset-failed time-correction.service || true")
        machine.succeed("systemctl restart time-correction.service")
        corrected = clock()
        assert corrected > 1600000000, f"the clock was not corrected: {corrected}"

        # DNS only works because the clock does now.
        wait_dns()

        resync()
        wait_synced(150)

        tracking = machine.succeed("${pkgs.chrony}/bin/chronyc tracking")
        assert "Leap status" in tracking and "Not synchronised" not in tracking, tracking
        # Authenticated, not merely reachable: a source with no cookies would mean NTS-KE
        # silently did not happen.
        authdata = machine.succeed("${pkgs.chrony}/bin/chronyc -N authdata")
        assert "NTS" in authdata, authdata

        # Spec: "must use multiple servers to detect incorrect servers". The falseticker subtest
        # at the end of this run is the behavioural half, but it can only fail for the right
        # reason if this directive is present -- with chrony's default of 1, a single reachable
        # source is authoritative and that subtest would be asserting nothing. Pinned here rather
        # than there so config drift fails in the first minute of a four-VM run instead of the
        # last, and pinned as a directive because nothing else in the suite would notice it
        # vanishing.
        conf = chrony_conf()
        assert "minsources 2" in conf, conf

        # `rtcsync`, and the `enableRTCTrimming = false` that makes room for it. Both are ours
        # and both are load-bearing, in opposite directions:
        #
        #   * dropping `rtcsync` from our extraConfig is SILENT. chronyd would keep
        #     disciplining the clock and this whole test would still pass, while STA_UNSYNC
        #     stayed set forever -- so the kernel would never copy the system time to the RTC,
        #     and the laptop's next boot would start from a stale RTC that `chronyd -s` then
        #     believes. Nothing else in the suite looks at it.
        #   * `enableRTCTrimming` coming back (it is the nixpkgs DEFAULT) emits `rtcfile` and
        #     `rtcautotrim`, which conflict with `rtcsync`. That direction is not silent --
        #     nixpkgs' chrony module asserts on the combination -- so this half is a statement
        #     of intent rather than the guard, and it is one line.
        assert "rtcsync" in conf, conf
        for directive in ["rtcfile", "rtcautotrim"]:
            assert directive not in conf, f"enableRTCTrimming is back on: {conf}"

        # And the effect, which is the part worth having: `rtcsync` is what makes chronyd clear
        # the kernel's STA_UNSYNC, and systemd's NTPSynchronized is read straight off that bit
        # (timedated calls ntp_gettime and tests it). Asserting the directive alone would pass on
        # a chrony that parsed it and did nothing.
        machine.wait_until_succeeds(
            "timedatectl show -p NTPSynchronized --value | grep -qx yes", timeout=180
        )
        # Each hostname must become exactly one `server` line ending in `nts`. Both halves can
        # drift independently: nixpkgs emits `pool` instead of `server` for any hostname
        # containing "pool" (one name, several sources, which defeats the counting minsources
        # does), and `nts` is appended only under enableNTS. tests/nts-servers.nix guards the
        # deployed list against the pool spelling at eval time; this is the consequence that
        # check exists to prevent, read off the daemon that is actually running.
        sources = [
            l.strip() for l in conf.splitlines()
            if l.strip().startswith(("server ", "pool "))
        ]
        for host in ["${goodHost}", "${liarHost}"]:
            own = [l for l in sources if l.split()[1] == host]
            assert len(own) == 1, f"{host} is not exactly one source line: {sources}"
            assert own[0].startswith("server "), f"{host} became a pool: {own[0]}"
            assert own[0].split()[-1] == "nts", f"{host} is not authenticated: {own[0]}"

    with subtest("a clock already inside certificate validity is left alone"):
        # The program's only stand-down rule, on the node where the clock is genuinely right. It
        # needs no help from the kernel's STA_UNSYNC: a synchronised clock is inside the validity
        # of every certificate on the path by construction, so the certificate window alone
        # refuses to step it.
        #
        # And the exchange happens anyway, which is the half worth asserting -- the run is
        # evidence that DoH and NTS still work, not merely a repair that skips itself when the
        # clock looks fine.
        machine.succeed(f"test -e {MARKER}")
        output = machine.succeed("time-correction --dry-run 2>&1")
        assert "already inside the certificates' validity" in output, output
        # Non-vacuous: it did reach both providers rather than declining before the exchange.
        assert "asking" in output, output

    with subtest("NTS cookies are dumped when chronyd stops"):
        # chronyd writes the cookie dump on exit, not continuously, so this has to stop it
        # rather than look while it is running. One file per NTS-KE server, named by address.
        machine.succeed("systemctl stop chronyd.service")
        cookies = machine.succeed("ls /var/lib/chrony/*.nts").strip()
        assert cookies, "no NTS cookie dump was written"
        machine.log("cookie dump: " + cookies)
        machine.succeed("systemctl start chronyd.service")

    with subtest("cookies survive a reboot"):
        before = machine.succeed("systemctl stop chronyd.service; ls /var/lib/chrony/*.nts").strip()
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("multi-user.target")

        after = machine.succeed("ls /var/lib/chrony/*.nts").strip()
        assert after, "the NTS cookie dump did not survive the reboot"
        assert set(after.split()) == set(before.split()), f"{before!r} -> {after!r}"

        # And the host still gets there from a cold start, with the runtime routes gone --
        # which is the state a real power cycle leaves it in.
        connect_upstream()
        wait_synced(600)

    # ------------------------------------------------------------------------------------
    # The persisted last-known-good clock: `chronyd -s` plus the drift file's mtime.
    #
    # Spec: chrony "must write the last known good time regularly and bump the time forward to
    # this persisted value on boot". Both halves are chronyd's own, so what these subtests pin is
    # that the deployed configuration actually reaches them -- and, for the last one, that the step
    # really is forward-only, which is the only thing standing between this feature and a host
    # whose clock is dragged backwards on every start.
    #
    # Worth having spelled out, because the exact rule decides how each subtest has to be staged
    # (chrony 4.8 rtc.c:112-135 and rtc_linux.c:969-1025). With `-s`, chronyd:
    #
    #   * reads the drift file's mtime, or 0 if there is no drift file;
    #   * tries the RTC first. If /dev/rtc opens and reads, and the RTC is NOT earlier than that
    #     mtime, the clock is set from the RTC -- in EITHER direction, on any offset over a
    #     second, exactly as `hwclock -s` would;
    #   * otherwise -- no RTC, an unreadable one, or an RTC that reads earlier than the mtime,
    #     which is what a dead battery looks like -- steps the clock FORWARD to the mtime, and
    #     only forward.
    #
    # So "RTC behind the drift file" is the lever these subtests pull to reach the path the Pi
    # lives on, from a VM node that does have a working RTC.
    with subtest("chrony writes the last known good time regularly"):
        # The "regularly" half, on the running daemon -- not on shutdown. chronyd rewrites the
        # drift file whenever it computes a new clock update and at least `interval` has
        # accumulated (chrony 4.8 reference.c:1011-1017), and unconditionally on exit via
        # REF_Finalise. This node sets `interval 1` so the periodic trigger fires in seconds
        # instead of an hour; see the comment on nodes.machine for why that is a tempo change and
        # not a mechanism change.
        #
        # The directive itself is pinned too, because it is one we do not write: the nixpkgs chrony
        # module emits `driftfile <stateDir>/chrony.drift`, and if that ever moved or vanished this
        # whole feature would switch itself off with nothing else in the suite noticing.
        conf = chrony_conf()
        assert "driftfile ${driftFile}" in conf, conf
        # `-s` is the other half, and it is ours.
        assert "-s" in machine.succeed(
            "systemctl show -p ExecStart --value chronyd.service"
        ).split(), "chronyd is not started with -s"

        wait_synced(300)
        # Backdated to something no clock in this test ever sits at, so the wait below cannot be
        # satisfied by a write that happened before this subtest started.
        machine.succeed("touch -d '@1000000000' ${driftFile}")
        machine.succeed("systemctl is-active chronyd.service")
        # chronyd is left alone throughout: no stop, no restart, no signal. Whatever refreshes the
        # mtime here is the periodic write and nothing else. One poll interval is 64s at chrony's
        # default minpoll, so give it a few.
        machine.wait_until_succeeds(
            "test $(stat -c %Y ${driftFile}) -gt 1000000000", timeout=300
        )
        machine.succeed("systemctl is-active chronyd.service")
        recorded = int(machine.succeed("stat -c %Y ${driftFile}").strip())
        offset = clock() - recorded
        assert -120 < offset < 300, (
            f"the drift file's mtime is {offset}s away from the current clock ({recorded} vs "
            f"{clock()}); a last-known-good time has to be roughly now, not an arbitrary instant"
        )

    with subtest("and again when it stops, so a clean shutdown records its own stop time"):
        # The other trigger, and the one the man page's wording for -s is about: "restore the time
        # when chronyd was previously stopped". Same writer (update_drift_file), reached from
        # REF_Finalise instead of from the update path, so what this adds over the subtest above is
        # only that a shutdown does not skip it.
        stopped_at = clock()
        machine.succeed("systemctl stop chronyd.service")
        recorded = int(machine.succeed("stat -c %Y ${driftFile}").strip())
        age = recorded - stopped_at
        assert 0 <= age < 120, (
            f"the drift file was not refreshed on exit: mtime is {recorded}, "
            f"chronyd stopped at {stopped_at}"
        )

    with subtest("the persisted time is restored on boot"):
        # The spec's own wording is "on boot", so this is a real one rather than a `systemctl
        # start`. It is also the strongest form of the claim available: the runtime routes to the
        # DoH interceptor do not survive a reboot, so this host comes up with no DNS at all and
        # chronyd cannot reach a single source -- whatever moves the clock here moved it from a
        # local file.
        #
        # What has to be beaten is the RTC, not the system clock: chronyd only falls through to the
        # driftfile path when the RTC reads EARLIER than the mtime, logging "RTC time before last
        # driftfile modification (ignored)" on the way. Mis-stage that and this subtest tests
        # nothing while looking like it passed -- chronyd finds nothing to do, logs nothing, and
        # the clock the kernel already read from the RTC in the initrd looks plausible. Hence both
        # the deliberate margin below and the assertion under it.
        #
        # Three days, and it cannot be read off the RTC instead. `machine.start()` is a FRESH qemu
        # process with `-rtc base=$(date -u -d tomorrow +...T10:00:00)` (lib/test-rtc-base.nix), so
        # the emulated RTC is re-derived from that base on every boot: whatever this guest wrote to
        # it with `hwclock --systohc` earlier in the run is discarded, and it comes back reading up
        # to ~34h ahead of the host's real clock. A pre-reboot read therefore predicts nothing. What
        # it does bound is the post-reboot value, since every node's clock in this test descends
        # from that same base -- so three days past the larger of the current clock and the current
        # RTC is ahead of any RTC the next boot can produce.
        #
        # chronyd is already stopped by the subtest above, which matters: a running one would
        # rewrite the drift file on shutdown and undo the staging.
        persisted = max(clock(), rtc()) + 3 * 86400
        machine.succeed(f"touch -d '@{persisted}' ${driftFile}")

        machine.shutdown()
        machine.start()
        machine.wait_for_unit("multi-user.target")

        # The staging, checked against the RTC this boot actually came up with -- the assertion the
        # two broken versions of this subtest lacked. Without it a mis-staged mtime makes the
        # journal check below fail with chronyd's ordinary startup output and no hint why.
        booted_rtc = rtc()
        assert persisted > booted_rtc, (
            f"mis-staged: the drift file ({persisted}) is not ahead of this boot's RTC "
            f"({booted_rtc}), so chronyd took the RTC path and the restore was never exercised"
        )

        # The journal line is the precise evidence -- it is emitted only by the driftfile path, so
        # it cannot be satisfied by the RTC read or by chrony reaching a source.
        journal = machine.succeed("journalctl -b -u chronyd -o cat --no-pager")
        assert "restored from driftfile" in journal, journal
        # And the effect. Loose on the upper side on purpose: chronyd steps to the mtime early in
        # boot and the rest of the boot then runs on the stepped clock, so by the time the driver
        # can ask, a couple of minutes of ordinary startup have elapsed on top.
        restored = clock()
        drift = restored - persisted
        assert -60 < drift < 600, (
            f"the clock is {drift}s from the persisted {persisted} (it is {restored}); "
            f"the boot should have stepped it forward to the drift file's mtime"
        )

    with subtest("the restore is forward-only"):
        # The converse, and the one whose failure is silent -- a host whose clock is dragged
        # backwards on every start would still look synchronised most of the time, because chrony
        # would keep pulling it forward again.
        #
        # Staged so the driftfile path is what decides it, rather than the RTC: the RTC is put a
        # day behind the mtime (chronyd therefore ignores it, exactly as on a dead battery) while
        # the system clock is left an hour AHEAD of the mtime. Nothing may move.
        #
        # NTS is blocked as well, so a chronyd that reached a real source could not be what
        # produced the answer.
        nft = "${pkgs.nftables}/bin/nft"
        machine.succeed(f"{nft} add table inet blocknts2")
        machine.succeed(
            f"{nft} add chain inet blocknts2 out "
            "'{ type filter hook output priority 0; policy accept; }'"
        )
        machine.succeed(f"{nft} add rule inet blocknts2 out tcp dport 4460 drop")
        machine.succeed(f"{nft} add rule inet blocknts2 out udp dport 123 drop")
        try:
            machine.succeed("systemctl stop chronyd.service || true")
            persisted = clock()
            # RTC a day behind the mtime-to-be.
            machine.succeed(f"date -s @{persisted - 86400}")
            machine.succeed("${pkgs.util-linux}/bin/hwclock --systohc --utc --noadjfile")
            # Stopping chronyd rewrote the drift file, so set the mtime AFTER that, then put the
            # system clock an hour beyond it.
            machine.succeed(f"touch -d '@{persisted}' ${driftFile}")
            ahead = persisted + 3600
            machine.succeed(f"date -s @{ahead}")

            machine.succeed("systemctl reset-failed chronyd.service || true")
            machine.succeed("systemctl start chronyd.service")
            after = clock()
            assert after >= ahead - 60, (
                f"the clock went backwards: {ahead} -> {after}, toward the persisted {persisted}"
            )
            # And it really was the driftfile path being exercised, not the RTC read short-cutting
            # the decision -- otherwise this subtest would pass on a client with no direction rule
            # at all.
            journal = machine.succeed("journalctl -b -u chronyd -o cat --no-pager | tail -30")
            assert "before last driftfile modification" in journal, journal
        finally:
            machine.succeed(f"{nft} delete table inet blocknts2 || true")

        # Put the host back where the remaining subtests expect it: a clock and an RTC that agree
        # with the servers', a drift file that cannot bump anything, and a resolver again.
        #
        # The clock step here is BACKWARD by three days -- the subtest above pushed the host that
        # far into the future through the drift file -- which is the step that used to leave the
        # host with no resolver for the rest of the run. See set_clock; the routes have to be back
        # before resync() waits for a name to resolve through them.
        machine.succeed("systemctl stop chronyd.service || true")
        set_clock(f"@{clock(ntsgood)}")
        connect_upstream()
        resync()
        wait_synced(600)

    with subtest("a clock step under a running chronyd does not break it for good"):
        # The step this guards against is the correction service's own. It applies a timestamp as
        # old as the slowest leg of its exchange, truncated to a whole second, so on an
        # already-plausible clock the step it makes is BACKWARD -- and nothing orders it against
        # chronyd, so chronyd is running when it lands. If that could kill chronyd for the rest of
        # the boot, this host would end up permanently unsynchronised while DNS kept working, so
        # nothing else would notice and the metrics gate would stay shut forever.
        wait_synced(300)

        def chronyd_pid():
            return machine.succeed("systemctl show -p MainPID --value chronyd.service").strip()

        before_pid = chronyd_pid()
        before = clock()
        machine.succeed("date -s '-30 seconds'")
        # Non-vacuity, without depending on chrony's log wording: the clock really did move
        # backwards. Otherwise a step that silently did nothing would satisfy everything below.
        assert clock() < before - 20, f"the clock did not step back: {before} -> {clock()}"
        machine.sleep(15)

        # Alive, and the SAME process -- not merely restartable. Restart=on-failure would paper
        # over an exit here, and with systemd's default start limit a daemon that died on every
        # step would eventually stay dead.
        machine.succeed("systemctl is-active chronyd.service")
        after_pid = chronyd_pid()
        assert after_pid == before_pid, f"chronyd restarted across the step: {before_pid} -> {after_pid}"
        # Still doing the job it was doing, authenticated sources included.
        assert "NTS" in machine.succeed("${pkgs.chrony}/bin/chronyc -N authdata")
        machine.wait_until_succeeds(
            "${pkgs.chrony}/bin/chronyc tracking | grep -q 'Leap status.*Normal'", timeout=300
        )

    with subtest("no NTS-KE means no time, not unauthenticated time"):
        # Port 123 stays open and both servers keep serving correct time, so anything that
        # fell back to plain NTP would synchronise. Fail-closed means it must not.
        machine.succeed(
            "${pkgs.nftables}/bin/nft add table inet blocknts; "
            "${pkgs.nftables}/bin/nft add chain inet blocknts out "
            "'{ type filter hook output priority 0; policy accept; }'; "
            "${pkgs.nftables}/bin/nft add rule inet blocknts out tcp dport 4460 drop"
        )
        # The cached cookies have to go too. They are exactly what lets chrony authenticate
        # without a fresh NTS-KE, which the subtest above just proved works -- so leaving them
        # in place makes this pass for a reason that has nothing to do with fail-closed
        # behaviour. (First observed the other way round: this subtest failed because chrony
        # synchronised straight through the blocked port on reloaded cookies.)
        machine.succeed("systemctl stop chronyd.service")
        machine.succeed("rm -f /var/lib/chrony/*.nts")
        set_clock("2001-01-01 00:00:00")
        # dns=False: the clock is back in 2001, so the DoH certificates are not yet valid and no
        # name resolves. That is this subtest's own staging, not a fault to wait out.
        resync(dns=False)
        machine.sleep(60)
        machine.fail(f"test -e {MARKER}")
        assert clock() < 1600000000, "the clock moved without NTS -- that is a plaintext fallback"

        machine.succeed("${pkgs.nftables}/bin/nft delete table inet blocknts")

    with subtest("a server that disagrees with the others is not believed"):
        # Both sources were correct until now. Skewing one leaves chrony with two mutually
        # exclusive intervals and no majority, which -- with minsources 2 -- must resolve to
        # "no usable time" rather than to whichever answered first.
        # Re-establish a sane clock BEFORE skewing anything. time-correction now asks two NTS
        # operators and requires them to agree, so once one of them is lying it will correctly
        # refuse -- which is the behaviour under test here, not a way to set up for it.
        machine.succeed("systemctl reset-failed time-correction.service || true")
        machine.succeed("systemctl restart time-correction.service")
        corrected = clock()

        # Cut its upstream first, or chronyd simply steps the clock back to ntsgood's.
        ntsliar.succeed(
            f"${pkgs.iproute2}/bin/ip route replace unreachable {peer_ip(ntsgood)}"
        )
        ntsliar.succeed("date -s '+3 hours'")
        resync()
        machine.sleep(90)

        assert not machine.succeed(
            f"test -e {MARKER} && echo yes || echo no"
        ).strip().startswith("yes"), "chrony synchronised despite its sources disagreeing"
        drift = abs(clock() - corrected)
        assert drift < 600, f"the clock moved {drift}s toward a disagreeing source"

        sources = machine.succeed("${pkgs.chrony}/bin/chronyc sources")
        machine.log("sources with one skewed server:\n" + sources)

    with subtest("the correction service refuses a quorum that disagrees"):
        # chrony's half of "multiple servers to detect incorrect servers" is the subtest above.
        # This is the correction service's half, and it is the only place it is exercised against
        # real servers: tests/time-correction.nix forces `sample` to 1 (one of its two NTS
        # fixtures is deliberately expired, so a sample of two could never converge) and leaves
        # the arithmetic to fixtures in quorum.rs. Here `sample` is the deployed default of 2,
        # both certificates are valid, both names resolve, and ntsliar is three hours out --
        # which the subtest above already staged, so this costs no nodes and no setup.
        #
        # It is also the ONLY thing that exercises common.timeSync.tolerance at all. The option
        # has no other test: not the default, not the --tolerance argument, not the behaviour.
        # Hence matching on the bound as well as on the verdict -- a run that refused because
        # the module had threaded some other number through would pass a laxer assertion.
        #
        # --dry-run and NOT --force: the disagreement is decided in `quorum::decide`, which runs
        # before the stand-down rule, so no flag is needed to reach it and the clock is never a
        # candidate to be touched. Driven through the wrapper rather than `systemctl start` so
        # this leaves no failed unit behind for anything after it.
        output = machine.fail("time-correction --dry-run 2>&1")
        assert "operators disagree by" in output, output
        assert "(>60s)" in output, f"the deployed tolerance did not reach the binary: {output}"
        # Both operators are named in the spread, which is what makes the failure actionable --
        # and proves both were actually asked rather than one having simply failed.
        for operator in ["${good.operator}", "${liar.operator}"]:
            assert operator in output, f"{operator} is missing from the spread: {output}"
        # Non-vacuity: it must have failed on the disagreement, not on a pair that broke on the
        # way. Those exit through a different message and would satisfy nothing above, but they
        # would also mean this subtest never reached the quorum at all.
        assert "provider pairs failed" not in output, output

  '';
}
