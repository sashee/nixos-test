{ nixpkgs, pkgs, stateVersion, machineModule, dohStamps, globalTimeout ? 1200 }:

# The time-correction service, end to end over both of its TLS legs.
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
# or it passes while time-correction does nothing.
#
# Both interceptors also SEND a certificate that no path through them uses (padSuperseded and
# padExpired below), because "the certificates the answer was verified with" and "the certificates
# the peer sent" are different sets and only the first may decide anything -- the rule
# spec/features/system/time-correction-details.md states. That is not one subtest: every DoH
# handshake in this run carries one, so a client that went back to judging dates by what arrived
# would fail here broadly rather than in one place.
#
# Why so much of this drives the CLI wrapper rather than the unit: the unit samples operators at
# random, and a test that must hold a specific pair cannot be built on a random draw. `--only`
# pins the choice while every other flag stays exactly what the unit uses. The unit itself is
# driven where the integration is the point -- that a boot with no reachable resolver fails
# visibly and leaves the timer armed, and that a run recovers a clock decades out.
#
# Not covered here: operators disagreeing, one operator failing to outvote itself, and the
# tolerance boundary. Those are decisions taken by `quorum::decide`, which is pure and has
# fixtures for each, and reproducing them here would need this node to draw two operators at
# once -- which `sample = 1` rules out, since one of its NTS fixtures is deliberately expired.
# tests/nts-sync.nix runs at the deployed `sample = 2` against two valid servers and skews one
# of them, so the disagreement path is covered end to end there instead.

