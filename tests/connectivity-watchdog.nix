{ nixpkgs, pkgs, stateVersion, machineModule, dohStamps }:

# The DNS-outage reboot failsafe, end to end against a REAL resolver path.
#
# The machine runs the stock dnscrypt-proxy from modules/doh.nix; a second node
# impersonates the deployed DoH upstreams (real provider addresses, real TLS, a cert
# the machine trusts) via the shared tests/doh-interceptor.nix harness. So the probe
# resolves through the actual chain -- dig -> dnscrypt-proxy -> DoH over TLS -> upstream
# -- and "the upstream stops answering" is a genuine outage rather than a mocked verdict.
#
# Two regressions this buys over a stub resolver, both of which would otherwise be
# invisible:
#
#   * CACHE. dnscrypt-proxy's cache is live here, with cache_max_ttl defaulting to 86400s.
#     If the probe ever used a fixed name instead of a fresh random label, the probes after
#     the upstream dies would be served from cache, the box would never reboot, and
#     "outage -> reboot" below would fail. The random-label requirement is enforced by this
#     test rather than merely documented in the module.
#   * The DoH EGRESS FIREWALL. modules/doh.nix rejects port 53 to anything but loopback, so
#     the probe only works at all because it dials 127.0.0.1. Live on the aarch64 variant.
#
# Everything is TIMER-driven: the driver never starts connectivity-watchdog itself, it only
# breaks and repairs the network and then reads the journal. afterSeconds/intervalSeconds are
# shortened, exactly as tests/connectivity-fallback.nix shortens bootGrace/setupTimeout and
# leaves its timer armed. `date -s` is deliberately not used -- the module's age is
# monotonic (uptime), so moving the wall clock would prove nothing -- and icount is not
# worth it either: at the warp ratio tests/connectivity-fallback-timing.nix guarantees
# (< 0.75), warping the production 86400s could cost hours of wall time.
#
# machineModule picks the system under test: the aarch64 variant is the real hosts/rpi5
# config (so dnscrypt, the DoH egress rules and the default-deny firewall are all live),
# the x86 variant a minimal doh + watchdog node.
let
  # Must exceed the worst-case boot time, and by a clear margin. On the boot AFTER a
  # watchdog reboot there is no /run marker, so `since` is the uptime itself -- if the
  # threshold were shorter than a boot, a slow (TCG) boot would already be over it and the
  # box would reboot again immediately, turning the loop-breaker subtest into a loop.
  # Measured TCG boots in this repo run 250-390s, hence 600 -- which is also the floor the
  # module asserts, for exactly this reason.
  afterSeconds = 600;
  # Every `n * interval` timeout below is derived from this, so it has to be the REAL cadence.
  # That is what accuracySeconds is for: systemd places a timer's expiry anywhere in
  # [elapse, elapse + AccuracySec], on a grid of that size, so the production 60 would floor
  # the cadence here at 60s and every bound below would be 3x looser than it reads (a later
  # "this test is slow, halve the interval" would then tighten the timeouts while changing
  # nothing about the firing rate). 1 makes the shortening real, and the module asserts the
  # interval stays a multiple of it.
  interval = 20;
  accuracySeconds = 1;

  interceptor = import ./doh-interceptor.nix {
    inherit pkgs dohStamps;
    name = "connectivity-watchdog";
    readyFile = "/tmp/fake-doh-ready";
    respond = ''
      names_log = pathlib.Path("/tmp/fake-doh-names.log")
      servfail_flag = pathlib.Path("/tmp/fake-doh-servfail")

      def servfail(query):
          # Same shape as the harness's nxdomain(), rcode 2 instead of 3. A perfectly
          # well-formed DNS *response*, which is the whole point: dig exits 0 on it.
          return query[:2] + b"\x81\x82\x00\x01\x00\x00\x00\x00\x00\x00" + _q(query)

      def respond(query, meta):
          name, qtype, qclass, _ = read_question(query)
          # Root NS first, and unlogged: dnscrypt-proxy probes this to decide the resolver
          # is alive. Without it every later query fails for a reason that has nothing to
          # do with what this test is about.
          if qtype == 2 and name == "":
              return answer_rdata(query, b"\x02ns\xc0\x0c")
          with names_log.open("a") as fh:
              fh.write(name + "\n")
          if servfail_flag.exists():
              return servfail(query)
          # Every probe name is a fresh random label, so there is nothing to match on:
          # NXDOMAIN is the right answer and counts as success (the round-trip happened).
          return nxdomain(query)
    '';
  };
  dohIpv4Json = builtins.toJSON interceptor.dohIpv4;
  dohIpv6Json = builtins.toJSON interceptor.dohIpv6;
