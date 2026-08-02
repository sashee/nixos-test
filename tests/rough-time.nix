{ nixpkgs, pkgs, stateVersion, machineModule, dohStamps, globalTimeout ? 900 }:

# The boot-time rough clock, end to end against a REAL TLS path.
#
# A second node impersonates the deployed DoH providers on their real addresses with a real
# certificate the machine trusts (tests/doh-interceptor.nix), so rough-time performs the
# handshake, the two-pass certificate check and the Date parse it performs in production. The
# only thing the test controls is what the servers say, which is exactly the input whose
# mishandling would be invisible: a Date outside the certificate's validity, a Date from a
# cache, two providers disagreeing, one provider answering twice from two addresses.
#
# Why so much of this drives the CLI wrapper rather than the unit: the unit samples two
# providers at random, and a test that has to hold a specific pair cannot be built on a random
# draw without either pinning the seed (which tests the shuffle, not the decision) or retrying
# until the draw cooperates (which turns an assertion into a coin flip). `rough-time` is on
# PATH preloaded with the unit's own flags, so `--only` picks the pair while everything else
# stays exactly what the unit would use. The unit itself is driven where the integration is the
# point: that it retries until the network appears, and that it succeeds unattended.
#
# NOT covered here, because it needs a clock that something has genuinely synchronised: the
# STA_UNSYNC no-op path. tests/nts-sync.nix has a real NTS server and covers it there.

let
  lib = nixpkgs.lib;

  # Well before any plausible build time, so it never blocks a real answer, while still being a
  # real value rather than 0 -- the floor is only exercised by passing a different one below.
  floor = 1700000000;

  interceptor = import ./doh-interceptor.nix {
    inherit pkgs dohStamps;
    name = "rough-time";
    readyFile = "/tmp/fake-doh-ready";

    # The DNS payload is irrelevant here -- nothing on the machine resolves through this node
    # during the test -- but it has to be well formed, because rough-time reads the response
    # like any HTTP client and a handler that raised would close the connection instead.
    respond = ''
      def respond(query, meta):
          return a(query, "192.0.2.1")
    '';

    # The actual subject of the test. Driven by a JSON file the test driver rewrites between
    # subtests, keyed on the Host header so each impersonated provider can be given a different
    # answer -- which is what the disagreement and one-provider-two-families cases need.
    responseHeaders = ''
      CONTROL = pathlib.Path("/tmp/rough-time-control.json")

      def header_overrides(meta):
          if not CONTROL.exists():
              return {}
          control = json.loads(CONTROL.read_text())
          # A per-host entry wins over "*", so a subtest can change one provider and leave the
          # others answering normally.
          entry = control.get(meta.get("host") or "", control.get("*", {}))
          out = {}
          if entry.get("omit_date"):
              out["Date"] = None
          elif "epoch" in entry:
              out["Date"] = http_date(entry["epoch"])
          elif "offset" in entry:
              out["Date"] = http_date(time.time() + entry["offset"])
          if "age" in entry:
              out["Age"] = str(entry["age"])
          return out
    '';
  };
in