let
  floor = 1000000000;

  goodHost = "time.cloudflare.com";
  staleHost = "nts.netnod.se";

  # The redirect pair. An NTS server may answer key establishment itself and hand timestamping
  # to a DIFFERENT host, using records marked CRITICAL -- lib/nts-servers.nix records that
  # nts.netnod.se does exactly this in production, pointing at 194.58.207.80:4123. Nothing in
  # this suite reproduced it, so `main::ask_pair`'s redirect branch -- a SECOND DoH lookup, the
  # address-family match against the address key establishment worked over, and a THIRD
  # certificate chain recorded into `Deferred` -- never ran anywhere.
  #
  # Two names for one node: key establishment happens on `redirectKeHost` (which is what its
  # certificate is issued for) and the redirect names `redirectNtpHost`, which resolves back to
  # the same chronyd. One daemon, so the cookies it issued are the cookies it accepts and no
  # NTS key sharing is needed; two names, so following the redirect is observable rather than
  # indistinguishable from ignoring it.
  redirectKeHost = "ptbtime1.ptb.de";
  redirectNtpHost = "ptbtime2.ptb.de";

  # Valid now, so the NTS leg's pass 2 succeeds -- and DELIBERATELY not the same window as the
  # good DoH certificate below. The stand-down rule is defined over the validity of *every*
  # certificate gathered on the way to an answer, so the two legs are given windows that differ
  # at both ends and the intersection is strictly narrower than either:
  #
  #   DoH   2020-01-01 .................................... 2060-01-01
  #   NTS         2024-01-01 ................................... 2100-01-01
  #   both        2024-01-01 ............................. 2060-01-01
  #
  # One shared 100-year window would not do: a client that consulted only one leg, or that
  # answered "every instant" when it could not tell, would pass every subtest here. The dates are
  # absolute rather than relative to the build so the fixture is reproducible, and far enough out
  # that the window still contains the present for decades.
  ntsNotBefore = "20240101000000Z";
  ntsNotAfter = "21000101000000Z";
  dohNotBefore = "20200101000000Z";
  dohNotAfter = "20600101000000Z";
  # The intersection, as epoch seconds, for the driver to assert against.
  bothFrom = 1704067200; # 2024-01-01
  bothUntil = 2840140800; # 2060-01-01

  # The stand-down subtest's clock: comfortably inside the intersection above and wrong by years,
  # given both ways because that subtest sets the first and asserts the second.
  in2030 = "2030-01-01 00:00:00";
  in2030Epoch = 1893456000;

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

  # Issued for the KEY ESTABLISHMENT name only. The redirect target is reached over plain NTPv4
  # with no TLS at all -- the AEAD keys exported from this handshake are what authenticate it --
  # so a certificate naming it would be describing a handshake that never happens. Same window
  # as ntsCert, since this fixture is about the redirect and not about validity.
  redirectCert = import ./test-cert.nix { inherit pkgs; } {
    name = "nts-redirect";
    sans = [ redirectKeHost ];
    notBefore = ntsNotBefore;
    notAfter = ntsNotAfter;
  };

  # `extra` is appended to chrony.conf, which is how the redirect node advertises a different
  # timestamping host (`ntsntpserver`). Every other node passes nothing and is unchanged.
  mkNtsServer = { cert, extra ? "" }: { ... }: {
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
        ${extra}
      '';
    };
    system.stateVersion = stateVersion;
  };

  # Answers the two NTS hostnames with the addresses passed as argv. Two instances of this exist
  # on the network, differing only in certificate validity; the driver routes the provider
  # addresses to whichever one a subtest needs.
  # Both families, because time-correction asks for both: querying A alone would resolve an
  # IPv6-only host to an address it has no way to reach.
  # The redirect's key-establishment name and its timestamping name both resolve to the same
  # node, which is what lets one chronyd play both halves.
  respond = ''
    def respond(query, meta):
        name, qtype, _, _ = read_question(query)
        # Every question, appended before it is answered. This is the evidence that the
        # redirect was FOLLOWED: ${redirectNtpHost} is named by nothing this host is
        # configured with, so the only way it can be asked for is a client that read the
        # redirect out of the NTS-KE response and went to resolve it. Without this the
        # redirect subtest would pass just as well on a client that ignored the record and
        # kept talking to the key-establishment host, which answers correctly either way.
        with open("/tmp/queried-names", "a") as log:
            log.write(name + "\n")
        v4 = {
            "${goodHost}": ARGS[0],
            "${staleHost}": ARGS[1],
            "${redirectKeHost}": ARGS[4],
            "${redirectNtpHost}": ARGS[4],
        }
        v6 = {
            "${goodHost}": ARGS[2],
            "${staleHost}": ARGS[3],
            "${redirectKeHost}": ARGS[5],
            "${redirectNtpHost}": ARGS[5],
        }
        if name not in v4:
            return nxdomain(query)
        if qtype == 1:
            return a(query, v4[name])
        if qtype == 28:
            return aaaa(query, v6[name])
        return nodata(query)
  '';

  # Certificates the interceptors SEND and that no path through them uses -- the shape a provider
  # leaves behind when a superseded cross-sign stays in its chain file, and which
  # spec/features/system/time-correction-details.md names as the footgun. Each has its own CA,
  # trusted by nobody, so neither can ever be part of a path: they exist purely to be sent.
  #
  # Both windows exclude the present, which is what makes them discriminating, and the two shapes
  # are deliberately different because they break a client in two different ways:
  #
  #   padSuperseded, which OVERLAPS the leaf it rides with (2020-2060 & 2020-2022). A client that
  #     intersected what was sent would report a window ending in 2022, find the present outside it,
  #     and step a clock that is already correct -- hourly, on every host, with nothing local to
  #     blame. It goes on dohgood, so every DoH handshake in this run carries one.
  #   padExpired, which is DISJOINT from its leaf (2020-2021 & 2010-2011). The intersection of what
  #     was sent is then empty, and a client that needed a non-empty one to pick a pass-1 instant
  #     refuses the handshake outright -- failing the run, and with it any chance of recovering a
  #     host whose clock is wrong. It goes on dohstale, whose subtest asserts the failure it is
  #     supposed to have (an expired LEAF, caught by pass 2) and would report the wrong one.
  padSuperseded = import ./test-cert.nix { inherit pkgs; } {
    name = "pad-superseded";
    sans = [ "superseded.invalid" ];
    notBefore = "20200101000000Z";
    notAfter = "20220101000000Z";
  };

  padExpired = import ./test-cert.nix { inherit pkgs; } {
    name = "pad-expired";
    sans = [ "expired.invalid" ];
    notBefore = "20100101000000Z";
    notAfter = "20110101000000Z";
  };

  # How many certificates a TLS peer actually SENDS, which is the only thing that makes the
  # off-path fixtures above more than decoration: if a server quietly dropped the extra
  # certificate, the subtest that depends on it would pass while testing nothing at all.
  #
  # `get_unverified_chain` rather than parsing `openssl s_client -showcerts`, whose output prints
  # the leaf twice -- once in the chain listing and once under "Server certificate" -- so counting
  # PEM blocks there answers 3 for a chain of 2. This asks the TLS stack what arrived. Unverified
  # deliberately: the question is what was sent, so the answer must not depend on the trust store.
  #
  # Retried, because a single connect is a coin flip on the KVM-less aarch64 runner: this test
  # boots six TCG VMs on four cores, and dnscrypt-proxy's periodic re-probe opens a fresh TLS
  # connection to every one of its eight upstream entries -- all of which route to the one
  # interceptor node, whose accept loop does the handshakes itself (the harness wraps the LISTENING
  # socket). A probe landing in that burst waited out its whole 10s connect timeout on CI while the
  # same subtest took 1.5s on x86_64.
  #
  # Retrying cannot mask a wrong answer: only OSError is caught -- the transport never made it far
  # enough to report a chain -- and the caller still pins the count exactly. So the loop can turn a
  # connect failure into an answer, never one answer into another.
  peerChainCount = pkgs.writeShellScript "peer-chain-count" ''
    exec ${pkgs.python3}/bin/python3 -c '
    import socket, ssl, sys, time
    context = ssl._create_unverified_context()
    deadline = time.monotonic() + 120
    while True:
        try:
            with context.wrap_socket(
                socket.create_connection((sys.argv[1], 443), timeout=30),
                server_hostname=sys.argv[2],
            ) as tls:
                print(len(tls.get_unverified_chain()))
                break
        except OSError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(1)
    ' "$@"
  '';

  dohGood = import ./doh-interceptor.nix {
    inherit pkgs dohStamps respond;
    name = "time-correction-doh";
    readyFile = "/tmp/fake-doh-ready";
    certNotBefore = dohNotBefore;
    certNotAfter = dohNotAfter;
    certChainWith = [ padSuperseded.certFile ];
  };

  dohStale = import ./doh-interceptor.nix {
    inherit pkgs dohStamps respond;
    name = "time-correction-doh-stale";
    readyFile = "/tmp/fake-doh-ready";
    certNotBefore = "20200101000000Z";
    certNotAfter = "20210101000000Z";
    certChainWith = [ padExpired.certFile ];
  };
