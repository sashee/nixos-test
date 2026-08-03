{ nixpkgs, pkgs, stateVersion, machineModule, dohStamps, globalTimeout ? 1200 }:

# The boot-time rough clock, end to end over both of its TLS legs.
#
# The machine runs the deployed configuration and is told nothing: it resolves the real NTS
# hostnames through the real DoH provider addresses, does real NTS key establishment, and gets a
# real authenticated NTPv4 timestamp. What the test owns is the other end -- impersonated DoH
# resolvers and impersonated NTS servers, each with a certificate the machine trusts.
#
# The subject is the deferred certificate check. Both legs hand their chain to `Deferred`, and
# the time is believed only once every chain re-verifies at the instant the NTS server reported.
# That is tested on each leg separately, by giving one impersonated server a certificate whose
# validity window excludes the present *while leaving its clock correct* -- possible only
# because tests/test-cert.nix takes notBefore/notAfter. Making a server lie about the time
# instead would put it outside its own certificate and it would fail for the wrong reason.
#
# Those same windows are what decides whether the clock gets set at all, so the driver moves the
# machine's clock in and out of them deliberately. The fixtures are 100-year certificates issued
# at build time and these nodes boot at tomorrow 10:00 (lib/test-rtc-base.nix), i.e. already
# inside -- so any subtest that means to watch the clock being SET has to put it outside first,
# or it passes while rough-time does nothing.
#
# Why so much of this drives the CLI wrapper rather than the unit: the unit samples operators at
# random, and a test that must hold a specific pair cannot be built on a random draw. `--only`
# pins the choice while every other flag stays exactly what the unit uses. The unit itself is
# driven where the integration is the point -- that it retries until the network appears, and
# that it converges unattended.
#
# Not covered here: operators disagreeing, one operator failing to outvote itself, and the
# tolerance boundary. Those are decisions taken by `quorum::decide`, which is pure and has
# fixtures for each; reproducing them with real servers would need a third and fourth NTS node
# for no additional confidence.

let
  lib = nixpkgs.lib;

  floor = 1000000000;

  goodHost = "time.cloudflare.com";
  staleHost = "nts.netnod.se";

  # Valid now, so the NTS leg's pass 2 succeeds -- and DELIBERATELY not the same window as the
  # good DoH certificate below. The stand-down rule is defined over the validity of *every*
  # certificate gathered on the way to an answer, so the two legs are given windows that differ
  # at both ends and the intersection is strictly narrower than either:
  #
  #   DoH   2020-01-01 .................................... 2060-01-01
  #   NTS         2024-01-01 ................................... 2100-01-01
  #   both        2024-01-01 ............................. 2060-01-01
  #
  # With one shared 100-year window (which is what these fixtures used to have) a client that
  # consulted only one leg, or that answered "every instant" when it could not tell, would pass
  # every subtest here. The dates are absolute rather than relative to the build so the fixture
  # is reproducible, and far enough out that the window still contains the present for decades.
  ntsNotBefore = "20240101000000Z";
  ntsNotAfter = "21000101000000Z";
  dohNotBefore = "20200101000000Z";
  dohNotAfter = "20600101000000Z";
  # The intersection, as epoch seconds, for the driver to assert against.
  bothFrom = 1704067200; # 2024-01-01
  bothUntil = 2840140800; # 2060-01-01

  ntsCert = import ./test-cert.nix { inherit pkgs; } {
    name = "nts-good";
    sans = [ goodHost ];
    notBefore = ntsNotBefore;
    notAfter = ntsNotAfter;
  };

  # Well formed, chains to a CA the machine trusts, matches the hostname -- and expired in 2021.
  # Pass 1 accepts it, which is the whole point of deferring the date check; pass 2 must not.
  staleCert = import ./test-cert.nix { inherit pkgs; } {
    name = "nts-stale";
    sans = [ staleHost ];
    notBefore = "20200101000000Z";
    notAfter = "20210101000000Z";
  };

  mkNtsServer = cert: { ... }: {
    virtualisation.memorySize = 512;
    networking.firewall.enable = false;
    services.chrony = {
      enable = true;
      servers = [ ];
      extraConfig = ''
        local stratum 10
        allow all
        ntsserverkey ${cert.keyFile}
        ntsservercert ${cert.certFile}
        ntsprocesses 0
      '';
    };
    system.stateVersion = stateVersion;
  };

  # Answers the two NTS hostnames with the addresses passed as argv. Two instances of this exist
  # on the network, differing only in certificate validity; the driver routes the provider
  # addresses to whichever one a subtest needs.
  # Both families, because rough-time asks for both: querying A alone would resolve an
  # IPv6-only host to an address it has no way to reach.
  respond = ''
    def respond(query, meta):
        name, qtype, _, _ = read_question(query)
        v4 = {"${goodHost}": ARGS[0], "${staleHost}": ARGS[1]}
        v6 = {"${goodHost}": ARGS[2], "${staleHost}": ARGS[3]}
        if name not in v4:
            return nxdomain(query)
        if qtype == 1:
            return a(query, v4[name])
        if qtype == 28:
            return aaaa(query, v6[name])
        return nodata(query)
  '';

  dohGood = import ./doh-interceptor.nix {
    inherit pkgs dohStamps respond;
    name = "rough-time-doh";
    readyFile = "/tmp/fake-doh-ready";
    certNotBefore = dohNotBefore;
    certNotAfter = dohNotAfter;
  };

  dohStale = import ./doh-interceptor.nix {
    inherit pkgs dohStamps respond;
    name = "rough-time-doh-stale";
    readyFile = "/tmp/fake-doh-ready";
    certNotBefore = "20200101000000Z";
    certNotAfter = "20210101000000Z";
  };
