{ nixpkgs, pkgs, stateVersion, machineModule, dohStamps, globalTimeout ? 1200 }:

# The whole time chain, on the real host config: rough clock -> DNS -> chrony over NTS.
#
# tests/rough-time.nix covers the rough clock against a controlled HTTP server. This covers
# what happens after it, and it is the only place the bootstrap deadlock is actually
# reproduced rather than described:
#
#   the machine boots with its clock years out, so DoH's TLS cannot validate and no name
#   resolves; rough-time reaches the DoH providers by pinned address and sets a rough clock;
#   DNS starts working; chronyd resolves the NTS hostnames and synchronises over NTS-KE.
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
      timeoutSeconds = 3;
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

    def resync():
        # Drop everything chrony knows and make it start over, so a subtest cannot pass on a
        # measurement taken before it changed anything.
        machine.succeed("rm -f " + MARKER)
        machine.succeed("systemctl stop chrony-wait.service || true")
        machine.succeed("systemctl reset-failed chrony-wait.service || true")
        machine.succeed("systemctl restart chronyd.service")
        machine.succeed("systemctl start --no-block chrony-wait.service")

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

    with subtest("the rough clock stands down once something has synchronised"):
        # The STA_UNSYNC no-op path, which tests/rough-time.nix cannot reach because nothing
        # there ever genuinely synchronises the clock. Without --force this must do nothing.
        output = machine.succeed("rough-time --dry-run 2>&1")
        assert "already synchronised" in output, output

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
        # Cut its upstream first, or chronyd simply steps the clock back to ntsgood's.
        ntsliar.succeed(
            f"${pkgs.iproute2}/bin/ip route replace unreachable {peer_ip(ntsgood)}"
        )
        ntsliar.succeed("date -s '+3 hours'")
        machine.succeed("systemctl restart rough-time.service")
        rough = clock()
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