nixpkgs.lib.nixos.runTest {
  name = "rough-time";
  hostPkgs = pkgs;
  skipTypeCheck = true;

  # Ceiling, not a wait: the rpi variant runs under TCG emulation on the KVM-less aarch64 CI
  # runner, where the retry-until-success subtest alone spans several 30s restarts.
  inherit globalTimeout;

  # Impersonates all four DoH providers on their real addresses. Binds 0.0.0.0:443, so it needs
  # its own node.
  nodes.dohpeer = { ... }: {
    networking = {
      hostName = "dohpeer";
      firewall.enable = false;
    };
    # Helper node, tiny workload: keeps the two-VM run affordable under aarch64 TCG.
    virtualisation.memorySize = 512;
    systemd.services.fake-doh = interceptor.mkService { };
    system.stateVersion = stateVersion;
  };

  nodes.machine = { lib, ... }: {
    imports = [ machineModule ];

    networking.hostName = "rough-time-test";

    # Off in the VM: no network for upgrades, no credentials for reporting/iroh.
    common.autoUpgrade.enable = lib.mkForce false;
    common.monitoring.enable = lib.mkForce false;
    common.irohSsh.enable = lib.mkForce false;

    # The real module, with only the floor supplied (it has no default by design) and the
    # timeout shortened so an unreachable address costs seconds rather than tens of them --
    # every subtest below waits on at least one.
    # mkForce: the shared test-node layer switches time sync off on every node (see
    # testNodeTimeSyncOff in flake.nix), which for this test is the thing under test.
    common.timeSync = {
      enable = lib.mkForce true;
      # mkForce because the host layer supplies the real floor (nixpkgs.lastModified). A 2026
      # floor would put the 2024 date in the certificate-validity subtest below it, so that
      # subtest would pass by being rejected for the wrong reason -- the exact confusion the
      # `assert ... > FLOOR` guard in the test script exists to catch.
      floor = lib.mkForce floor;
      timeoutSeconds = 3;
    };

    # Only this CA, so the two-pass verification is doing real work: pass 1 still has to build
    # a chain to a trusted root, and pass 2 still has to place the reported Date inside the
    # leaf's validity.
    security.pki.certificateFiles = [ interceptor.caFile ];

    system.stateVersion = stateVersion;
  };

  testScript = ''
    import json

    doh_ipv4 = ${builtins.toJSON interceptor.dohIpv4}
    doh_ipv6 = ${builtins.toJSON interceptor.dohIpv6}
    providers = ${builtins.toJSON (lib.mapAttrs (_: p: p.hostname) dohStamps.providers)}
    FLOOR = ${toString floor}

    dohpeer.start()
    dohpeer.wait_for_unit("fake-doh.service")
    dohpeer.succeed(
        "${pkgs.coreutils}/bin/timeout 60 ${pkgs.bash}/bin/bash -c "
        "'until test -e /tmp/fake-doh-ready; do sleep 0.2; done'"
    )

    def control(entries):
        # Rewritten between subtests and read per request, so no server restart is needed and
        # a subtest cannot inherit the previous one's answers.
        dohpeer.succeed(
            "${pkgs.coreutils}/bin/install -m 644 /dev/stdin /tmp/rough-time-control.json <<'EOF'\n"
            + json.dumps(entries)
            + "\nEOF"
        )

    def clear_control():
        dohpeer.succeed("rm -f /tmp/rough-time-control.json")

    def peer_ip():
        return dohpeer.wait_until_succeeds(
            "${pkgs.iproute2}/bin/ip -j -4 addr show dev eth1 "
            "| ${pkgs.jq}/bin/jq -r '.[0].addr_info[] | select(.prefixlen==24) | .local' "
            "| ${pkgs.gnugrep}/bin/grep .",
            timeout=120,
        ).strip()

    def connect_upstream():
        # Runtime routes, exactly as tests/iroh-ssh.nix installs them: the machine's own config
        # is untouched, so it dials the providers' real addresses believing nothing has changed.
        via = peer_ip()
        for ip in doh_ipv4:
            machine.succeed(f"${pkgs.iproute2}/bin/ip route replace {ip}/32 via {via} dev eth1")
        for ip in doh_ipv6:
            machine.succeed(f"${pkgs.iproute2}/bin/ip -6 route replace {ip}/128 dev eth1")

    def disconnect_upstream(v4=True, v6=True):
        # `unreachable` rather than deleting the route: an unreachable route fails immediately
        # instead of costing the full connect timeout, which keeps the v4-only subtest quick.
        if v4:
            for ip in doh_ipv4:
                machine.succeed(f"${pkgs.iproute2}/bin/ip route replace unreachable {ip}/32")
        if v6:
            for ip in doh_ipv6:
                machine.succeed(f"${pkgs.iproute2}/bin/ip -6 route replace unreachable {ip}/128")

    def clock():
        return int(machine.succeed("date +%s").strip())

    def rough_time(args, expect_success):
        # --force because the wrapper is used on a machine whose clock this test has often just
        # set; the unit's own STA_UNSYNC short-circuit is covered in tests/nts-sync.nix.
        # --dry-run because these subtests are about the decision, not about stepping the clock.
        command = f"rough-time --force --dry-run {args} 2>&1"
        if expect_success:
            return machine.succeed(command)
        return machine.fail(command)

    machine.wait_for_unit("multi-user.target")

    with subtest("a host that cannot reach any provider keeps trying and changes nothing"):
        # No routes have been installed yet, so this is the state a real cold boot starts in.
        before = clock()
        # The unit must be retrying rather than dead: a terminal failure here would mean a box
        # that never gets a clock, never gets DNS, and cannot be reached to be told so.
        machine.wait_until_succeeds(
            "systemctl show -p NRestarts --value rough-time.service | grep -qvx 0", timeout=180
        )
        state = machine.succeed("systemctl show -p ActiveState --value rough-time.service").strip()
        assert state in ("activating", "failed"), f"unexpected state {state}"
        # `failed` here is the between-restarts state, not a give-up: systemd only stops
        # retrying when the start limit trips, and RestartSec keeps it clear of that.
        assert (
            "start-limit" not in machine.succeed("systemctl status rough-time.service || true")
        ), "the restart rate limit stopped the retries"
        drift = abs(clock() - before)
        assert drift < 120, f"the clock moved {drift}s with no reachable provider"
        # The whole point of ordering rather than requiring: a box with no time still boots.
        machine.succeed("systemctl is-active multi-user.target")

    connect_upstream()

    with subtest("the clock is set once the providers are reachable"):
        clear_control()
        # Unattended: the driver does not start the unit, it only repairs the network, so this
        # asserts the retry loop converges on its own.
        machine.wait_for_unit("rough-time.service", timeout=300)
        served = int(dohpeer.succeed("date +%s").strip())
        drift = abs(clock() - served)
        assert drift < 120, f"clock is {drift}s from what the providers served"

    with subtest("a Date outside the certificate's validity is refused"):
        # The single most important case: this is what stops "ignore the dates during the
        # handshake" from becoming "accept a chain from anyone holding any old certificate".
        #
        # 2024-01-01, chosen to sit ABOVE the floor and below the test CA's notBefore (its
        # build time). An earlier date would also be rejected, but by the floor -- so the
        # subtest would still pass with pass 2 deleted entirely, which is precisely the bug it
        # exists to catch. Verified by mutation: removing the pass 2 call makes this fail.
        assert 1704067200 > FLOOR, "the date below must exercise validity, not the floor"
        control({"*": {"epoch": 1704067200}})
        output = rough_time("--only cloudflare,google", expect_success=False)
        assert "not valid at the time the server reported" in output, output

    with subtest("a Date below the floor is refused even though the certificate allows it"):
        # Distinct from the case above: the chain is perfectly valid at this instant. Only the
        # floor rejects it, which is what bounds a rollback by a once-valid certificate.
        clear_control()
        output = rough_time(f"--only cloudflare,google --floor {2 ** 40}", expect_success=False)
        assert "earlier than the build-time floor" in output, output

    with subtest("providers that disagree set nothing"):
        control({
            providers["cloudflare"]: {"offset": 0},
            providers["google"]: {"offset": 300},
        })
        output = rough_time("--only cloudflare,google", expect_success=False)
        assert "providers disagree" in output, output

    with subtest("the tolerance boundary is where it says it is"):
        control({
            providers["cloudflare"]: {"offset": 0},
            providers["google"]: {"offset": 59},
        })
        rough_time("--only cloudflare,google --tolerance 60", expect_success=True)

        control({
            providers["cloudflare"]: {"offset": 0},
            providers["google"]: {"offset": 61},
        })
        output = rough_time("--only cloudflare,google --tolerance 60", expect_success=False)
        assert "providers disagree" in output, output

    with subtest("one provider answering on both families is still one vote"):
        # cloudflare answers over IPv4 and IPv6; quad9 says nothing. Two answers arrive, but
        # from one operator, and a quorum of two must not be satisfied by that.
        clear_control()
        control({providers["quad9"]: {"omit_date": True}})
        output = rough_time("--only cloudflare,quad9", expect_success=False)
        assert "of 2 providers gave no usable answer" in output, output
        assert "quad9" in output, output

    with subtest("a cached response is ignored"):
        clear_control()
        control({providers["google"]: {"age": 122}})
        output = rough_time("--only cloudflare,google", expect_success=False)
        assert "served from a cache" in output, output

    with subtest("a provider that sends no Date at all is reported as such"):
        clear_control()
        control({"*": {"omit_date": True}})
        output = rough_time("--only cloudflare,google", expect_success=False)
        assert "no Date header" in output, output

    with subtest("a v4-only host still gets a clock"):
        # The rpi5 has no IPv6 route in practice, so every v6 endpoint fails. Those failures
        # must count as "no answer from that address", never as a provider disagreeing.
        clear_control()
        disconnect_upstream(v4=False, v6=True)
        rough_time("--only cloudflare,google", expect_success=True)
        connect_upstream()

    with subtest("the deployed provider set still converges"):
        # Reproduces production: quad9 and mullvad send no Date, so only one draw in six can
        # succeed. The unit must still get there on its own, which is the property that makes
        # shipping the full DoH list acceptable rather than curating a list of what works.
        control({
            providers["quad9"]: {"omit_date": True},
            providers["mullvad"]: {"omit_date": True},
        })
        machine.succeed("date -s '2001-01-01 00:00:00'")
        machine.succeed("systemctl reset-failed rough-time.service || true")
        machine.succeed("systemctl restart rough-time.service || true")
        # Wait on the clock, not on the unit. `systemctl show -p Result` reports the last
        # FINISHED run, and `reset-failed` resets it to "success" -- so polling it returns
        # immediately on the previous run's result and the assertion below then races the
        # retry loop. Observed exactly that: a draw that needed several retries failed here
        # while the unit was still working.
        machine.wait_until_succeeds(f"test $(date +%s) -gt {FLOOR}", timeout=600)
        assert clock() > FLOOR, "the clock was never brought forward"

    with subtest("nothing was left broken"):
        # A step of a quarter century just happened. Anything that ended up failed because of
        # it is a real finding, not test noise.
        failed = machine.succeed("systemctl list-units --state=failed --no-legend || true").strip()
        # chrony-wait is expected: there is no NTS server on this network for it to wait for.
        remaining = [
            line for line in failed.splitlines() if "chrony-wait" not in line and line.strip()
        ]
        assert not remaining, "units failed after the clock step:\n" + "\n".join(remaining)
  '';
}
