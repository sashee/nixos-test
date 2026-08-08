{ nixpkgs, pkgs, machineModule, stateVersion, globalTimeout ? 600 }:

# End-to-end check of the measurement producer over the REAL deployed path: the node is the
# deployed host config, so the producer posts through the actual unix socket to the on-host
# `mp-collector`, which forwards to the actual receiver, and the assertions read the results back
# out of the receiver's own query API. That round trip is what verifies the protobuf encoding --
# nothing here inspects the wire bytes, because the receiver is the only opinion that counts.
#
# "Collector" here always means mp-collector, the forwarding hop. The thing that samples /proc is
# the *producer* (system-metrics.service); it used to be called the collector, back when it posted
# to the receiver directly.
#
# Scope. The collector's own behaviour -- its sandbox, its unit ordering against the time daemons,
# its buffering across a receiver restart, its step detection -- belongs to upstream's suite,
# which this repo already runs against the same host configs (the monitoring-platform-* checks).
# What is only testable here is the seam: that OUR producer targets the collector and nothing
# else, that it can reach it, and that the deployed consequence of that hop -- no clock gate --
# preserves the pre-sync samples the gate used to discard.

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

    # Restored, not overridden: qemu-vm.nix disables timesyncd on every test node. mkForce
    # because that definition is at normal priority, so a plain `true` fails to merge.
    #
    # This is no longer about the producer's clock gate -- the collector in the path switches that
    # off (common.systemMetrics.viaCollector) -- it is about giving the node a time source it can
    # be moved between states with. What the collector reads is adjtimex(2), not this marker, so
    # the marker below is only ever used here as a convenient observable for "has the clock been
    # disciplined yet"; the assertions that matter ask the collector.
    #
    # Note this is not the configuration the hosts deploy: they run chrony, which forces timesyncd
    # off (modules/time-sync.nix). timesyncd is kept because it is the cheaper way to drive the
    # clock between synced and unsynced -- one node, no NTS server -- and the collector cannot
    # tell the difference.
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
    COLLECTOR = "/run/mp-collector/mp-collector.sock"


    def query(params):
        # root is not in the monitoring-platform group but bypasses the 0750 runtime
        # directory anyway, so the test needs no extra client user of its own.
        raw = machine.succeed(
            f"curl -sS --unix-socket {SOCKET} 'http://localhost/v1/measurements?{params}'"
        )
        return json.loads(raw)["measurements"]


    def collector_health():
        raw = machine.succeed(
            f"curl -sS --fail-with-body --unix-socket {COLLECTOR} http://localhost/healthz"
        )
        return json.loads(raw)


    def collect():
        # A oneshot started back to back trips systemd's start rate limit, which would fail the
        # start with "start-limit-hit" rather than run the unit.
        machine.succeed("systemctl reset-failed system-metrics.service")
        machine.succeed("systemctl start system-metrics.service")
        state = machine.succeed(
            "systemctl show -p Result --value system-metrics.service"
        ).strip()
        assert state == "success", f"producer run failed: {state}"


    def collect_batch(params="limit=200"):
        # One run, and the records it put in the store.
        #
        # Two things this handles that a bare collect() + query() cannot, both consequences of
        # the collector hop. First, the producer's run finishing is not the batch arriving: the
        # collector resolves the frame, applies the correction and forwards asynchronously, so
        # a read straight after the run races it. Second, the store is no longer empty when the
        # assertions start -- the pre-sync batch is already in it -- so "the batch" has to be a
        # delta rather than everything.
        #
        # Taking the head is sound because the read API orders event_time DESC, id DESC and the
        # records that just landed are both the newest and the highest-id ones.
        before = len(query(params))
        collect()
        retry(lambda _: len(query(params)) > before)
        rows = query(params)
        return rows[: len(rows) - before]


    def bodies(measurements, kind):
        return [m["body"] for m in measurements if m["type"] == kind]


    MARKER = "/run/systemd/timesync/synchronized"


    def unix_seconds(node):
        return int(node.succeed("date +%s").strip())


    start_all()
    machine.wait_for_unit("multi-user.target")
    # Type=notify on both, so `active` means each socket is bound and accepting.
    machine.wait_for_unit("mp-collector.service")
    machine.wait_for_unit("monitoring-platform.service")
    ntp.wait_for_unit("multi-user.target")

    with subtest("the producer names the collector and nothing further downstream"):
        # The property the whole indirection exists for: when the receiver moves off this host,
        # the only thing that changes is the collector's --forward-to. Asserted on the rendered
        # ExecStart rather than on the Nix, because "the producer does not know where the
        # receiver is" is a claim about the command line that actually runs.
        producer = machine.succeed("systemctl cat system-metrics.service")
        exec_lines = [
            line for line in producer.splitlines() if line.startswith("ExecStart=")
        ]
        assert exec_lines, f"no ExecStart in the producer unit:\n{producer}"
        assert any(COLLECTOR in line for line in exec_lines), (
            f"the producer does not post to the collector socket:\n{exec_lines}"
        )
        assert not any(SOCKET in line for line in exec_lines), (
            f"the producer names the receiver's socket; moving the receiver would edit it "
            f"too:\n{exec_lines}"
        )

        # The other half: the collector is the one that knows. (After=monitoring-platform.service
        # on the producer is not a counterexample -- ordering against a unit that may not exist
        # is a no-op, and it carries no address.)
        forwarder = machine.succeed("systemctl cat mp-collector.service")
        assert SOCKET in forwarder, (
            f"the collector does not forward to the receiver's socket:\n{forwarder}"
        )

    with subtest("the producer is wired to a timer, not run by hand"):
        machine.succeed("systemctl is-active system-metrics.timer")
        unit = machine.succeed(
            "systemctl show -p Unit --value system-metrics.timer"
        ).strip()
        assert unit == "system-metrics.service", f"the timer points at {unit}"
        assert "mp-collector.service" in machine.succeed(
            "systemctl show -p After --value system-metrics.service"
        ), "the producer must be ordered after the collector it posts to"
        # From here the driver owns every run: left armed, a timer tick landing mid-test would
        # break the batch counting at the end.
        machine.succeed("systemctl stop system-metrics.timer")

    with subtest("the producer reaches the socket without being root"):
        assert machine.succeed(
            "systemctl show -p DynamicUser --value system-metrics.service"
        ).strip() == "yes", "the producer should not need an account of its own"
        # The collector's group, not the receiver's: access at either end is the mode on the
        # containing 0750 runtime directory, and the producer only ever opens the near one.
        groups = machine.succeed(
            "systemctl show -p SupplementaryGroups --value system-metrics.service"
        )
        assert "mp-collector" in groups, (
            f"group membership is the only thing that opens the 0750 socket directory: {groups!r}"
        )

    with subtest("a host that does not know the time records anyway, held not dropped"):
        # The natural state of a freshly booted machine whose only NTP server is down. Nothing
        # here fakes it: chronyd is simply not started yet.
        machine.fail(f"test -e {MARKER}")
        health = collector_health()
        assert not health["clock"]["ever_synchronized"], (
            f"this subtest needs an undisciplined clock to be about anything: {health}"
        )

        # The gate is GONE, and its absence is the point: the collector holds a pre-sync batch
        # and re-dates it, where the condition used to discard the run outright. Asserted on the
        # unit file because systemd exposes conditions as an opaque `Conditions` array, not as a
        # per-type property `systemctl show` can be asked for.
        assert f"ConditionPathExists={MARKER}" not in machine.succeed(
            "systemctl cat system-metrics.service"
        ), "the clock gate is redundant once the collector re-dates pre-sync batches"

        collect()
        # Buffered, not forwarded: "clock never set this boot" is the one state the collector
        # withholds in (design 8.1), so the receiver must still be empty.
        assert query("limit=10") == [], (
            "a batch stamped against an unsynchronised clock must not reach the store yet"
        )
        assert collector_health()["buffer"]["records"] > 0, (
            "the batch was neither stored nor buffered -- it was lost"
        )

    with subtest("the buffered batch lands once the clock is disciplined"):
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

        # The flush is driven by the collector noticing sync, not by anything the driver does,
        # so this is a wait rather than a read.
        retry(lambda _: len(query("limit=200")) > 0)
        assert collector_health()["buffer"]["records"] == 0, "the buffer did not drain"

        # Flushed because the clock became good, not because the 300 s cap expired -- the
        # difference between a re-dated sample and one shipped with a shrug.
        held = query("type=system.memory&limit=10")
        assert held, "the held batch never arrived"
        uncertain = held[0]["attributes"].get("record.attributes.mp.clock.uncertain")
        assert uncertain in (None, False, "false"), (
            f"the batch was flushed on timeout rather than on sync: {held[0]['attributes']}"
        )
        # Proof the hop happened at all: these attributes are the collector's, and a producer
        # posting straight at the receiver could not have produced them.
        assert any(
            k.startswith("record.attributes.mp.clock.") for k in held[0]["attributes"]
        ), f"the batch did not travel through the collector: {held[0]['attributes']}"

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
        # The batch this run added, not the whole store: the pre-sync batch above is still in
        # there, and every assertion from here to the end of the file is about ONE batch (the
        # root-filesystem count especially, which is exactly 1 per run).
        measurements = collect_batch()
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
        generation = bodies(collect_batch(), "system.generation")[0]
        assert generation["current"] == 1, generation

    with subtest("each run appends a new batch instead of overwriting the last"):
        before = query("type=system.memory&limit=10")
        collect_batch("type=system.memory&limit=10")
        after = query("type=system.memory&limit=10")
        assert len(after) == len(before) + 1, (len(before), len(after))
        # Ordered event_time DESC, so the newest is first and must be strictly newer.
        assert int(after[0]["event_time_unix_nano"]) > int(before[0]["event_time_unix_nano"])

    with subtest("losing NTP after a good sync does not stop recording"):
        # The inverse of what this host used to do, and deliberately so (design 8.2). Nothing
        # steps when a time source disappears: the clock free-runs on the local oscillator and
        # drifts by parts per million, so the error bound grows while the actual error stays in
        # the milliseconds. Withholding telemetry on that signal would blank the record during
        # a network outage -- exactly when it is most wanted -- to avoid an error smaller than
        # the transmission delay.
        ntp.succeed("systemctl stop chronyd.service")
        machine.succeed("systemctl restart systemd-timesyncd.service")
        machine.wait_until_fails(f"test -e {MARKER}", timeout=60)

        # collect_batch waits for the store to grow, so its returning at all is the assertion:
        # a withheld run would time out here.
        assert collect_batch("type=system.memory&limit=20"), (
            "a run with a free-running clock must still be recorded"
        )

        ntp.succeed("systemctl start chronyd.service")
        machine.succeed("systemctl restart systemd-timesyncd.service")
        machine.wait_for_file(MARKER)

    with subtest("a collector that is down fails the run instead of skipping it"):
        # There is deliberately no ConditionPathExists on the socket: a condition would mark
        # the unit green and the measurements would simply stop, silently and forever. The
        # target of this assertion moved with the socket -- the producer's only hop is the
        # collector now, and a receiver that is down is the collector's problem to buffer
        # through (upstream's collector-clock case covers that, against this same host config).
        machine.succeed("systemctl stop mp-collector.socket mp-collector.service")
        machine.succeed("systemctl reset-failed system-metrics.service")
        machine.fail("systemctl start system-metrics.service")
        assert "cannot reach" in machine.succeed(
            "journalctl -b -u system-metrics.service -o cat"
        ), "an unreachable collector should be named in the journal"

        machine.succeed("systemctl start mp-collector.socket mp-collector.service")
        machine.wait_for_unit("mp-collector.service")
        collect()
  '';
}