in
nixpkgs.lib.nixos.runTest {
  name = "connectivity-watchdog";
  hostPkgs = pkgs;
  skipTypeCheck = true;

  # Impersonates every DoH provider in lib/doh-stamps.nix on its real address. Binds
  # 0.0.0.0:443, so it needs its own node.
  nodes.dohpeer = { ... }: {
    networking = {
      hostName = "dohpeer";
      firewall.enable = false;
    };
    # Helper node, tiny workload: keep the 2-node test within the 4 GB Pi.
    virtualisation.memorySize = 512;
    systemd.services.fake-doh = interceptor.mkService { };
    system.stateVersion = stateVersion;
  };

  nodes.machine = { lib, ... }: {
    imports = [ machineModule ];

    networking.hostName = "nixos-rpi5";

    # Only this CA, so dnscrypt-proxy still performs real certificate validation.
    security.pki.certificateFiles = [ interceptor.caFile ];

    # mkForce, not plain definitions: the aarch64 variant composes the real hosts/rpi5 config,
    # which pins afterSeconds and intervalSeconds at normal priority (3h and 10min), and two
    # differing normal-priority definitions of an int is an eval CONFLICT, not an override. So
    # without this the valuable variant of this test does not build at all. Forced even where
    # the host does not set it today (accuracySeconds) so that a host tuning the remaining knob
    # cannot break this test either -- the shortened values are the whole premise here, and
    # this block is the statement that they win regardless of what the composed host wants.
    # `enable` needs no force: both definitions are `true`, and equal values merge.
    common.connectivityWatchdog = {
      enable = true;
      afterSeconds = lib.mkForce afterSeconds;
      accuracySeconds = lib.mkForce accuracySeconds;
      intervalSeconds = lib.mkForce interval;
    };

    # No extra disk for the reboot breadcrumb: virtualisation.diskImage defaults to a
    # qcow2 that survives shutdown/start within a run, so /var/lib already outlives the
    # reboot here as it does on the Pi's SD card. (That same persistence is why the
    # journal reads below must be scoped with `-b`.)
    system.stateVersion = stateVersion;
  };

  testScript = ''
    import json
    import shlex

    doh_ipv4 = json.loads('${dohIpv4Json}')
    doh_ipv6 = json.loads('${dohIpv6Json}')

    AFTER = ${toString afterSeconds}
    OK = "resolved via 127.0.0.1 (NXDOMAIN)"
    BELOW = f"of {AFTER}s without DNS; nothing to do"
    PROBE_NAMES = "/tmp/fake-doh-names.log"
    SERVFAIL_FLAG = "/tmp/fake-doh-servfail"

    dohpeer.start()
    dohpeer.wait_for_unit("fake-doh.service")
    dohpeer.succeed(
        "${pkgs.coreutils}/bin/timeout 60 ${pkgs.bash}/bin/bash -c "
        "'until test -e /tmp/fake-doh-ready; do sleep 0.2; done'"
    )


    def vlan_ip(node):
        # eth1's static address comes from network-addresses-eth1.service, which on a slow
        # TCG boot can land after the units we waited for. `grep .` turns empty jq output
        # (exit 0) into a failure so a missing address cannot leak out as "".
        return node.wait_until_succeeds(
            "${pkgs.iproute2}/bin/ip -j -4 addr show dev eth1 "
            "| ${pkgs.jq}/bin/jq -r '.[0].addr_info[] | select(.prefixlen==24) | .local' "
            "| ${pkgs.gnugrep}/bin/grep .",
            timeout=120,
        ).strip()


    dohpeer_ip = vlan_ip(dohpeer)


    def connect_upstream():
        # Route the real DoH provider addresses to the interceptor, then make dnscrypt
        # pick them up. These are runtime routes, so they are gone after a reboot -- which
        # is what makes boot #2 start out with no DNS at all, exactly the state the
        # loop-breaker has to survive.
        for ip in doh_ipv4:
            machine.succeed(f"${pkgs.iproute2}/bin/ip route replace {ip}/32 via {dohpeer_ip} dev eth1")
        for ip in doh_ipv6:
            machine.succeed(f"${pkgs.iproute2}/bin/ip -6 route replace {ip}/128 dev eth1")
        machine.succeed("systemctl restart dnscrypt-proxy.service")


    # `-b` is load-bearing: this VM's journal survives the watchdog's reboot, so without it
    # every boot-#2 assertion is satisfied (or broken) by boot #1's lines -- the reboot
    # verdict in particular, which is exactly what boot #2 has to prove did NOT recur.
    JOURNAL = "journalctl -b -u connectivity-watchdog.service -o cat"


    def watchdog_journal():
        return machine.succeed(f"{JOURNAL} || true")


    def count(pattern):
        # This unit fires many times per subtest, so assertions are phrased as "the count
        # of X went up", never "X appears somewhere in the journal" -- otherwise an earlier
        # phase's line satisfies a later phase's assertion. (Cheaper and less brittle here
        # than the _SYSTEMD_INVOCATION_ID scoping tests/connectivity-fallback-trigger.nix
        # uses, which works only for a unit that runs once.)
        return int(machine.succeed(
            f"{JOURNAL} | grep -cF {shlex.quote(pattern)} || true"
        ).strip() or 0)


    def wait_for_more(pattern, base, timeout):
        machine.wait_until_succeeds(
            f"test \"$({JOURNAL} | grep -cF {shlex.quote(pattern)})\" -gt {base}",
            timeout=timeout,
        )


    def probe_names():
        raw = dohpeer.succeed(f"cat {PROBE_NAMES} 2>/dev/null || true")
        return [n for n in raw.split() if n.endswith(".example.com")]


    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("dnscrypt-proxy.service")
    machine.wait_for_unit("connectivity-watchdog.timer")
    connect_upstream()

    with subtest("upstream healthy: the timer's own probes resolve, nothing reboots"):
        # Not wait_for_unit: the watchdog is a oneshot, inactive between firings. Three
        # separate firings, so this is the timer driving it rather than one lucky run.
        wait_for_more(OK, 2, timeout=${toString (12 * interval)})
        machine.succeed("test -r /run/connectivity-watchdog/last-success")
        # No reboot was ever contemplated.
        assert count("rebooting") == 0, watchdog_journal()

    with subtest("every probe asks a fresh name, so nothing can come from cache"):
        names = probe_names()
        assert len(names) >= 3, names
        assert len(set(names)) == len(names), names

    with subtest("SERVFAIL is a failure, not a response -- and recovery works"):
        # A well-formed answer that is not a resolution. dig exits 0 on it, so this is the
        # subtest that fails if the module is ever "simplified" to trust dig's exit status.
        base = count("probe failed (status=SERVFAIL)")
        dohpeer.succeed(f"touch {SERVFAIL_FLAG}")
        wait_for_more("probe failed (status=SERVFAIL)", base, timeout=${toString (8 * interval)})
        # Short window on purpose: enough SERVFAILs and dnscrypt-proxy sidelines the
        # resolver, and the recovery below would be measuring its backoff instead.
        dohpeer.succeed(f"rm -f {SERVFAIL_FLAG}")
        base_ok = count(OK)
        wait_for_more(OK, base_ok, timeout=180)
        assert count("rebooting") == 0, watchdog_journal()

    with subtest("a dead resolver, not just a dead upstream, is a failure"):
        # The upstream stays healthy here; dnscrypt-proxy itself goes away, so 127.0.0.1:53
        # refuses the connection and dig exits 9 with no response to parse. That is the ONLY
        # path exercising the `|| true` on the dig pipeline -- without it pipefail+errexit
        # would kill the script here, the unit would merely go `failed`, and the reboot
        # would never come. "Wedged dnscrypt" is one of the failures this module exists for,
        # and stopping the upstream alone never produces it (dnscrypt stays up to SERVFAIL).
        base = count("probe failed (status=no-response)")
        machine.succeed("systemctl stop dnscrypt-proxy.service")
        wait_for_more("probe failed (status=no-response)", base, timeout=${toString (8 * interval)})
        assert count("rebooting") == 0, watchdog_journal()
        base_ok = count(OK)
        machine.succeed("systemctl start dnscrypt-proxy.service")
        wait_for_more(OK, base_ok, timeout=180)

    with subtest("a forward clock step is not an outage"):
        # The age is monotonic (uptime), never the wall clock. If it were an epoch diff, the
        # step below would instantly read as an hour without DNS -- past the 600s threshold
        # -- and the next firing would reboot a box whose only problem was that NTP fixed
        # its clock. A Pi 5 with no RTC battery does exactly that on every boot.
        #
        # +1h, not +1d: it dwarfs the threshold while staying inside the same guest day as
        # the testRtcBase 10:00 clock, so no nix-gc slot (03:15/15:15) or auto-upgrade
        # window is crossed and no test certificate leaves its validity period.
        machine.succeed("date -s '+1 hour'")
        base = count("probe failed")
        dohpeer.succeed("systemctl stop fake-doh.service")
        wait_for_more("probe failed", base, timeout=${toString (8 * interval)})
        assert count("rebooting") == 0, watchdog_journal()
        # Every reported age must still be uptime-scale, i.e. nowhere near the stepped hour.
        since = max(
            int(line.split("s of ")[0].split()[-1])
            for line in watchdog_journal().splitlines() if f"s of {AFTER}s without DNS" in line
        )
        assert since < 3600, f"since={since} looks like a wall-clock diff, not uptime"
        # Restore well before AFTER seconds of failure accumulate, so this subtest does not
        # bleed into the reboot the next ones are about.
        dohpeer.succeed("systemctl start fake-doh.service")
        dohpeer.succeed(
            "${pkgs.coreutils}/bin/timeout 60 ${pkgs.bash}/bin/bash -c "
            "'until test -e /tmp/fake-doh-ready; do sleep 0.2; done'"
        )
        base_ok = count(OK)
        wait_for_more(OK, base_ok, timeout=180)

    with subtest("upstream gone: failures accumulate but stay below the threshold"):
        base = count("probe failed")
        base_below = count(BELOW)
        dohpeer.succeed("systemctl stop fake-doh.service")
        # THE CACHE REGRESSION TEST: with a fixed probe name dnscrypt would answer these
        # from its cache (cache_max_ttl 86400) and the probe would wrongly report success,
        # so no failure would ever be logged and the reboot below would never come.
        wait_for_more("probe failed", base, timeout=${toString (8 * interval)})
        wait_for_more(BELOW, base_below, timeout=${toString (4 * interval)})
        assert count("rebooting") == 0, watchdog_journal()

    with subtest("past the threshold the timer reboots the box on its own"):
        # No systemctl start anywhere: the OnUnitActiveSec timer gets there by itself.
        # Bounded by afterSeconds (measured from the last success) + one interval.
        machine.wait_for_shutdown()

    with subtest("boot #2: the counter restarts, so one outage cannot loop reboots"):
        # The runtime routes did not survive, so DNS is still broken here -- the exact
        # state that would reboot again immediately if the age were kept across boots.
        machine.start()
        machine.wait_for_unit("multi-user.target")
        # The previous boot rebooted itself, and for this reason. Read from the PREVIOUS
        # boot's journal rather than a breadcrumb file: journald is persistent by default,
        # so this ties the reboot to the watchdog's own recorded decision -- and the module
        # deliberately writes no file, because a failed write under errexit would cancel the
        # very reboot it was documenting.
        prev = machine.succeed(
            "journalctl -b -1 -u connectivity-watchdog.service -o cat || true"
        )
        assert "; rebooting" in prev, prev
        recorded = int(prev.split("no DNS for ")[1].split("s;")[0])
        assert recorded >= AFTER, recorded

        wait_for_more(BELOW, 0, timeout=${toString (8 * interval)})
        journal = watchdog_journal()
        assert count("rebooting") == 0, journal
        # The age restarted from this boot rather than carrying over: it must be bounded by
        # uptime, and well under the threshold that was just crossed.
        since = max(
            int(line.split("s of ")[0].split()[-1])
            for line in journal.splitlines() if f"s of {AFTER}s without DNS" in line
        )
        uptime = int(float(machine.succeed("cut -d' ' -f1 /proc/uptime")))
        assert since <= uptime, f"since={since} uptime={uptime}"
        assert since < AFTER, f"since={since} already at threshold {AFTER}"

    with subtest("connectivity returning ends the cycle"):
        dohpeer.succeed("systemctl start fake-doh.service")
        dohpeer.succeed(
            "${pkgs.coreutils}/bin/timeout 60 ${pkgs.bash}/bin/bash -c "
            "'until test -e /tmp/fake-doh-ready; do sleep 0.2; done'"
        )
        base_ok = count(OK)
        connect_upstream()
        wait_for_more(OK, base_ok, timeout=180)
        machine.succeed("test -r /run/connectivity-watchdog/last-success")
  '';
}