in

nixpkgs.lib.nixos.runTest {
  name = "rough-time";
  hostPkgs = pkgs;
  skipTypeCheck = true;
  inherit globalTimeout;

  nodes.dohgood = { nodes, ... }: {
    networking = {
      hostName = "dohgood";
      firewall.enable = false;
    };
    virtualisation.memorySize = 512;
    systemd.services.fake-doh = dohGood.mkService {
      args = [
        nodes.ntsgood.networking.primaryIPAddress
        nodes.ntsstale.networking.primaryIPAddress
        nodes.ntsgood.networking.primaryIPv6Address
        nodes.ntsstale.networking.primaryIPv6Address
      ];
    };
    system.stateVersion = stateVersion;
  };

  nodes.dohstale = { nodes, ... }: {
    networking = {
      hostName = "dohstale";
      firewall.enable = false;
    };
    virtualisation.memorySize = 512;
    systemd.services.fake-doh = dohStale.mkService {
      args = [
        nodes.ntsgood.networking.primaryIPAddress
        nodes.ntsstale.networking.primaryIPAddress
        nodes.ntsgood.networking.primaryIPv6Address
        nodes.ntsstale.networking.primaryIPv6Address
      ];
    };
    system.stateVersion = stateVersion;
  };

  nodes.ntsgood = { ... }: {
    imports = [ (mkNtsServer ntsCert) ];
    networking.hostName = "ntsgood";
  };

  nodes.ntsstale = { ... }: {
    imports = [ (mkNtsServer staleCert) ];
    networking.hostName = "ntsstale";
  };

  nodes.machine = { lib, ... }: {
    imports = [ machineModule ];

    networking.hostName = "rough-time-test";

    common.autoUpgrade.enable = lib.mkForce false;
    common.monitoring.enable = lib.mkForce false;
    common.irohSsh.enable = lib.mkForce false;

    # mkForce: the shared test-node layer switches time sync off on every node (see
    # testNodeTimeSyncOff in flake.nix), which here is the thing under test.
    common.timeSync = {
      enable = lib.mkForce true;
      # Only the two hosts this test impersonates, so no unreachable name adds delay.
      servers = lib.mkForce [ goodHost staleHost ];
      # mkForce because the host layer supplies the real floor (nixpkgs.lastModified). A 2026
      # floor would reject the deliberately-stale fixtures for the wrong reason.
      floor = lib.mkForce floor;
      # Only one operator can ever succeed here (the other's certificate is expired), so the
      # deployed sample of two could never converge. The quorum arithmetic itself is covered by
      # fixtures in quorum.rs; what this test is for is the two TLS legs.
      sample = lib.mkForce 1;
      timeoutSeconds = 3;
      # No unwedge unit here. This test has no chrony that can ever synchronise -- the NTS nodes
      # are the subject, not sources this machine polls -- so the unit would wait out its window
      # and reboot the machine in the middle of the run. The unit is covered in
      # tests/nts-sync.nix, which has a real chrony to satisfy or to wedge on purpose.
      unwedgeSeconds = null;
    };

    # All four CAs. Verification is still real -- pass 1 must build a chain to a trusted root on
    # both legs -- so an impersonated server without a trusted CA would fail before any of this
    # became interesting.
    security.pki.certificateFiles = [
      dohGood.caFile
      dohStale.caFile
      ntsCert.caFile
      staleCert.caFile
    ];

    system.stateVersion = stateVersion;
  };

  testScript = ''
    doh_ipv4 = ${builtins.toJSON dohGood.dohIpv4}
    doh_ipv6 = ${builtins.toJSON dohGood.dohIpv6}
    FLOOR = ${toString floor}
    # The instants at which BOTH good certificates are valid; see the fixtures above.
    BOTH_FROM = ${toString bothFrom}
    BOTH_UNTIL = ${toString bothUntil}

    start_all()

    for peer in (dohgood, dohstale):
        peer.wait_for_unit("fake-doh.service")
        peer.succeed(
            "${pkgs.coreutils}/bin/timeout 60 ${pkgs.bash}/bin/bash -c "
            "'until test -e /tmp/fake-doh-ready; do sleep 0.2; done'"
        )
    ntsgood.wait_for_unit("chronyd.service")
    ntsstale.wait_for_unit("chronyd.service")
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

    def use_resolver(node):
        # Runtime routes, so the machine's own configuration is untouched: it dials the
        # providers' real addresses and reaches whichever interceptor the test points them at.
        #
        # The IPv6 routes need an explicit gateway rather than being on-link. Both interceptor
        # nodes hold the same provider /128s on the same segment, so an on-link route would let
        # neighbour discovery pick either one -- and which resolver answers is exactly what
        # these subtests are choosing between.
        via4 = peer_ip(node)
        via6 = peer_ip6(node)
        for ip in doh_ipv4:
            machine.succeed(f"${pkgs.iproute2}/bin/ip route replace {ip}/32 via {via4} dev eth1")
        for ip in doh_ipv6:
            machine.succeed(f"${pkgs.iproute2}/bin/ip -6 route replace {ip}/128 via {via6} dev eth1")


    def disconnect(v4=True, v6=True):
        # `unreachable` rather than deleting: it fails at once instead of costing the timeout.
        if v4:
            for ip in doh_ipv4:
                machine.succeed(f"${pkgs.iproute2}/bin/ip route replace unreachable {ip}/32")
        if v6:
            for ip in doh_ipv6:
                machine.succeed(f"${pkgs.iproute2}/bin/ip -6 route replace unreachable {ip}/128")

    def clock():
        return int(machine.succeed("date +%s").strip())

    def rough_time(args, expect_success):
        # --force because the machine's clock is often already fine here; the STA_UNSYNC no-op
        # path is covered in tests/nts-sync.nix, which has a real chrony to clear the bit.
        command = f"rough-time --force --dry-run {args} 2>&1"
        return machine.succeed(command) if expect_success else machine.fail(command)

    with subtest("a host that cannot reach any resolver keeps trying and changes nothing"):
        before = clock()
        machine.wait_until_succeeds(
            "systemctl show -p NRestarts --value rough-time.service | grep -qvx 0", timeout=240
        )
        assert (
            "start-limit" not in machine.succeed("systemctl status rough-time.service || true")
        ), "the restart rate limit stopped the retries"
        assert abs(clock() - before) < 120, "the clock moved with nothing reachable"
        # Ordering, not requiring: a box with no time still boots.
        machine.succeed("systemctl is-active multi-user.target")

    # Outside the good certificates' validity, which is what makes the next subtest test
    # anything. The fixtures are 100-year certificates (tests/test-cert.nix) issued at build
    # time, so the tomorrow-10:00 clock these nodes boot with sits comfortably INSIDE them -- and
    # rough-time now stands down when the clock is already inside, because TLS works there and
    # there is nothing left for it to fix. 2001 is before every fixture's notBefore, so the unit
    # has to do the whole job.
    machine.succeed("date -s '2001-01-01 00:00:00'")

    use_resolver(dohgood)

    with subtest("the clock is set once the whole chain is reachable"):
        # Unattended: the driver only repairs the network, so this asserts the retry loop gets
        # through DoH resolution, NTS key establishment and an authenticated NTP exchange on its
        # own -- which is also the only place the exporter-derived AEAD keys are exercised
        # against a real server rather than a fixture.
        machine.wait_for_unit("rough-time.service", timeout=420)
        served = int(ntsgood.succeed("date +%s").strip())
        drift = abs(clock() - served)
        assert drift < 120, f"clock is {drift}s from what the NTS server serves"

    with subtest("an NTS server outside its certificate's validity is refused"):
        # The heart of it. ntsstale's certificate chains to a trusted CA, matches the hostname
        # and is accepted by pass 1 -- and expired in 2021, while the server's own clock is
        # correct. Only pass 2 can catch this.
        output = rough_time("--only netnod", expect_success=False)
        assert "not valid at the time the server reported" in output, output
        assert "NTS-KE" in output, f"the failing leg should be named: {output}"

    with subtest("a DoH resolver outside its certificate's validity is refused"):
        # The other leg, and it must fail even though the NTS server is beyond reproach: the
        # resolver that produced the address is part of what vouches for the answer, so its
        # certificate has to hold at the same instant.
        use_resolver(dohstale)
        output = rough_time("--only cloudflare", expect_success=False)
        assert "not valid at the time the server reported" in output, output
        assert "DoH" in output, f"the failing leg should be named: {output}"
        use_resolver(dohgood)

    with subtest("a time below the floor is refused"):
        # Distinct from the two above: every chain is valid at this instant, and only the floor
        # rejects it. That is what bounds a rollback by a once-valid certificate.
        output = rough_time(f"--only cloudflare --floor {2 ** 40}", expect_success=False)
        assert "earlier than the build-time floor" in output, output

    def stand_down_or_set(when):
        # Not --force and not --dry-run: the decision AND its effect are the subject. The kernel
        # reports STA_UNSYNC throughout this test (nothing here ever synchronises the clock), so
        # the adjtimex check can never be what decides these -- only the certificate window can.
        machine.succeed(f"date -s '{when}'")
        return machine.succeed("rough-time --only cloudflare 2>&1")

    with subtest("a clock already inside the certificates' validity is left alone"):
        # 2030 is wrong by years and inside both fixtures' validity, which is exactly the state
        # the rule is about: TLS works, so chrony can reach its sources and make the accurate
        # correction itself, and stepping here would only replace one wrong time with a
        # whole-second approximation of a different one.
        output = stand_down_or_set("2030-01-01 00:00:00")
        assert "already inside the certificates' validity" in output, output
        # The reported window is the INTERSECTION of the two legs, asserted exactly. Without this
        # the subtest would pass just as well on a client that answered "every instant is inside"
        # whenever it could not work a window out -- which is the one wrong answer here, and the
        # reason `common_window` treats a single unknown as poisoning the whole result.
        assert f"({BOTH_FROM}..{BOTH_UNTIL})" in output, output
        # Still in 2030, i.e. not stepped back to what the NTS server serves.
        assert 1893456000 <= clock() < 1900000000, f"the clock moved to {clock()}"

    with subtest("a clock outside the certificates' validity is set"):
        # The converse, so the subtest above cannot pass by rough-time having simply stopped
        # setting clocks. Same command, same flags, only the starting clock differs.
        assert "clock set to" in stand_down_or_set("2001-01-01 00:00:00")
        served = int(ntsgood.succeed("date +%s").strip())
        drift = abs(clock() - served)
        assert drift < 120, f"clock is {drift}s from what the NTS server serves"

    with subtest("one leg's window is not enough to stand down on"):
        # 2022 is inside the DoH certificate's validity and outside the NTS one; 2070 is inside
        # the NTS certificate's and outside the DoH one. Either way the clock is outside the
        # instants where BOTH hold, so TLS does not actually work there and the clock must be
        # set. A client that consulted one leg and not the other would stand down on exactly one
        # of these two -- which is why both directions are here rather than one.
        for when in ["2022-06-01 00:00:00", "2070-06-01 00:00:00"]:
            output = stand_down_or_set(when)
            assert "clock set to" in output, f"{when} should have been stepped: {output}"
        served = int(ntsgood.succeed("date +%s").strip())
        assert abs(clock() - served) < 120, "the clock did not end up on the served time"

    with subtest("--force overrides the certificate window, not just adjtimex"):
        # The documented way to check the configured servers still answer on a host whose clock
        # is fine (`rough-time --force --dry-run`). If --force skipped only the adjtimex check,
        # this would report a stand-down on any host whose clock is inside validity -- i.e. every
        # healthy host -- and the escape hatch would be useless precisely where it is used.
        machine.succeed("date -s '2030-01-01 00:00:00'")
        output = machine.succeed("rough-time --force --dry-run --only cloudflare 2>&1")
        assert "would set the clock to" in output, output
        machine.succeed(f"date -s @{int(ntsgood.succeed('date +%s').strip())}")

    with subtest("a v4-only host still gets a clock"):
        disconnect(v4=False, v6=True)
        rough_time("--only cloudflare", expect_success=True)
        use_resolver(dohgood)

    with subtest("a v6-only host still gets a clock"):
        # Not redundant with the above: the two families are separate addresses, sockets and
        # routes all the way down, and this repo already treats an asymmetry between them as
        # serious enough to run a dedicated v6-only client in tests/doh-upstream.nix.
        #
        # Retried rather than attempted once. Installing a route is not the same as being able
        # to use it -- neighbour discovery for the gateway still has to complete, and under TCG
        # that took long enough for this to fail about one run in three, while the IPv4 path
        # the preceding subtests had already warmed kept working. There is no cheap independent
        # probe to wait on either: the interceptor answers TLS on 443 and nothing else, not
        # even ICMPv6. So retry the operation itself.
        disconnect(v4=True, v6=False)
        machine.wait_until_succeeds(
            "rough-time --force --dry-run --only cloudflare", timeout=120
        )
        use_resolver(dohgood)

    with subtest("an NTS server reachable only over IPv6 still gives the time"):
        # The v4-only/v6-only pair above covers the DoH leg -- reaching the resolver. This
        # covers the other one: the resolver is reachable, but the NTS server it names is not
        # reachable over IPv4. Querying A alone (as this program once did) resolves to an
        # address the host cannot use and the whole chain fails.
        ntsgood_v4 = ntsgood.succeed(
            "${pkgs.iproute2}/bin/ip -j -4 addr show dev eth1 "
            "| ${pkgs.jq}/bin/jq -r '.[0].addr_info[] | select(.prefixlen==24) | .local'"
        ).strip()
        machine.succeed(f"${pkgs.iproute2}/bin/ip route replace unreachable {ntsgood_v4}/32")
        # Retried for the same reason as the subtest above: this is the first traffic to the
        # NTS server over IPv6, so its neighbour entry is cold.
        machine.wait_until_succeeds(
            "rough-time --force --dry-run --only cloudflare", timeout=120
        )
        machine.succeed(f"${pkgs.iproute2}/bin/ip route del unreachable {ntsgood_v4}/32")

    with subtest("the unit keeps exactly the privilege it needs"):
        def unit_property(name):
            return machine.succeed(
                f"systemctl show -p {name} --value rough-time.service"
            ).strip()

        bounding = unit_property("CapabilityBoundingSet")
        assert bounding == "cap_sys_time", f"bounding set is {bounding!r}"
        assert unit_property("AmbientCapabilities") == "cap_sys_time"
        # Deliberately off -- the unit exists to change the clock -- so pin it rather than leave
        # it looking like an oversight someone should tidy up.
        assert unit_property("ProtectClock") == "no"
        for name in [
            "NoNewPrivileges",
            "RestrictSUIDSGID",
            "MemoryDenyWriteExecute",
            "ProtectKernelModules",
            "ProtectKernelTunables",
            "LockPersonality",
        ]:
            assert unit_property(name) == "yes", f"{name} is not enabled"
        families = unit_property("RestrictAddressFamilies")
        assert set(families.split()) == {"AF_INET", "AF_INET6"}, families

    with subtest("the unit converges unattended after a large step"):
        machine.succeed("date -s '2001-01-01 00:00:00'")
        machine.succeed("systemctl reset-failed rough-time.service || true")
        machine.succeed("systemctl restart rough-time.service || true")
        # Wait on the clock, not the unit: `systemctl show -p Result` reports the last FINISHED
        # run and `reset-failed` resets it to "success", so polling it races the retry loop.
        machine.wait_until_succeeds(f"test $(date +%s) -gt {FLOOR}", timeout=600)

    with subtest("nothing was left broken"):
        failed = machine.succeed("systemctl list-units --state=failed --no-legend || true").strip()
        remaining = [
            line for line in failed.splitlines() if "chrony-wait" not in line and line.strip()
        ]
        assert not remaining, "units failed after the clock step:\n" + "\n".join(remaining)
  '';
}
