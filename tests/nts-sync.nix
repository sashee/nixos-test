# Back to 1200 now that the unwedge node is gone (it added two 120s countdowns plus a real
# reboot). The ceiling should stay above the sum of the waits inside the test so a slow run fails
# on the subtest that was slow rather than on the global deadline.
{ nixpkgs, pkgs, stateVersion, machineModule, dohStamps, globalTimeout ? 1200 }:

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

let
  lib = nixpkgs.lib;

  # The subset of lib/nts-servers.nix this test points at. Two, because `minsources 2` needs
  # two selectable sources: a third unreachable name would only add resolution delay, and the
  # real four-name list is guarded at eval time by tests/nts-servers.nix instead.
  goodHost = "time.cloudflare.com";
  liarHost = "nts.netnod.se";

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
  mkNtsServer = upstream: { ... }: {
    virtualisation.memorySize = 512;
    networking.firewall.enable = false;

    services.chrony = {
      enable = true;
      # Plain NTP for the intra-test chain: NTS is what the MACHINE must use, and making the
      # servers authenticate to each other would only test the harness.
      servers = lib.optional (upstream != null) upstream;
      extraConfig = ''
        local stratum 10
        allow all
        ntsserverkey ${ntsCert.keyFile}
        ntsservercert ${ntsCert.certFile}
        # No helper processes: one chronyd in a 512 MB VM has nothing to hand work to, and
        # the helpers only complicate what the journal shows when NTS-KE fails.
        ntsprocesses 0
      '';
    };
    system.stateVersion = stateVersion;
  };

  # chrony's drift file, and so the persisted last-known-good time `chronyd -s` reads. The path
  # is the nixpkgs chrony module's (`${services.chrony.directory}/chrony.drift`), restated here
  # because the driver has to stat and touch it and there is no option exposing it.
  driftFile = "/var/lib/chrony/chrony.drift";

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
          mapping = {"${goodHost}": ARGS[0], "${liarHost}": ARGS[1]}
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

  nodes.dohpeer = { nodes, ... }: {
    networking = {
      hostName = "dohpeer";
      firewall.enable = false;
    };
    virtualisation.memorySize = 512;
    systemd.services.fake-doh = interceptor.mkService {
      args = [
        nodes.ntsgood.networking.primaryIPAddress
        nodes.ntsliar.networking.primaryIPAddress
      ];
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
    environment.systemPackages = [ pkgs.iproute2 ];

    networking.hostName = "nts-sync-test";

    common.autoUpgrade.enable = lib.mkForce false;
    common.monitoring.enable = lib.mkForce false;
    common.irohSsh.enable = lib.mkForce false;

    # The clock goes back to 2001 and forward again repeatedly below, and nix-gc.timer is
    # Persistent, so a forward jump past a missed OnCalendar fires a store-wide delete in the
    # middle of a subtest. Same reasoning and remedy as tests/restic.nix.
    nix.gc.automatic = lib.mkForce false;

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
        # The spec dropped it, so this is the guard against it coming back: several subtests
        # below leave this host deliberately unsynchronised for a minute or more at a stretch,
        # and a unit whose job was to reboot an unsynchronised host would fire in the middle of
        # them -- taking the machine down for a reason the failing subtest would not name.
        machine.fail("systemctl cat time-sync-unwedge.service")

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

    def clock(node=None):
        return int((node or machine).succeed("date +%s").strip())

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
        # carries on (same MainPID either side, asserted in the subtest below). The comment here
        # used to claim it exits, which would have made the whole retry loop unsafe.
        machine.succeed("systemctl stop chronyd.service || true")
        machine.succeed(f"date -s '{when}'")
        align_rtc()

    def start_collector():
        # Returns systemd's own verdict on the unit's conditions. A condition that is not met
        # makes `systemctl start` a satisfied no-op rather than an error, so the exit status
        # says nothing -- ConditionResult is the observable.
        #
        # reset-failed first because a oneshot started back to back trips the start rate limit
        # and would fail with "start-limit-hit" instead of running (tests/system-metrics.nix:86).
        machine.succeed("systemctl reset-failed system-metrics.service || true")
        machine.succeed("systemctl start system-metrics.service")
        return machine.succeed(
            "systemctl show -p ConditionResult --value system-metrics.service"
        ).strip()

    def resync():
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
        machine.succeed("systemctl restart chronyd.service")
        machine.succeed("systemctl start --no-block chrony-wait.service")

    with subtest("the collector is gated on chrony's marker, not timesyncd's"):
        # This wiring is why the RTC-less Pi does not write 1970-dated rows into a store that
        # has no retention, and until now nothing asserted it. tests/system-metrics.nix covers
        # the timesyncd marker, which no host uses any more -- enabling chrony forces timesyncd
        # off -- so the deployed gate was evaluated by these tests and checked by none of them.
        machine.succeed(
            f"systemctl cat system-metrics.service | grep -Fx 'ConditionPathExists={MARKER}'"
        )

        # Nothing has synchronised yet, so the collector must hold back even though the clock
        # is perfectly capable of producing a timestamp -- that is exactly the trap, since the
        # timestamp it would produce is wrong and permanent.
        machine.fail(f"test -e {MARKER}")
        condition = start_collector()
        assert condition == "no", f"the collector ran before the clock was synchronised ({condition})"

    with subtest("with the clock years out, nothing resolves"):
        # The deadlock the correction service exists to break, demonstrated rather than assumed.
        set_clock("2001-01-01 00:00:00")
        machine.succeed("systemctl restart dnscrypt-proxy.service")
        connect_upstream()
        machine.fail(f"${pkgs.dig}/bin/dig +short +time=3 +tries=1 @127.0.0.1 {'${goodHost}'} | grep -q .")

    with subtest("the correction service breaks the deadlock and chrony takes over"):
        machine.succeed("systemctl reset-failed time-correction.service || true")
        machine.succeed("systemctl restart time-correction.service")
        corrected = clock()
        assert corrected > 1600000000, f"the clock was not corrected: {corrected}"

        # DNS only works because the clock does now.
        machine.wait_until_succeeds(
            f"${pkgs.dig}/bin/dig +short +time=3 +tries=1 @127.0.0.1 {'${goodHost}'} | grep -q .",
            timeout=120,
        )

        resync()
        try:
            machine.wait_for_file(MARKER, timeout=150)
        except Exception:
            machine.log("SOURCES:\n" + machine.succeed("${pkgs.chrony}/bin/chronyc -N sources -v || true"))
            machine.log("CHRONYD:\n" + machine.succeed("journalctl -u chronyd -o cat --no-pager | tail -40 || true"))
            machine.log("RESOLVES:\n" + machine.succeed("${pkgs.dig}/bin/dig +short @127.0.0.1 ${goodHost} || true"))
            machine.log("CONF:\n" + machine.succeed("systemctl cat chronyd.service | grep -o '/nix/store/[^ ]*chrony.conf' | head -1 | xargs cat || true"))
            ntsgood.log("SERVERJOURNAL:\n" + ntsgood.succeed("journalctl -u chronyd -o cat --no-pager | tail -40 || true"))
            ntsgood.log("SERVERPORTS:\n" + ntsgood.succeed("${pkgs.iproute2}/bin/ss -lntu | head -20 || true"))
            raise

        tracking = machine.succeed("${pkgs.chrony}/bin/chronyc tracking")
        assert "Leap status" in tracking and "Not synchronised" not in tracking, tracking
        # Authenticated, not merely reachable: a source with no cookies would mean NTS-KE
        # silently did not happen.
        authdata = machine.succeed("${pkgs.chrony}/bin/chronyc -N authdata")
        assert "NTS" in authdata, authdata

    with subtest("the collector is released once chrony has synchronised"):
        # The other half of the gate. Asserting only the closed side would pass just as well
        # with a marker path that can never appear, which would silently stop collection
        # forever -- the failure modules/system-metrics.nix warns about in both directions.
        condition = start_collector()
        assert condition == "yes", f"the collector is still gated after synchronisation ({condition})"
        machine.log(
            "collector run result: "
            + machine.succeed("systemctl show -p Result --value system-metrics.service")
        )

    with subtest("a clock already inside certificate validity is left alone"):
        # The one stand-down rule the spec leaves, on the node where the clock is genuinely
        # right. There used to be a second one -- ask the kernel via adjtimex whether anything
        # had already synchronised the clock -- and it is gone, along with the subtest that
        # covered it and the one that staged the mid-exchange race it guarded. What replaces
        # both is this: a synchronised clock is inside the validity of every certificate on the
        # path by construction, so the window rule alone still refuses to step it.
        #
        # The difference is that the exchange now actually happens, which is the point of the
        # change: the run is evidence that DoH and NTS still work, not merely a repair that
        # skips itself when the clock looks fine.
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
        machine.wait_for_file(MARKER, timeout=600)

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
        conf = machine.succeed(
            "systemctl cat chronyd.service | grep -o '/nix/store/[^ ]*chrony.conf' "
            "| head -1 | xargs cat"
        )
        assert "driftfile ${driftFile}" in conf, conf
        # `-s` is the other half, and it is ours.
        assert "-s" in machine.succeed(
            "systemctl show -p ExecStart --value chronyd.service"
        ).split(), "chronyd is not started with -s"

        machine.wait_for_file(MARKER, timeout=300)
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
        # driftfile modification (ignored)" on the way. Two earlier versions of this subtest got
        # that staging wrong and silently tested nothing -- chronyd found nothing to do, logged
        # nothing, and the clock the kernel had already read from the RTC in the initrd looked
        # plausible -- so the margin below is deliberate and so is the assertion under it.
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
        machine.succeed("systemctl stop chronyd.service || true")
        set_clock(f"@{clock(ntsgood)}")
        connect_upstream()
        resync()
        machine.wait_for_file(MARKER, timeout=600)

    with subtest("a clock step under a running chronyd does not break it for good"):
        # The step this guards against is the correction service's own. It applies a timestamp as
        # old as the slowest leg of its exchange, truncated to a whole second, so on an
        # already-plausible clock the step it makes is BACKWARD -- and nothing orders it against
        # chronyd, so chronyd is running when it lands. If that could kill chronyd for the rest of
        # the boot, this host would end up permanently unsynchronised while DNS kept working, so
        # nothing else would notice and the metrics gate would stay shut forever.
        machine.wait_for_file(MARKER, timeout=300)

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
        resync()
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

  '';
}