in

nixpkgs.lib.nixos.runTest {
  name = "time-correction";
  hostPkgs = pkgs;
  skipTypeCheck = true;
  inherit globalTimeout;

  # Six nodes brought up together, which is the shape that made this necessary; see the file.
  defaults = import ./slow-tcg-node.nix;

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
        nodes.ntsredirect.networking.primaryIPAddress
        nodes.ntsredirect.networking.primaryIPv6Address
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
        nodes.ntsredirect.networking.primaryIPAddress
        nodes.ntsredirect.networking.primaryIPv6Address
      ];
    };
    system.stateVersion = stateVersion;
  };

  nodes.ntsgood = { ... }: {
    imports = [ (mkNtsServer { cert = ntsCert; }) ];
    networking.hostName = "ntsgood";
  };

  nodes.ntsstale = { ... }: {
    imports = [ (mkNtsServer { cert = staleCert; }) ];
    networking.hostName = "ntsstale";
  };

  # A separate node rather than a redirect bolted onto ntsgood, deliberately: ntsgood is the
  # server every other subtest here talks to, and putting a redirect in its path would mean a
  # break in the redirect code failed a dozen unrelated assertions at once instead of the one
  # that is about it.
  nodes.ntsredirect = { ... }: {
    imports = [
      (mkNtsServer {
        cert = redirectCert;
        # Points at its own other name. chronyd puts this in the NTS-KE response as an
        # NTPv4 Server Negotiation record marked CRITICAL, which is the record a client that
        # does not understand it is required to abort on.
        extra = "ntsntpserver ${redirectNtpHost}";
      })
    ];
    networking.hostName = "ntsredirect";
  };

  nodes.machine = { lib, ... }: {
    imports = [ machineModule ];

    networking.hostName = "time-correction-test";

    common.autoUpgrade.enable = lib.mkForce false;
    common.monitoring.enable = lib.mkForce false;
    common.irohSsh.enable = lib.mkForce false;

    # This test moves the clock by decades, and nix-gc.timer is Persistent -- so a forward jump
    # past a missed OnCalendar fires it immediately, putting a store-wide delete underneath the
    # timing-sensitive subtests below (observed mid-run on the aarch64 runner). Same reasoning
    # and same remedy as tests/restic.nix, which advances the clock for its own purposes.
    nix.gc.automatic = lib.mkForce false;

    # fstrim.timer is the same hazard by a different route, and it bites the LAST subtest rather
    # than a timing-sensitive one. It is `OnCalendar=weekly` and enabled by default, so every
    # forward jump this test makes crosses a weekly boundary and fires it again -- and back-to-back
    # starts trip systemd's start limit, leaving `fstrim.service` permanently failed. "nothing was
    # left broken" then reports a failure that has nothing to do with the clock code. Disabled
    # rather than added to that subtest's exclusion list, because a repeatedly-fired timer is
    # something this test causes and can therefore prevent, not a fact about the host.
    services.fstrim.enable = lib.mkForce false;

    # mkForce: the shared test-node layer switches time sync off on every node (see
    # testNodeTimeSyncOff in flake.nix), which here is the thing under test.
    common.timeSync = {
      enable = lib.mkForce true;
      # Only the hosts this test impersonates, so no unreachable name adds delay. Three
      # operators (cloudflare, netnod, ptb), which the `sample = 1` below is well inside.
      servers = lib.mkForce [ goodHost staleHost redirectKeHost ];
      # mkForce because the host layer supplies the real floor (nixpkgs.lastModified). A 2026
      # floor would reject the deliberately-stale fixtures for the wrong reason.
      floor = lib.mkForce floor;
      # Only one operator can ever succeed here (the other's certificate is expired), so the
      # deployed sample of two could never converge. The quorum arithmetic itself is covered by
      # fixtures in quorum.rs; what this test is for is the two TLS legs.
      sample = lib.mkForce 1;
      timeoutSeconds = 3;
      # The boot run is the subject of the first subtest, so it keeps the module default. What
      # must not happen is a SECOND, timed run landing in the middle of the later subtests, which
      # move the clock in and out of certificate windows by hand -- so push the interval past the
      # end of the run. The timer's own wiring is asserted rather than exercised.
      interval = "3h";
    };

    # All four CAs. Verification is still real -- pass 1 must build a chain to a trusted root on
    # both legs -- so an impersonated server without a trusted CA would fail before any of this
    # became interesting.
    security.pki.certificateFiles = [
      dohGood.caFile
      dohStale.caFile
      ntsCert.caFile
      staleCert.caFile
      redirectCert.caFile
    ];

    system.stateVersion = stateVersion;
  };

  testScript = ''
    doh_ipv4 = ${builtins.toJSON dohGood.dohIpv4}
    doh_ipv6 = ${builtins.toJSON dohGood.dohIpv6}
    doh_domains = ${builtins.toJSON dohGood.dohDomains}
    FLOOR = ${toString floor}
    # The instants at which BOTH good certificates are valid; see the fixtures above.
    BOTH_FROM = ${toString bothFrom}
    BOTH_UNTIL = ${toString bothUntil}
    # A clock that is wrong by years but inside both windows, as a wall-clock string and as the
    # epoch second it must land on. The two have to agree, which is why every `date -s` in this
    # file passes `-u`: the string is otherwise read in the node's own timezone.
    IN_2030 = "${in2030}"
    IN_2030_EPOCH = ${toString in2030Epoch}

    start_all()

    for peer in (dohgood, dohstale):
        peer.wait_for_unit("fake-doh.service")
        peer.succeed(
            "${pkgs.coreutils}/bin/timeout 60 ${pkgs.bash}/bin/bash -c "
            "'until test -e /tmp/fake-doh-ready; do sleep 0.2; done'"
        )
    ntsgood.wait_for_unit("chronyd.service")
    ntsstale.wait_for_unit("chronyd.service")
    ntsredirect.wait_for_unit("chronyd.service")
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

    def dry_run(args, expect_success):
        # --force because the machine's clock is often already fine here, and a clock inside the
        # fixtures' validity makes the run stand down before it decides anything these subtests
        # are about. The stand-down rule itself is exercised separately, below.
        command = f"time-correction --force --dry-run {args} 2>&1"
        return machine.succeed(command) if expect_success else machine.fail(command)

    def run_unit(timeout=420):
        """Drive the deployed unit until a run succeeds, the way the timer would."""
        # Retried rather than started once, and the reason is this node's fixtures rather than any
        # weakness in the unit. `sample` is forced to 1 while `servers` lists both the good NTS
        # server and the deliberately-expired one, so each run draws one of the two at random and
        # about half of them MUST fail -- that is "any error fails the service run" doing its job,
        # and the same draw is what lets the subtests below pin each leg with --only.
        #
        # The retrying therefore lives in the driver, which is honest about whose job it is: the
        # unit has no Restart= at all, and on the deployed hosts every configured operator is real
        # and the timer is what tries again.
        machine.wait_until_succeeds(
            "systemctl reset-failed time-correction.service || true; "
            "systemctl start time-correction.service",
            timeout=timeout,
        )

    with subtest("the boot run is timed, and a host with no resolver fails it and changes nothing"):
        # The spec asks for "runs every hour and after boot", not "gets restarted until it
        # succeeds", so what is asserted here is a plain terminal failure plus an armed timer.
        before = clock()
        machine.wait_until_succeeds(
            "systemctl show -p Result --value time-correction.service | grep -qx exit-code",
            timeout=420,
        )
        # No retry, so the failure has to be visible as a failure rather than as a unit forever
        # mid-restart. That is what makes the run monitorable at all.
        assert machine.succeed(
            "systemctl show -p ActiveState --value time-correction.service"
        ).strip() == "failed"
        assert machine.succeed(
            "systemctl show -p Restart --value time-correction.service"
        ).strip() == "no"
        # And the next attempt is the timer's. A failed run must not disarm it -- systemd timers
        # are independent of the triggered unit's result, and this pins that nothing in the module
        # made them otherwise (a ConditionPathExists on the service, say, or Requisite on the
        # timer).
        assert machine.succeed(
            "systemctl show -p ActiveState --value time-correction.timer"
        ).strip() == "active"
        machine.succeed(
            "systemctl list-timers time-correction.timer --all | grep -q time-correction"
        )

        assert abs(clock() - before) < 120, "the clock moved with nothing reachable"
        # A box with no time still boots.
        machine.succeed("systemctl is-active multi-user.target")
        # And chronyd runs regardless, which is what modules/time-sync.nix declines to order
        # against this unit in order to guarantee. Either someone re-adding `Before=chronyd.service`
        # or a Requires-shaped dependency appearing would mean a host that can never reach an NTS
        # server runs no time daemon at all, chrony having forced timesyncd off -- and nothing else
        # in this suite would notice, because chrony-wait would simply never run. Note this is now
        # a stronger claim than it was: the unit also waits for network-online.target, so the
        # ordering would hold chronyd behind the network as well.
        machine.succeed("systemctl is-active chronyd.service")
        jobs = machine.succeed("systemctl list-jobs --no-legend || true")
        assert "chronyd" not in jobs, f"chronyd's start job is still queued:\n{jobs}"

    with subtest("the timer runs it after boot and then on the configured interval"):
        # Monotonic rather than OnCalendar + Persistent, deliberately: Persistent decides what was
        # missed by comparing a stored wall-clock stamp against the current clock, and a wrong
        # clock is the state this unit exists for. Pinned here because the difference is invisible
        # until the clock is wrong, which is exactly when it matters.
        unit = machine.succeed("systemctl cat time-correction.timer")
        assert "OnBootSec=1min" in unit, unit
        assert "OnUnitActiveSec=3h" in unit, unit
        assert "OnCalendar" not in unit, unit

        # And systemd agrees, so a directive it silently ignored cannot satisfy the check above.
        #
        # Asked one scalar at a time with --value, which is the only reliable form here: plain
        # `systemctl show -p NAME` omits properties whose value is empty unless --all is passed,
        # so a false boolean or an unset timestamp simply does not appear in the output and an
        # `in`-style assertion on it silently tests nothing. `-p TimersMonotonic -p Persistent`
        # on this unit comes back as nothing but the `Unit=` line, which is exactly the trap.
        def timer_property(name):
            return machine.succeed(
                f"systemctl show -p {name} --value time-correction.timer"
            ).strip()

        # A monotonic elapse is armed. This is the load-bearing half of "monotonic rather than
        # calendar": systemd fills in whichever of the two next-elapse fields matches the kind of
        # timer it actually parsed, so a unit that had somehow become calendar-driven would leave
        # this one unset.
        monotonic = timer_property("NextElapseUSecMonotonic")
        assert monotonic not in ("", "0", "infinity"), (
            f"no monotonic elapse is armed: {monotonic!r}"
        )
        assert timer_property("Persistent") == "no"
        assert timer_property("Unit") == "time-correction.service"

    # Outside the good certificates' validity, which is what makes the next subtest test
    # anything. The fixtures are 100-year certificates (tests/test-cert.nix) issued at build
    # time, so the tomorrow-10:00 clock these nodes boot with sits comfortably INSIDE them -- and
    # time-correction now stands down when the clock is already inside, because TLS works there and
    # there is nothing left for it to fix. 2001 is before every fixture's notBefore, so the unit
    # has to do the whole job.
    machine.succeed("date -u -s '2001-01-01 00:00:00'")

    use_resolver(dohgood)

    with subtest("the clock is set once the whole chain is reachable"):
        # The unit as the timer runs it, end to end: DoH resolution, NTS key establishment and an
        # authenticated NTP exchange, with nothing pinned by --only and nothing relaxed by
        # --force. This is also the only place the exporter-derived AEAD keys are exercised
        # against a real server rather than a fixture.
        #
        # Started explicitly rather than waited for: the unit is not RemainAfterExit, so
        # `wait_for_unit` would wait forever on a oneshot that goes inactive the moment it
        # succeeds. See run_unit for why a successful run has to be waited for rather than
        # demanded of the first attempt.
        run_unit()
        served = int(ntsgood.succeed("date +%s").strip())
        drift = abs(clock() - served)
        assert drift < 120, f"clock is {drift}s from what the NTS server serves"

    with subtest("an NTS server outside its certificate's validity is refused"):
        # The heart of it. ntsstale's certificate chains to a trusted CA, matches the hostname
        # and is accepted by pass 1 -- and expired in 2021, while the server's own clock is
        # correct. Only pass 2 can catch this.
        output = dry_run("--only netnod", expect_success=False)
        assert "not valid at the time the server reported" in output, output
        assert "NTS-KE" in output, f"the failing leg should be named: {output}"

    with subtest("a DoH resolver outside its certificate's validity is refused"):
        # The other leg, and it must fail even though the NTS server is beyond reproach: the
        # resolver that produced the address is part of what vouches for the answer, so its
        # certificate has to hold at the same instant.
        #
        # dohstale also sends padExpired, whose window is DISJOINT from its leaf's -- so the
        # certificates it sends have no common instant at all. That must not change which failure
        # this is: pass 1 has to get far enough to accept the chain, on an instant it takes from the
        # LEAF rather than from an intersection there is none of, and pass 2 has to reject it for the
        # leaf's own expiry. Asserting the message rather than merely `fail` is what distinguishes
        # the two: a client that refused the handshake over the off-path certificate would fail this
        # subtest's command just as reliably, and for a reason that would leave a wrong clock
        # unrecoverable.
        use_resolver(dohstale)
        output = dry_run("--only cloudflare", expect_success=False)
        assert "not valid at the time the server reported" in output, output
        assert "DoH" in output, f"the failing leg should be named: {output}"
        assert "no instant" not in output, (
            f"pass 1 judged the certificates the peer sent rather than the path: {output}"
        )
        use_resolver(dohgood)

    with subtest("a time below the floor is refused, before any chain is re-verified"):
        # Distinct from the two above: every chain is valid at this instant, and only the floor
        # rejects it. That is what bounds a rollback by a once-valid certificate.
        output = dry_run(f"--only cloudflare --floor {2 ** 40}", expect_success=False)
        assert "earlier than the build-time floor" in output, output
        # The ORDER, which the spec states and which is not cosmetic: the floor is applied to each
        # provider's own answer before that answer is used to re-verify anything. Pass 2 asks "was
        # this chain valid at the claimed instant", so it happily accepts a once-valid certificate
        # presented with a date inside its old window -- precisely the rollback the floor bounds.
        # Every certificate here IS valid now, so a pass-2 message appearing at all would mean the
        # chains were checked against a timestamp already refused.
        assert "not valid at the time the server reported" not in output, output

    with subtest("an NTS server that redirects timestamping to another host is followed"):
        # `nts.netnod.se` answers key establishment itself and hands timestamping to a different
        # host, marking the records CRITICAL -- lib/nts-servers.nix records the measurement. So
        # this branch runs against a real deployed provider on every draw that picks netnod, and
        # until now nothing exercised it: `nts::parse_response` and `timeserver::ntp_target` have
        # fixtures for the records and the target arithmetic, but the part in `main::ask_pair`
        # that acts on them -- a SECOND DoH lookup for the redirect's name, the address-family
        # match against the address key establishment worked over, and a THIRD chain recorded
        # into `Deferred` so pass 2 covers it too -- had no test at all.
        #
        # ntsredirect establishes keys as ${redirectKeHost} and redirects to ${redirectNtpHost},
        # which resolves back to itself. One daemon, so its own cookies authenticate the reply.
        dohgood.succeed("truncate -s 0 /tmp/queried-names")
        output = dry_run("--only ptb1", expect_success=True)
        assert "would set the clock to" in output, output

        # The evidence, and the reason the redirect target has a different name from the key
        # establishment host: nothing on this machine is configured with ${redirectNtpHost}, so
        # the only thing that can have asked for it is a client that read the redirect record
        # and went to resolve it. A client that ignored the record would have kept talking to
        # ${redirectKeHost}, which answers correctly, and every other assertion here would still
        # hold.
        queried = dohgood.succeed("cat /tmp/queried-names").split()
        assert "${redirectKeHost}" in queried, queried
        assert "${redirectNtpHost}" in queried, (
            f"the redirect was not followed; names resolved this run: {queried}"
        )

        # What this does NOT isolate, said plainly so nobody adds an assertion believing it
        # does: the redirect lookup records a THIRD chain into `Deferred`, and pointing this run
        # at the stale resolver would indeed fail it -- but on the first lookup, before the
        # redirect is even read, so it would prove nothing the DoH subtest above has not already
        # proved. Isolating the third chain needs a resolver that is good for one query and
        # stale for the next, which is a fixture this test has no other use for. The recording
        # itself is not conditional (`doh::resolve` records on every success), so what is left
        # untested is a line that cannot be skipped for the redirect alone.

    with subtest("one failing provider fails the whole run"):
        # Spec: "any error fails the service run". With --sample forced to 1 this node normally
        # asks one pair, so ask for two and let the deliberately-stale one be the second: the run
        # must fail and must NAME the pair that failed, since resolution, key establishment and
        # the NTP exchange are three different faults to go and look at.
        output = machine.fail("time-correction --force --dry-run --only cloudflare,netnod 2>&1")
        assert "provider pairs failed" in output, output
        assert "netnod" in output, f"the failing pair should be named: {output}"

    def stand_down_or_set(when):
        # Not --force and not --dry-run: the decision AND its effect are the subject. The
        # certificate window is the only thing that can decide these -- it is the program's sole
        # stand-down rule, and nothing consults the kernel's STA_UNSYNC.
        #
        # `-u`, so `when` names the same instant whatever the host's timezone is. Without it
        # `date -s` parses as LOCAL time, and the epoch bound below -- which is a UTC instant
        # worked out by hand -- is off by the offset: anya-feher-laptop is Europe/Budapest, so
        # 2030-01-01 00:00:00 landed an hour early and the subtest read it as a clock that moved.
        machine.succeed(f"date -u -s '{when}'")
        return machine.succeed("time-correction --only cloudflare 2>&1")

    with subtest("a clock already inside the certificates' validity is left alone"):
        # 2030 is wrong by years and inside both fixtures' validity, which is exactly the state
        # the rule is about: TLS works, so chrony can reach its sources and make the accurate
        # correction itself, and stepping here would only replace one wrong time with a
        # whole-second approximation of a different one.
        output = stand_down_or_set(IN_2030)
        assert "already inside the certificates' validity" in output, output
        # The reported window is the INTERSECTION of the two legs, asserted exactly. Without this
        # the subtest would pass just as well on a client that answered "every instant is inside"
        # whenever it could not work a window out -- which is the one wrong answer here, and the
        # reason `common_window` treats a single unknown as poisoning the whole result.
        assert f"({BOTH_FROM}..{BOTH_UNTIL})" in output, output
        # Still in 2030, i.e. not stepped back to what the NTS server serves. The lower bound is
        # IN_2030 itself, which is why stand_down_or_set places it as UTC -- see there.
        assert IN_2030_EPOCH <= clock() < 1900000000, f"the clock moved to {clock()}"

    with subtest("a certificate the peer sends but the path does not use gets no vote"):
        # The footgun in spec/features/system/time-correction-details.md, on the clock where it does
        # damage: a CORRECT one. dohgood sends padSuperseded beside its leaf -- expired in 2022,
        # chaining to a CA nobody trusts, so no path can include it -- and the window this run
        # reports has to be the two LEAVES' intersection, with the present comfortably inside.
        #
        # Judge by what arrived instead and the window ends in 2022, `now` is past it, and the run
        # steps a clock that was already right. Hourly, on every host at once, triggered by a
        # provider's chain file rather than by anything on the box. That is the whole reason the
        # window comes from `verified_window` rather than from the chain as sent.
        #
        # Non-vacuous in both directions, which matters more here than usual because the fixture is
        # only a fixture if the extra certificate really goes out on the wire: the peer is asked
        # what it sends, and the reported window is pinned exactly rather than merely "inside".
        sent = int(machine.succeed(
            f"${peerChainCount} {doh_ipv4[0]} {doh_domains[0]}"
        ).strip())
        assert sent == 2, f"dohgood sent {sent} certificates, not its leaf plus the off-path one"

        # The clock the NTS server itself keeps, i.e. right. Not IN_2030: the subtest above already
        # covers standing down on a clock that is merely inside the windows, and what is under test
        # here is that a healthy clock is left alone despite what the peer sent.
        machine.succeed(f"date -s @{int(ntsgood.succeed('date +%s').strip())}")
        healthy = clock()
        output = machine.succeed("time-correction --only cloudflare 2>&1")
        assert "already inside the certificates' validity" in output, output
        assert f"({BOTH_FROM}..{BOTH_UNTIL})" in output, output
        assert abs(clock() - healthy) < 120, f"a correct clock was stepped to {clock()}"

    with subtest("a clock outside the certificates' validity is set"):
        # The converse, so the subtest above cannot pass by time-correction having simply stopped
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

    with subtest("--force overrides the certificate window"):
        # The documented way to check the configured servers still answer on a host whose clock
        # is fine (`time-correction --force --dry-run`). The window rule is the only stand-down rule
        # left, so if --force did not override it this would report a stand-down on every healthy
        # host -- i.e. the escape hatch would be useless precisely where it is used.
        machine.succeed(f"date -u -s '{IN_2030}'")
        output = machine.succeed("time-correction --force --dry-run --only cloudflare 2>&1")
        assert "would set the clock to" in output, output
        machine.succeed(f"date -s @{int(ntsgood.succeed('date +%s').strip())}")

    with subtest("a v4-only host still gets a clock"):
        disconnect(v4=False, v6=True)
        dry_run("--only cloudflare", expect_success=True)
        use_resolver(dohgood)

    with subtest("a v6-only host still gets a clock"):
        # Not redundant with the above: the two families are separate addresses, sockets and
        # routes all the way down, and this repo already treats an asymmetry between them as
        # serious enough to run a dedicated v6-only client in tests/doh-upstream.nix.
        #
        # Retried rather than attempted once, because installing a route is not the same as
        # being able to use it: neighbour discovery for the gateway still has to complete, and
        # this is the first traffic this host sends over IPv6. There is no cheap independent
        # probe to wait on -- the interceptor answers TLS on 443 and nothing else, not even
        # ICMPv6 -- so retry the operation itself.
        #
        # The retry cannot rescue a v6 address that is `dadfailed`, which both interceptor nodes
        # holding the same provider /128s would otherwise produce; see the `nodad` note in
        # tests/doh-interceptor.nix for why that is not what is being waited on here.
        disconnect(v4=True, v6=False)
        machine.wait_until_succeeds(
            "time-correction --force --dry-run --only cloudflare", timeout=120
        )
        use_resolver(dohgood)

    with subtest("an NTS server reachable only over IPv6 still gives the time"):
        # The v4-only/v6-only pair above covers the DoH leg -- reaching the resolver. This
        # covers the other one: the resolver is reachable, but the NTS server it names is not
        # reachable over IPv4. A client that queried A alone would resolve to an address the host
        # cannot use and the whole chain would fail, which is why `ask_pair` asks for both.
        ntsgood_v4 = ntsgood.succeed(
            "${pkgs.iproute2}/bin/ip -j -4 addr show dev eth1 "
            "| ${pkgs.jq}/bin/jq -r '.[0].addr_info[] | select(.prefixlen==24) | .local'"
        ).strip()
        machine.succeed(f"${pkgs.iproute2}/bin/ip route replace unreachable {ntsgood_v4}/32")
        # Retried for the same reason as the subtest above: this is the first traffic to the
        # NTS server over IPv6, so its neighbour entry is cold.
        machine.wait_until_succeeds(
            "time-correction --force --dry-run --only cloudflare", timeout=120
        )
        machine.succeed(f"${pkgs.iproute2}/bin/ip route del unreachable {ntsgood_v4}/32")

    with subtest("the wrapper on PATH asks exactly what the timed unit asks"):
        # Everything above this line drives `time-correction ...` -- the wrapper
        # modules/time-sync.nix installs, preloaded with the unit's own flags -- rather than the
        # unit. So does `time-correction --force --dry-run` in the README and in
        # lib/nts-servers.nix, which is the documented way to check a live Pi's providers still
        # answer. All of that rests on the two carrying identical arguments: the wrapper and the
        # unit interpolate `correctionArgs` at two separate call sites, so a flag added to one and
        # not the other would leave every test here passing while the command an operator actually
        # runs asked something else.
        #
        # tests/time-sync-deployed.nix pins what those arguments ARE on the deployed hosts. This
        # pins that there is only one set of them, which is a claim about the module rather than
        # about any host -- so this node's forced `servers`/`sample`/`floor` do not weaken it.
        unit_exec = machine.succeed(
            "systemctl cat time-correction.service | grep -m1 '^ExecStart='"
        ).strip()[len("ExecStart="):]
        wrapper = machine.succeed("cat $(command -v time-correction)")
        execs = [l.strip() for l in wrapper.splitlines() if l.strip().startswith("exec ")]
        assert len(execs) == 1, f"the wrapper does not exec exactly once:\n{wrapper}"
        # `"$@"` is the wrapper's whole reason to exist -- it is what lets --only and --dry-run
        # be appended by hand -- so it is part of the expected string rather than stripped out.
        expected = f'exec {unit_exec} "$@"'
        assert execs[0] == expected, f"wrapper:\n  {execs[0]}\nunit:\n  {expected}"

    with subtest("the unit keeps exactly the privilege it needs"):
        def unit_property(name):
            return machine.succeed(
                f"systemctl show -p {name} --value time-correction.service"
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

    with subtest("a run recovers a clock two decades out"):
        # The whole job in one invocation of the deployed unit, with no flags of the driver's own:
        # 2001 is outside every fixture's validity, so the run has to resolve over DoH, establish
        # NTS, take a timestamp, re-verify both chains against it and step the clock. Worth
        # repeating here rather than resting on the earlier subtest, because by now the clock has
        # been moved in and out of certificate windows a dozen times and the unit has failed and
        # been reset repeatedly -- so this is also the check that none of that left it wedged.
        machine.succeed("date -u -s '2001-01-01 00:00:00'")
        run_unit()
        assert clock() > FLOOR, f"the run left the clock at {clock()}"

    with subtest("nothing was left broken"):
        # time-correction is excluded alongside chrony-wait: the first subtest deliberately left it
        # failed (a host with no reachable resolver), and with no Restart= that verdict is
        # terminal until something starts it again. The successful runs above each cleared it,
        # but a `reset-failed` is not a promise about ordering -- what matters here is that no
        # OTHER unit broke while the clock jumped around by decades.
        failed = machine.succeed("systemctl list-units --state=failed --no-legend || true").strip()
        remaining = [
            line for line in failed.splitlines()
            if "chrony-wait" not in line and "time-correction" not in line and line.strip()
        ]
        assert not remaining, "units failed after the clock step:\n" + "\n".join(remaining)
  '';
}
