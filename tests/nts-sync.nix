{ nixpkgs, pkgs, stateVersion, machineModule, dohStamps, globalTimeout ? 1200 }:

# The whole time chain, on the real host config: rough clock -> DNS -> chrony over NTS.
#
# tests/rough-time.nix covers the rough clock itself -- its quorum, floor and deferred
# certificate checks -- against controlled DoH resolvers and NTS servers. This covers what
# happens after it, and it is the only place the bootstrap deadlock is actually reproduced
# rather than described:
#
#   the machine boots with its clock years out, so DoH's TLS cannot validate and no name
#   resolves; rough-time reaches the DoH providers by pinned address, resolves an NTS server
#   through them, takes an authenticated timestamp from it and sets a rough clock; DNS starts
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
  # Clears STA_UNSYNC without moving the clock, so "something synchronised the clock while
  # rough-time was mid-exchange" can be staged at a chosen instant rather than raced for.
  # Nothing but this test has any use for it; it exists only on the test node.
  clearUnsync = pkgs.writers.writePython3Bin "clear-unsync" { } ''
    import ctypes
    import ctypes.util


    class Timex(ctypes.Structure):
        _fields_ = [("modes", ctypes.c_uint), ("offset", ctypes.c_long),
                    ("freq", ctypes.c_long), ("maxerror", ctypes.c_long),
                    ("esterror", ctypes.c_long), ("status", ctypes.c_int),
                    ("constant", ctypes.c_long), ("precision", ctypes.c_long),
                    ("tolerance", ctypes.c_long), ("tv_sec", ctypes.c_long),
                    ("tv_usec", ctypes.c_long), ("tick", ctypes.c_long),
                    ("ppsfreq", ctypes.c_long), ("jitter", ctypes.c_long),
                    ("shift", ctypes.c_int), ("stabil", ctypes.c_long),
                    ("jitcnt", ctypes.c_long), ("calcnt", ctypes.c_long),
                    ("errcnt", ctypes.c_long), ("stbcnt", ctypes.c_long),
                    ("tai", ctypes.c_int), ("pad", ctypes.c_int * 11)]


    libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
    buf = Timex()
    assert libc.adjtimex(ctypes.byref(buf)) >= 0, "adjtimex read failed"
    buf.status &= ~0x0040  # STA_UNSYNC
    # Clearing the bit alone is not enough. The kernel grows time_maxerror
    # every second and re-sets STA_UNSYNC once it reaches NTP_PHASE_LIMIT,
    # and on a clock that has been unsynchronised it is already pinned
    # there -- so the bit came back within a second, and rough-time saw it
    # set again eighteen seconds into its exchange. Real daemons reset
    # these on every update; so must this.
    buf.maxerror = 0
    buf.esterror = 0
    # ADJ_MAXERROR | ADJ_ESTERROR | ADJ_STATUS
    buf.modes = 0x0004 | 0x0008 | 0x0010
    assert libc.adjtimex(ctypes.byref(buf)) >= 0, "adjtimex write failed"
  '';
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
    environment.systemPackages = [ clearUnsync pkgs.iproute2 ];

    networking.hostName = "nts-sync-test";

    common.autoUpgrade.enable = lib.mkForce false;
    common.monitoring.enable = lib.mkForce false;
    common.irohSsh.enable = lib.mkForce false;

    # mkForce: the shared test-node layer switches time sync off on every node (see
    # testNodeTimeSyncOff in flake.nix), and here it is the thing under test.
    common.timeSync = {
      enable = lib.mkForce true;
      servers = lib.mkForce [ goodHost liarHost ];
      # Well below any date this test uses, so the floor never masks a different failure --
      # tests/rough-time.nix is where the floor itself is exercised.
      floor = lib.mkForce 1000000000;
      # Headroom for the mid-exchange subtest, which slows the network deliberately. Nothing
      # here exercises an unreachable provider, so the short timeout that keeps
      # tests/rough-time.nix brisk buys nothing.
      timeoutSeconds = 10;
    };

    # Both CAs: the DoH interceptor's, so dnscrypt-proxy and rough-time accept it, and the NTS
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

    def peer_ip(node):
        return node.wait_until_succeeds(
            "${pkgs.iproute2}/bin/ip -j -4 addr show dev eth1 "
            "| ${pkgs.jq}/bin/jq -r '.[0].addr_info[] | select(.prefixlen==24) | .local' "
            "| ${pkgs.gnugrep}/bin/grep .",
            timeout=120,
        ).strip()

    def peer_ip6(node):
        return node.wait_until_succeeds(
            "${pkgs.iproute2}/bin/ip -j -6 addr show dev eth1 "
            "| ${pkgs.jq}/bin/jq -r '.[0].addr_info[] "
            "| select(.prefixlen==64 and .scope==\"global\") | .local' "
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

    def set_clock(when):
        # chronyd exits on a backward time jump ("Backward time jump detected!"), so it is
        # stopped first: the step is deliberate here and should not read as a crash.
        machine.succeed("systemctl stop chronyd.service || true")
        machine.succeed(f"date -s '{when}'")

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
        # The deadlock the rough clock exists to break, demonstrated rather than assumed.
        set_clock("2001-01-01 00:00:00")
        machine.succeed("systemctl restart dnscrypt-proxy.service")
        connect_upstream()
        machine.fail(f"${pkgs.dig}/bin/dig +short +time=3 +tries=1 @127.0.0.1 {'${goodHost}'} | grep -q .")

    with subtest("the rough clock breaks the deadlock and chrony takes over"):
        machine.succeed("systemctl reset-failed rough-time.service || true")
        machine.succeed("systemctl restart rough-time.service")
        rough = clock()
        assert rough > 1600000000, f"the rough clock was not set: {rough}"

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

    with subtest("the rough clock stands down once something has synchronised"):
        # The STA_UNSYNC no-op path, which tests/rough-time.nix cannot reach because nothing
        # there ever genuinely synchronises the clock. Without --force this must do nothing.
        output = machine.succeed("rough-time --dry-run 2>&1")
        assert "already synchronised" in output, output

    with subtest("a clock synchronised mid-exchange is not overwritten"):
        # The race the second adjtimex check exists for, staged rather than hoped for.
        #
        # The check at the top of the program cannot cover this on its own: STA_UNSYNC is
        # always set at boot, so on a warm reboot rough-time always proceeds to the full
        # exchange, while chronyd starts alongside it and -- with cached cookies and no key
        # establishment to do -- can synchronise in well under a second. Without a second
        # check the exchange then finishes and overwrites an accurate clock with a
        # whole-second approximation of it.
        #
        # clear-unsync plays the part of chrony finishing: it flips the kernel bit without
        # moving the clock, so the assertion below is about rough-time's decision and nothing
        # else.
        machine.succeed("systemctl stop chronyd.service || true")
        machine.succeed("rm -f " + MARKER)
        set_clock("2001-01-01 00:00:00")
        before = clock()

        # Widen the window deterministically rather than by shaping traffic. Every attempt to
        # slow the link failed for its own reason: at 800ms the run finished in about two
        # seconds and the flip landed after the check it exercises, at 1500ms chronyd's own
        # key-establishment timeout closed the session before answering, and a blackhole route
        # turned out not to delay anything at all -- for locally generated packets the routing
        # lookup fails immediately rather than the packet being sent and dropped, so the run
        # still finished in 200ms.
        #
        # Dropping the packets on the way out is what actually costs a timeout. Silently
        # dropping IPv4 to the resolvers while pointing their IPv6 addresses at the interceptor
        # makes each of the two DoH lookups spend the unit's full 10s connect timeout on IPv4
        # before succeeding on IPv6, so the run reliably lasts over twenty seconds with every
        # server behaving exactly as it does in the other subtests.
        nft = "${pkgs.nftables}/bin/nft"
        machine.succeed(f"{nft} add table inet slowdoh")
        machine.succeed(
            f"{nft} add chain inet slowdoh out "
            "'{ type filter hook output priority 0; policy accept; }'"
        )
        for ip in doh_ipv4:
            machine.succeed(f"{nft} add rule inet slowdoh out ip daddr {ip} tcp dport 443 drop")
        via6 = peer_ip6(dohpeer)
        for ip in doh_ipv6:
            machine.succeed(
                f"${pkgs.iproute2}/bin/ip -6 route replace {ip}/128 via {via6} dev eth1"
            )

        try:
            machine.succeed("systemctl reset-failed rough-time.service || true")

            # `systemctl start --no-block` returns before the unit has started, so reading
            # InvocationID straight afterwards yields the PREVIOUS run's -- whose journal
            # already contains "clock set to" from an earlier subtest, which made this pass its
            # wait instantly and then fail against the wrong run's output. Poll until the id
            # actually changes.
            previous = machine.succeed(
                "systemctl show -p InvocationID --value rough-time.service"
            ).strip()
            # `restart`, not `start`: the unit is RemainAfterExit and still active from an
            # earlier subtest, and `start` on an active unit is a no-op that produces no new
            # invocation at all.
            machine.succeed("systemctl restart --no-block rough-time.service")

            inv = ""
            for _ in range(120):
                inv = machine.succeed(
                    "systemctl show -p InvocationID --value rough-time.service"
                ).strip()
                if inv and inv != previous:
                    break
                machine.sleep(0.5)
            assert inv and inv != previous, "rough-time never started a new invocation"

            # Flip as early as possible: the window is however long the exchange takes, and
            # every moment spent here is a moment it might finish in.
            machine.succeed("clear-unsync")
            # The staging has to have worked, or this subtest proves nothing about rough-time.
            # A second invocation short-circuits on the check at the top of the program without
            # touching the network, so this is both cheap and a direct read of the bit.
            staged = machine.succeed("rough-time --dry-run --only cloudflare 2>&1")
            assert "already synchronised" in staged, f"clear-unsync did not take: {staged}"
            # And that it holds. The first version of this helper left maxerror at its ceiling,
            # so the kernel re-set the bit a second later and the assertion above still passed
            # while the run under test saw it set.
            machine.sleep(3)
            still = machine.succeed("rough-time --dry-run --only cloudflare 2>&1")
            assert "already synchronised" in still, f"the bit did not stay clear: {still}"
            # Waiting on the unit's ActiveState would never return: RemainAfterExit keeps a
            # successful oneshot active. Wait on what the run said instead, scoped to this
            # invocation so an earlier run cannot satisfy it -- and accept any terminal message
            # so a regression fails on the assertion below with the journal attached, rather
            # than timing out with nothing to look at.
            machine.wait_until_succeeds(
                f"journalctl _SYSTEMD_INVOCATION_ID={inv} -o cat "
                "| grep -qE 'while we were asking|clock set to|error:'",
                timeout=300,
            )
            journal = machine.succeed(f"journalctl _SYSTEMD_INVOCATION_ID={inv} -o cat")
        finally:
            machine.succeed(f"{nft} delete table inet slowdoh || true")
            connect_upstream()

        assert "while we were asking" in journal, journal
        drift = abs(clock() - before)
        assert drift < 60, f"the clock moved {drift}s despite being synchronised mid-exchange"

        # Put the host back the way the following subtests expect it.
        machine.succeed("systemctl start chronyd.service")
        resync()
        machine.wait_for_file(MARKER, timeout=300)

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
        # Re-establish a sane clock BEFORE skewing anything. rough-time now asks two NTS
        # operators and requires them to agree, so once one of them is lying it will correctly
        # refuse -- which is the behaviour under test here, not a way to set up for it.
        machine.succeed("systemctl reset-failed rough-time.service || true")
        machine.succeed("systemctl restart rough-time.service")
        rough = clock()

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
        drift = abs(clock() - rough)
        assert drift < 600, f"the clock moved {drift}s toward a disagreeing source"

        sources = machine.succeed("${pkgs.chrony}/bin/chronyc sources")
        machine.log("sources with one skewed server:\n" + sources)
  '';
}
