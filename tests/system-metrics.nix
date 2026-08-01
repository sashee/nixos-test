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

    # Restored, not overridden: requireClockSync follows services.timesyncd.enable, which the
    # VM harness forces off, so without this the node would silently drop the clock gate that
    # every real host runs with. The marker timesyncd would write is faked in the script.
    common.systemMetrics.requireClockSync = true;

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


    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("monitoring-platform.service")

    # The unit is conditioned on timesyncd's "clock is real now" marker, and a test VM has no
    # NTP server to reach, so stand the marker up by hand -- the skip path it guards gets its
    # own subtest at the end.
    machine.succeed(
        "mkdir -p /run/systemd/timesync && touch /run/systemd/timesync/synchronized"
    )

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

    with subtest("an unsynchronised clock skips the run rather than dating it 1970"):
        machine.succeed("rm -f /run/systemd/timesync/synchronized")
        machine.succeed("systemctl reset-failed system-metrics.service")
        before = query("type=system.memory&limit=20")
        # Condition unsatisfied: systemd reports the start as a success and runs nothing, which
        # is the honest description -- the host simply does not know the time yet.
        machine.succeed("systemctl start system-metrics.service")
        assert query("type=system.memory&limit=20") == before, (
            "a run with no synchronised clock must not store anything"
        )
        machine.succeed("touch /run/systemd/timesync/synchronized")

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
