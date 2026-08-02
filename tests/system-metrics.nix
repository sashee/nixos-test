{ nixpkgs, pkgs, machineModule, stateVersion, globalTimeout ? 600 }:

# End-to-end check of the measurement producer against a REAL monitoring-platform receiver: the
# node is the deployed host config, so the collector posts through the actual unix socket, the
# actual group permissions and the actual OTLP decoder, and the assertions read the results back
# out of the receiver's own query API. That round trip is what verifies the protobuf encoding --
# nothing here inspects the wire bytes, because the receiver is the only opinion that counts.

nixpkgs.lib.nixos.runTest {
  name = "system-metrics";
  hostPkgs = pkgs;
  inherit globalTimeout;

  nodes.machine = { lib, ... }: {
    imports = [ machineModule ];

    networking.hostName = "system-metrics-test";
    # Neither can work in a VM: auto-upgrade needs /etc/nixos, monitoring and iroh-ssh need
    # credentials. Nothing here is about them.
    common.autoUpgrade.enable = lib.mkForce false;
    common.monitoring.enable = lib.mkForce false;
    common.irohSsh.enable = lib.mkForce false;

    # Restored, not overridden. qemu-vm.nix disables timesyncd on every test node, which would
    # take `requireClockSync` (it follows services.timesyncd.enable) down with it and quietly
    # drop the clock gate. mkForce because that definition is at normal priority, so a plain
    # `true` fails to merge.
    #
    # Note this is no longer the configuration the hosts deploy: they run chrony, which forces
    # timesyncd off, and gate on /run/chrony-wait/synchronized instead (modules/time-sync.nix).
    # This test keeps the timesyncd marker because it is the option's default and the cheaper
    # way to exercise the gate MECHANISM -- one node, no NTS server. The deployed marker is
    # asserted end to end by tests/nts-sync.nix, which has real chrony to synchronise.
    services.timesyncd = {
      enable = lib.mkForce true;
      servers = [ "ntp-server" ];
      # The nixos pool is unreachable from a test net; without this timesyncd would keep
      # retrying it and the "no working NTP" state below would be noisier than it needs to be.
      fallbackServers = [ ];
    };

    system.stateVersion = stateVersion;
  };

  # The only time source on this network. Its own node because chrony, ntpd and openntpd all
  # `mkForce services.timesyncd.enable = false` -- a real NTP daemon cannot sit next to the
  # timesyncd client it is meant to serve.
  nodes.ntp = { lib, ... }: {
    networking.hostName = "ntp-server";
    networking.firewall.allowedUDPPorts = [ 123 ];
    # Helper node, tiny workload: keeps the two-VM run affordable under aarch64 TCG.
    virtualisation.memorySize = 512;

    # The same RTC base the node under test runs on. Without it this node would serve real
    # wall-clock time to a client pinned at tomorrow-10:00, and timesyncd would step that
    # client 10-34 hours BACKWARDS mid-test -- rearming the nix-gc Persistent timers the
    # pinning exists to avoid, and breaking the "each run appends a newer batch" assertion
    # below. `date -d tomorrow` is day-truncated, so both nodes resolve to the same instant.
    virtualisation.qemu.options = [ (import ../lib/test-rtc-base.nix pkgs.coreutils) ];

    services.chrony = {
      enable = true;
      # An island: there is no upstream to reach, and `local` is what makes chronyd offer its
      # own clock as a valid reference anyway instead of refusing to answer until it syncs.
      servers = [ ];
      extraConfig = ''
        local stratum 10
        allow all
      '';
    };
    # Not started at boot: "no working NTP" is the state the first subtest needs, and starting
    # this daemon is how the test flips the machine to "the clock is real now".
    systemd.services.chronyd.wantedBy = lib.mkForce [ ];

    system.stateVersion = stateVersion;
  };

  testScript = ''
    import json

    SOCKET = "/run/monitoring-platform/monitoring-platform.sock"


    def query(params):
        # root is not in the monitoring-platform group but bypasses the 0750 runtime
        # directory anyway, so the test needs no extra client user of its own.
        raw = machine.succeed(
            f"curl -sS --unix-socket {SOCKET} 'http://localhost/v1/measurements?{params}'"
        )
        return json.loads(raw)["measurements"]


    def collect():
        # A oneshot started back to back trips systemd's start rate limit, which would fail the
        # start with "start-limit-hit" rather than run the unit.
        machine.succeed("systemctl reset-failed system-metrics.service")
        machine.succeed("systemctl start system-metrics.service")
        state = machine.succeed(
            "systemctl show -p Result --value system-metrics.service"
        ).strip()
        assert state == "success", f"collector run failed: {state}"


    def bodies(measurements, kind):
        return [m["body"] for m in measurements if m["type"] == kind]


    MARKER = "/run/systemd/timesync/synchronized"


    def unix_seconds(node):
        return int(node.succeed("date +%s").strip())


    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("monitoring-platform.service")
    ntp.wait_for_unit("multi-user.target")

    with subtest("a host that does not know the time records nothing"):
        # The natural state of a freshly booted machine whose only NTP server is down. Nothing
        # here fakes it: chronyd is simply not started yet.
        machine.fail(f"test -e {MARKER}")
        # Asserted on the unit file: systemd exposes conditions as an opaque `Conditions`
        # array, not as a per-type property `systemctl show` can be asked for.
        machine.succeed(
            f"systemctl cat system-metrics.service | grep -Fx 'ConditionPathExists={MARKER}'"
        )

        # An unmet condition is a no-op, not a failure -- the host is not broken, it just does
        # not know what time it is -- so the start succeeds and the receiver stays empty.
        machine.succeed("systemctl start system-metrics.service")
        assert query("limit=10") == [], (
            "a host with no synchronised clock must not store measurements"
        )

    with subtest("the gate opens once NTP works"):
        ntp.succeed("systemctl start chronyd.service")
        ntp.wait_for_unit("chronyd.service")

        before = unix_seconds(machine)
        # RuntimeDirectory=, so a restart clears the marker and re-polls immediately: a clean
        # edge trigger rather than waiting out timesyncd's poll interval.
        machine.succeed("systemctl restart systemd-timesyncd.service")
        machine.wait_for_file(MARKER)

        # Both nodes share the RTC base, so synchronising must be a nudge and not a leap. A
        # ~24h step would mean the helper node lost the base and served real wall-clock time,
        # which would otherwise surface much later as a baffling assertion failure.
        drift = abs(unix_seconds(machine) - before)
        assert drift < 300, f"synchronising moved the clock by {drift}s; the nodes disagree"

    with subtest("the collector is wired to a timer, not run by hand"):
        machine.succeed("systemctl is-active system-metrics.timer")
        unit = machine.succeed(
            "systemctl show -p Unit --value system-metrics.timer"
        ).strip()
        assert unit == "system-metrics.service", f"the timer points at {unit}"
        assert "monitoring-platform.service" in machine.succeed(
            "systemctl show -p After --value system-metrics.service"
        ), "the collector must be ordered after the receiver it posts to"
        # From here the driver owns every run: left armed, a timer tick landing mid-test would
        # break the batch counting at the end.
        machine.succeed("systemctl stop system-metrics.timer")

    with subtest("the collector reaches the socket without being root"):
        assert machine.succeed(
            "systemctl show -p DynamicUser --value system-metrics.service"
        ).strip() == "yes", "the collector should not need an account of its own"
        assert "monitoring-platform" in machine.succeed(
            "systemctl show -p SupplementaryGroups --value system-metrics.service"
        ), "group membership is the only thing that opens the 0750 socket directory"

    with subtest("the operator can inspect a batch without sending it"):
        # Same flags as the unit, so this is what the next tick would post -- and it must not
        # reach the receiver, which the row count below confirms.
        before = len(query("limit=200"))
        planned = machine.succeed("system-metrics --dry-run")
        assert len(query("limit=200")) == before, "--dry-run must not store anything"
        planned_types = sorted(
            line.split()[1] for line in planned.splitlines() if line.startswith("record ")
        )
        assert planned_types, f"--dry-run printed no records:\n{planned}"

    with subtest("a run lands every measurement type in the receiver"):
        collect()
        measurements = query("limit=200")
        types = {m["type"] for m in measurements}
        assert types == {
            "system.cpu",
            "system.memory",
            "system.filesystem",
            "system.generation",
            "system.host",
        }, f"unexpected measurement types: {sorted(types)}"
        assert sorted(m["type"] for m in measurements) == planned_types, (
            "the batch that landed differs from the one --dry-run predicted"
        )

    with subtest("nothing was rejected on the way in"):
        # Rejections come back as an HTTP 200 with a partial_success, so the only proof the
        # batch was accepted whole is the receiver's own log plus the counts above.
        receiver_log = machine.succeed("journalctl -u monitoring-platform.service -o cat")
        assert "with rejections" not in receiver_log, (
            f"receiver rejected records:\n{receiver_log}"
        )

    with subtest("the values are real, not placeholders"):
        memory = bodies(measurements, "system.memory")[0]
        assert memory["total_bytes"] > 0
        assert 0 < memory["available_bytes"] <= memory["total_bytes"]
        assert memory["used_bytes"] == memory["total_bytes"] - memory["available_bytes"]

        cpu = bodies(measurements, "system.cpu")[0]
        assert cpu["cores"] >= 1, cpu
        assert 0.0 <= cpu["utilization_percent"] <= 100.0, cpu
        assert cpu["load1"] >= 0.0, cpu

        host = bodies(measurements, "system.host")[0]
        assert host["uptime_seconds"] > 0, host
        assert host["kernel_release"], host

    with subtest("filesystems are the real volumes, not the kernel's pseudo ones"):
        filesystems = [
            m for m in measurements if m["type"] == "system.filesystem"
        ]
        roots = [
            m for m in filesystems
            if m["attributes"]["record.attributes.mountpoint"] == "/"
        ]
        assert len(roots) == 1, f"expected exactly one root filesystem, got {len(roots)}"
        assert roots[0]["body"]["total_bytes"] > 0
        assert 0.0 <= roots[0]["body"]["used_percent"] <= 100.0

        fstypes = {m["attributes"]["record.attributes.fstype"] for m in filesystems}
        excluded = {"tmpfs", "devtmpfs", "proc", "sysfs", "9p", "virtiofs", "erofs"}
        assert not (fstypes & excluded), f"excluded types were reported: {fstypes & excluded}"

    with subtest("the percentages agree with df rather than inventing their own"):
        df_percent = int(
            machine.succeed("df --output=pcent / | tail -1 | tr -dc 0-9").strip()
        )
        reported = roots[0]["body"]["used_percent"]
        assert abs(reported - df_percent) <= 1, f"{reported} vs df's {df_percent}"

    with subtest("every measurement identifies the host that produced it"):
        for m in measurements:
            attributes = m["attributes"]
            assert attributes["resource.attributes.host.name"] == "system-metrics-test", m
            assert attributes["resource.attributes.service.name"] == "system-metrics", m
            assert attributes["scope.name"] == "system-metrics", m

    with subtest("the generation number appears once a system profile exists"):
        # A VM never runs nixos-rebuild, so there is no /nix/var/nix/profiles/system yet and
        # the collector reports the record without a `current` key rather than inventing a 0.
        generation = bodies(measurements, "system.generation")[0]
        assert "current" not in generation, generation
        assert generation["activated_since_boot"] is False, generation

        machine.succeed("nix-env -p /nix/var/nix/profiles/system --set /run/current-system")
        collect()
        generation = bodies(query("type=system.generation&limit=10"), "system.generation")[0]
        assert generation["current"] == 1, generation

    with subtest("each run appends a new batch instead of overwriting the last"):
        before = query("type=system.memory&limit=10")
        collect()
        after = query("type=system.memory&limit=10")
        assert len(after) == len(before) + 1, (len(before), len(after))
        # Ordered event_time DESC, so the newest is first and must be strictly newer.
        assert int(after[0]["event_time_unix_nano"]) > int(before[0]["event_time_unix_nano"])

    with subtest("losing NTP closes the gate again"):
        # The operationally important half: a host that loses its time source stops recording
        # rather than carrying on with a clock nobody is correcting.
        ntp.succeed("systemctl stop chronyd.service")
        machine.succeed("systemctl restart systemd-timesyncd.service")
        machine.wait_until_fails(f"test -e {MARKER}", timeout=60)

        machine.succeed("systemctl reset-failed system-metrics.service")
        before = query("type=system.memory&limit=20")
        machine.succeed("systemctl start system-metrics.service")
        assert query("type=system.memory&limit=20") == before, (
            "a run with no synchronised clock must not store anything"
        )

        ntp.succeed("systemctl start chronyd.service")
        machine.succeed("systemctl restart systemd-timesyncd.service")
        machine.wait_for_file(MARKER)

    with subtest("a receiver that is down fails the run instead of skipping it"):
        # There is deliberately no ConditionPathExists on the socket: a condition would mark
        # the unit green and the measurements would simply stop, silently and forever.
        machine.succeed("systemctl stop monitoring-platform.service")
        machine.succeed("systemctl reset-failed system-metrics.service")
        machine.fail("systemctl start system-metrics.service")
        assert "cannot reach" in machine.succeed(
            "journalctl -b -u system-metrics.service -o cat"
        ), "a missing receiver should be named in the journal"

        machine.succeed("systemctl start monitoring-platform.service")
        machine.wait_for_unit("monitoring-platform.service")
        collect()
  '';
}
