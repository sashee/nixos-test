{ nixpkgs, pkgs, machineModule, stateVersion, globalTimeout ? 600 }:

let
  # A stand-in for smartctl. Nothing in a QEMU guest exposes SMART -- virtio disks have none --
  # and neither does the Pi, whose SD card `smartctl --scan-open` reports as no devices at all.
  # So a fake is not a shortcut here, it is the only way either branch of the drive record is
  # ever exercised: the SATA half in particular has no hardware in this fleet to run against.
  smartFixture = name: value: pkgs.writeText "smart-${name}.json" (builtins.toJSON value);

  scanJson = smartFixture "scan" {
    devices = [
      { name = "/dev/nvme0"; type = "nvme"; }
      { name = "/dev/sda"; type = "sat"; }
    ];
  };

  nvmeJson = smartFixture "nvme" {
    device = { name = "/dev/nvme0"; type = "nvme"; protocol = "NVMe"; };
    model_name = "FAKE-NVME-1TB";
    serial_number = "NVME-SERIAL-1";
    smart_status.passed = true;
    power_on_time.hours = 4321;
    nvme_smart_health_information_log = {
      critical_warning = 0;
      available_spare = 100;
      percentage_used = 3;
      media_errors = 0;
      unsafe_shutdowns = 41;
    };
  };

  # `when_failed` set on two attributes, and ids 187/188 absent entirely: a drive that
  # implements only part of the table is the normal case, not an error, and it is what makes
  # the difference between a real zero and an unimplemented attribute testable.
  sataJson = smartFixture "sata" {
    device = { name = "/dev/sda"; type = "sat"; protocol = "ATA"; };
    model_name = "FAKE-SATA-SSD";
    serial_number = "SATA-SERIAL-2";
    smart_status.passed = false;
    power_on_time.hours = 19004;
    ata_smart_attributes.table = [
      { id = 5; name = "Reallocated_Sector_Ct"; when_failed = ""; raw.value = 0; }
      { id = 12; name = "Power_Cycle_Count"; when_failed = ""; raw.value = 1183; }
      { id = 197; name = "Current_Pending_Sector"; when_failed = "now"; raw.value = 8; }
      { id = 199; name = "UDMA_CRC_Error_Count"; when_failed = "past"; raw.value = 2; }
    ];
  };

  fakeSmartctl = pkgs.writeShellScriptBin "smartctl" ''
    if [[ "$*" == *--scan-open* ]]; then
      cat ${scanJson}
    elif [[ "$*" == */dev/nvme0* ]]; then
      cat ${nvmeJson}
    else
      cat ${sataJson}
    fi
  '';

  # Logs at four known priorities so the journal counts have something deterministic to count.
  # A unit rather than `systemd-cat` from the driver, because only a unit gives a predictable
  # `_SYSTEMD_UNIT` -- and that is the attribute the record is keyed by. systemd reads the
  # `<N>` prefixes as priorities.
  noisyScript = pkgs.writeShellScript "test-noisy" ''
    echo "<4>a warning"
    echo "<3>an error"
    echo "<3>another error"
    echo "<2>something critical"
  '';
in

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

    common.systemMetrics = {
      # A guest has essentially no hwmon, so the sweep would find nothing and every sensor
      # assertion would be vacuous. The tree is built by the driver, which is what lets it hold
      # the shapes that matter and that no single real machine has all of: a chip with no
      # `_label`, two chips sharing a `name`, and both `_alarm` spellings.
      hwmonRoot = "/run/fixture-hwmon";
      # There is no /etc/nixos in a VM, so the deployed default would leave the three common_*
      # fields null and untested. This fixture is the shape the real stubs produce -- note it
      # pins no branch, so `common_ref` is null on the hosts too.
      flakeLock.path = "/etc/fixture-flake.lock";
      smart = {
        enable = true;
        package = fakeSmartctl;
      };
      # irohSsh is force-disabled above, so this would default off. Enabled explicitly because
      # the firewall half is real: the chain, the tagged rule and the CAP_NET_ADMIN needed to
      # read them all behave exactly as they do on the Pi.
      irohFailsafe.enable = true;
      # Two timers of this test's own rather than the host's real ones: the point is the
      # difference between a timer that has a next run and one that never will, and pinning that
      # to whatever nix-gc happens to be scheduled for would make it a test of another feature.
      timers = [ "test-scheduled.timer" "test-boot-only.timer" "test-monotonic.timer" ];
    };
    environment.etc."fixture-flake.lock".text = builtins.toJSON {
      nodes.common = {
        locked = {
          lastModified = 1786191634;
          owner = "sashee";
          repo = "nixos-test";
          rev = "8b3741955a446de07c0a9ae74c0a9c72421b6242";
          type = "github";
        };
        original = { owner = "sashee"; repo = "nixos-test"; type = "github"; };
      };
      root = "root";
      version = 7;
    };

    # Fails once and stays failed: the unit record must pick it up WITHOUT it being listed,
    # which is the whole point of also reporting whatever is currently failing.
    systemd.services.test-broken = {
      description = "A unit that fails";
      serviceConfig = { Type = "oneshot"; ExecStart = "${pkgs.coreutils}/bin/false"; };
    };

    # Fails in a loop. It never settles into `failed` -- it sits in activating/auto-restart --
    # so this is the case that `n_restarts` exists for and that a plain `is-active` check misses.
    systemd.services.test-flapping = {
      description = "A unit that restarts forever";
      serviceConfig = {
        ExecStart = "${pkgs.coreutils}/bin/false";
        Restart = "always";
        RestartSec = "1s";
      };
      # systemd would otherwise give up after 5 starts in 10s and park the unit in `failed`,
      # which is precisely the state this is meant NOT to be in. A [Unit] setting, not [Service].
      unitConfig.StartLimitIntervalSec = 0;
      wantedBy = [ "multi-user.target" ];
    };

    systemd.services.test-noisy = {
      description = "A unit that logs at known priorities";
      serviceConfig = { Type = "oneshot"; ExecStart = noisyScript; };
    };

    # Deliberately NOT test-noisy: the timer below fires at boot, and a second run of the noisy
    # unit would double every count the journal subtest asserts.
    systemd.services.test-noop = {
      description = "Does nothing, quietly";
      serviceConfig = { Type = "oneshot"; ExecStart = "${pkgs.coreutils}/bin/true"; };
    };

    # A timer with no next elapse once it has fired: `OnBootSec` only, exactly like
    # connectivity-fallback-check on the Pi, where `NextElapseUSecMonotonic` reads `infinity`
    # and the realtime side is empty. Normal operation, and it must land as a null rather than
    # as a failure.
    systemd.timers.test-boot-only = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "1s"; AccuracySec = "1s"; Unit = "test-noop.service"; };
    };

    # A monotonic timer that has NOT yet elapsed. systemd reports its next elapse as a timespan
    # (`59min 12.3s`) rather than as an integer, unlike the calendar timer below -- and most of
    # the real timers on these hosts are this kind, so the two cases above between them missed
    # the shape that matters most.
    systemd.timers.test-monotonic = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "1h"; Unit = "test-noop.service"; };
    };

    # The ordinary case: a calendar timer always has a next elapse, so this is the value half of
    # the pair above. `Persistent = false` keeps it from firing at boot on a guest whose clock
    # starts in the future.
    systemd.timers.test-scheduled = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 04:00:00";
        Persistent = false;
        Unit = "test-noop.service";
      };
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


    # Every row in the store. A batch is now ~45 records and the assertions below collect
    # several times, so a limit sized for the old five-record batch would silently cap the
    # query and make the delta below come out empty.
    ALL = "limit=5000"


    def collect_batch(params=ALL):
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


    def by_attr(measurements, kind, attribute, wanted):
        return [
            m for m in measurements
            if m["type"] == kind
            and m["attributes"].get(f"record.attributes.{attribute}") == wanted
        ]


    def build_hwmon_fixture():
        # Reproduces the shapes measured on the two real machines, which no single one of them
        # has all of. Two chips are deliberately both named "nvme": their records are otherwise
        # identical, and only the `device` attribute tells the drives apart.
        machine.succeed(
            "mkdir -p /run/fixture-hwmon/hwmon0 /run/fixture-hwmon/hwmon1 "
            "/run/fixture-hwmon/hwmon2 /run/fixture-hwmon/devices/thermal_zone0 "
            "/run/fixture-hwmon/devices/nvme0 /run/fixture-hwmon/devices/nvme1",
            # hwmon0: the Pi's cpu_thermal -- no label at all, which is the case that would make
            # a label-keyed implementation report nothing on the Pi.
            "echo cpu_thermal > /run/fixture-hwmon/hwmon0/name",
            "echo 58950 > /run/fixture-hwmon/hwmon0/temp1_input",
            "ln -sfn ../devices/thermal_zone0 /run/fixture-hwmon/hwmon0/device",
            # Files that share the directory and must not be swept in.
            "echo 'JUNK=1' > /run/fixture-hwmon/hwmon0/uevent",
            "echo 3210 > /run/fixture-hwmon/hwmon0/temp1_raw",
            # hwmon1: labelled, with both alarm spellings on one chip.
            "echo nvme > /run/fixture-hwmon/hwmon1/name",
            "echo Composite > /run/fixture-hwmon/hwmon1/temp1_label",
            "echo 42850 > /run/fixture-hwmon/hwmon1/temp1_input",
            "echo 0 > /run/fixture-hwmon/hwmon1/temp1_alarm",
            "echo 1 > /run/fixture-hwmon/hwmon1/in0_lcrit_alarm",
            "ln -sfn ../devices/nvme0 /run/fixture-hwmon/hwmon1/device",
            # hwmon2: same `name` as hwmon1, different device.
            "echo nvme > /run/fixture-hwmon/hwmon2/name",
            "echo 51000 > /run/fixture-hwmon/hwmon2/temp1_input",
            "ln -sfn ../devices/nvme1 /run/fixture-hwmon/hwmon2/device",
        )


    MARKER = "/run/systemd/timesync/synchronized"


    def unix_seconds(node):
        return int(node.succeed("date +%s").strip())


    start_all()
    machine.wait_for_unit("multi-user.target")
    build_hwmon_fixture()
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

        # The spec's cadence, "every 15 minutes and 5 minutes after boot". Nothing else here
        # sees it: every other assertion in this file drives the producer by hand, so a timer
        # that had drifted to daily would pass the whole suite and simply stop measuring the
        # hosts. Read off the rendered timer, because the claim is that systemd was told.
        timer = machine.succeed("systemctl cat system-metrics.timer")
        assert "OnBootSec=5m" in timer, timer
        assert "OnUnitActiveSec=15m" in timer, timer
        # A measurement describes the moment it was taken, so a run missed while the host was
        # off must not be caught up later under a past timestamp.
        assert "Persistent=" not in timer, timer
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
        retry(lambda _: len(query(ALL)) > 0)
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

    with subtest("the states the later subtests measure are reached first"):
        # Every record type has to be reachable before --dry-run is compared against a real
        # batch, or the two would legitimately disagree about which types exist.
        machine.fail("systemctl start test-broken.service")
        machine.succeed("systemctl start test-noisy.service")
        machine.wait_until_succeeds(
            "journalctl -u test-noisy.service -p err --no-pager | grep -q 'an error'"
        )
        # Restart=always with no start limit, so this climbs on its own and never settles into
        # `failed` -- the state a plain is-active check reads as merely "not running".
        machine.wait_until_succeeds(
            "test \"$(systemctl show -p NRestarts --value test-flapping.service)\" -ge 2"
        )

    with subtest("the operator can inspect a batch without sending it"):
        # Same flags as the unit, so this is what the next tick would post -- and it must not
        # reach the receiver, which the row count below confirms.
        before = len(query(ALL))
        planned = machine.succeed("system-metrics --dry-run")
        assert len(query(ALL)) == before, "--dry-run must not store anything"
        planned_types = {
            line.split()[1] for line in planned.splitlines() if line.startswith("record ")
        }
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
            "system.drive",
            "system.drive.nvme",
            "system.drive.sata",
            "system.generation",
            "system.host",
            "system.iroh_failsafe",
            "system.sensor",
            "system.unit",
            "system.timer",
            "system.journal",
        }, f"unexpected measurement types: {sorted(types)}"
        # Sets, not sorted lists: the record COUNT is no longer fixed, because how many units are
        # failing and how many units logged in the window both vary between two runs seconds
        # apart. What must hold is that --dry-run describes the same kinds of measurement the
        # batch actually carries.
        assert types == planned_types, (
            f"--dry-run predicted {sorted(planned_types)}, the batch carried {sorted(types)}"
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
        # zram is on in the deployed config, so both of these describe a device that exists.
        # They measure different things: the total is the uncompressed capacity swap sees, the
        # memory figure is what those pages actually cost in RAM.
        assert memory["zramswap_total_bytes"] > 0, memory
        assert memory["zramswap_memory_bytes"] < memory["zramswap_total_bytes"], memory
        # A counter, so the only safe claim is that it was read at all rather than nulled.
        assert memory["oom_kill"] is not None and memory["oom_kill"] >= 0, memory

        cpu = bodies(measurements, "system.cpu")[0]
        assert cpu["cores"] >= 1, cpu
        assert 0.0 <= cpu["utilization_percent"] <= 100.0, cpu
        assert cpu["load1"] >= 0.0, cpu

        host = bodies(measurements, "system.host")[0]
        assert host["uptime_seconds"] > 0, host
        assert host["kernel_release"], host

    with subtest("a value that cannot be read is null, and the key stays"):
        # The whole reason nothing is omitted: one stable key set per measurement type, so
        # "this host has no such fact" and "the schema changed" can never look alike. Asserted
        # on the exact set rather than on one field, because it is the shape that has to hold.
        host = bodies(measurements, "system.host")[0]
        assert set(host) == {
            "uptime_seconds",
            "kernel_release",
            "nixos_version",
            "common_commit_id",
            "common_last_modified",
            "common_ref",
        }, host

    with subtest("the deployed source revision is read out of the flake lock"):
        host = bodies(measurements, "system.host")[0]
        assert host["common_commit_id"] == "8b3741955a446de07c0a9ae74c0a9c72421b6242", host
        assert host["common_last_modified"] == 1786191634, host
        # The fixture pins no branch, exactly as the real stubs do not -- so this is the null
        # case, and a required field here would fail every run on the Pi.
        assert host["common_ref"] is None, host

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
        assert 0 < roots[0]["body"]["available_bytes"] <= roots[0]["body"]["total_bytes"]

        fstypes = {m["attributes"]["record.attributes.fstype"] for m in filesystems}
        excluded = {"tmpfs", "devtmpfs", "proc", "sysfs", "9p", "virtiofs", "erofs"}
        assert not (fstypes & excluded), f"excluded types were reported: {fstypes & excluded}"

    with subtest("one disk is one record, however many times it is mounted"):
        # /nix/store is a read-only bind of the root filesystem and reports the same f_fsid, so
        # without the fsid check the same disk would be counted twice in every batch.
        machine.succeed("mkdir -p /run/bind-of-root && mount --bind / /run/bind-of-root")
        try:
            filesystems = [
                m for m in collect_batch() if m["type"] == "system.filesystem"
            ]
            mountpoints = [
                m["attributes"]["record.attributes.mountpoint"] for m in filesystems
            ]
            assert "/run/bind-of-root" not in mountpoints, (
                f"a bind mount of / was reported as a second filesystem: {mountpoints}"
            )
        finally:
            machine.succeed("umount /run/bind-of-root")

    with subtest("the size figures agree with df rather than inventing their own"):
        # `df` reports 1K blocks; the record reports bytes off the same statvfs, so the two must
        # agree to within a block or the wrong unit is being used for the block count.
        df_total_kb = int(
            machine.succeed("df --output=size / | tail -1 | tr -dc 0-9").strip()
        )
        reported = roots[0]["body"]["total_bytes"]
        assert abs(reported - df_total_kb * 1024) <= 4096, f"{reported} vs df's {df_total_kb}K"

    with subtest("every measurement identifies the host and the boot that produced it"):
        for m in measurements:
            attributes = m["attributes"]
            assert attributes["resource.attributes.host.name"] == "system-metrics-test", m
            assert attributes["resource.attributes.service.name"] == "system-metrics", m
            assert attributes["scope.name"] == "system-metrics", m
            # Grouping samples by boot is otherwise arithmetic on uptime across a 15-minute
            # sampling grid, which cannot tell a reboot from a gap in collection.
            assert attributes["resource.attributes.boot_id"], m
        boot_id = machine.succeed("cat /proc/sys/kernel/random/boot_id").strip()
        assert measurements[0]["attributes"]["resource.attributes.boot_id"] == boot_id

    with subtest("every hwmon sensor is reported, whatever the chip calls itself"):
        sensors = [m for m in measurements if m["type"] == "system.sensor"]
        readings = {
            (
                m["attributes"]["record.attributes.chip"],
                m["attributes"]["record.attributes.device"],
                m["attributes"]["record.attributes.sensor"],
                m["attributes"]["record.attributes.kind"],
            ): m
            for m in sensors
        }

        # A chip with no _label file at all -- the Pi's shape, and the one that a
        # label-keyed implementation would silently drop every sensor on.
        unlabelled = readings[("cpu_thermal", "thermal_zone0", "temp1", "temp")]
        assert unlabelled["body"]["milli_celsius"] == 58950, unlabelled
        assert unlabelled["attributes"]["record.attributes.label"] is None, unlabelled
        assert unlabelled["attributes"]["record.attributes.threshold"] is None, unlabelled

        labelled = readings[("nvme", "nvme0", "temp1", "temp")]
        assert labelled["body"]["milli_celsius"] == 42850, labelled
        assert labelled["attributes"]["record.attributes.label"] == "Composite", labelled

        # Two chips with the SAME name: only `device` tells the drives apart, which is why the
        # hwmonN index (unstable across boots) is not what identifies a chip.
        second = readings[("nvme", "nvme1", "temp1", "temp")]
        assert second["body"]["milli_celsius"] == 51000, second

        # The junk that shares an hwmon directory. `temp1_raw` is a driver-specific ADC count
        # with no unit; sweeping "every file" would report it as though it meant something.
        assert not [
            m for m in sensors
            if m["attributes"]["record.attributes.sensor"] not in ("temp1", "in0")
        ], sensors

    with subtest("both spellings of an hwmon alarm are reported as one shape"):
        # The laptop's over-temperature flag has no threshold segment; the Pi's undervoltage
        # flag does. Both must land as the same record shape with a boolean body.
        plain = by_attr(measurements, "system.sensor", "sensor", "temp1")
        plain = [m for m in plain if m["attributes"]["record.attributes.kind"] == "alarm"]
        assert len(plain) == 1, plain
        assert plain[0]["body"]["triggered"] is False, plain
        assert plain[0]["attributes"]["record.attributes.threshold"] is None, plain

        thresholded = by_attr(measurements, "system.sensor", "sensor", "in0")
        assert len(thresholded) == 1, thresholded
        assert thresholded[0]["body"]["triggered"] is True, thresholded
        assert thresholded[0]["attributes"]["record.attributes.threshold"] == "lcrit", thresholded
        assert thresholded[0]["attributes"]["record.attributes.kind"] == "alarm", thresholded

    with subtest("a failing unit is reported whether or not anyone listed it"):
        # test-broken is in no watch list. Being failed is what puts it in the batch, which is
        # what makes the watch list about units whose health matters while they look fine.
        broken = by_attr(measurements, "system.unit", "unit", "test-broken.service")
        assert len(broken) == 1, f"a failed unit went unreported: {broken}"
        assert broken[0]["body"]["active_state"] == "failed", broken
        assert broken[0]["body"]["result"] == "exit-code", broken

        # A crash loop never reaches `failed`; it sits in activating/auto-restart, so the count
        # of restarts is the only thing that distinguishes it from a healthy unit.
        flapping = by_attr(measurements, "system.unit", "unit", "test-flapping.service")
        assert len(flapping) == 1, f"a restart-looping unit went unreported: {flapping}"
        assert flapping[0]["body"]["n_restarts"] >= 2, flapping
        assert flapping[0]["body"]["active_state"] != "failed", flapping

    with subtest("the watch list is derived from the features this host enables"):
        # The default list is built by reading other modules' options, each of which has to be
        # guarded because this module is also imported by configurations that enable none of
        # them. A guard that swallowed too much would leave the list empty -- and every other
        # assertion here would still pass, because they name units this test defines itself.
        watched = {
            m["attributes"]["record.attributes.unit"]
            for m in measurements if m["type"] == "system.unit"
        }
        # From common.connectivityWatchdog and common.connectivityFallback -- `common.*`
        # options reached through the guard. (Not common.timeSync: this node forces time
        # synchronisation off, so its units correctly do not appear.)
        assert "connectivity-watchdog.service" in watched, watched
        assert "connectivity-fallback-check.service" in watched, watched
        # From services.dnscrypt-proxy and nix.gc, nixpkgs options read directly.
        assert "dnscrypt-proxy.service" in watched, watched
        assert "nix-gc.service" in watched, watched

    with subtest("a watched unit reports its state and its last success separately"):
        collector = by_attr(measurements, "system.unit", "unit", "mp-collector.service")
        assert len(collector) == 1, collector
        assert collector[0]["body"]["active_state"] == "active", collector
        assert collector[0]["body"]["active_enter_seconds_ago"] >= 0, collector
        # No marker is written for it, so the field is null rather than absent.
        assert collector[0]["body"]["last_success_seconds_ago"] is None, collector

        # The marker monitoring.nix writes from the monitored unit's own OnSuccess. It is a
        # different fact from `active_enter_seconds_ago`: a unit that has failed every run for a
        # week still has a recent activation, and only this says it never succeeded.
        machine.succeed(
            "mkdir -p /var/lib/common-monitoring",
            "echo $(($(date +%s) - 600)) > /var/lib/common-monitoring/mp-collector.service.last-success",
            "chmod 0644 /var/lib/common-monitoring/mp-collector.service.last-success",
        )
        collector = by_attr(collect_batch(), "system.unit", "unit", "mp-collector.service")
        assert 550 < collector[0]["body"]["last_success_seconds_ago"] < 900, collector

    with subtest("a timer with no next elapse is null, not a failure"):
        # A calendar timer always has a next run, and systemd reports it in realtime.
        scheduled = by_attr(measurements, "system.timer", "unit", "test-scheduled.timer")
        assert len(scheduled) == 1, scheduled
        assert scheduled[0]["body"]["next_elapse_seconds_until"] is not None, scheduled
        assert scheduled[0]["body"]["next_elapse_seconds_until"] > 0, scheduled

        # A monotonic timer still waiting to fire. systemd renders its next elapse as a timespan
        # ("59min 12.3s"), not as an integer -- the shape that made every OnBootSec and
        # OnUnitActiveSec timer on the Pi report no schedule at all while calendar timers looked
        # fine. Set to an hour, so the bound below also catches a unit mix-up.
        monotonic = by_attr(measurements, "system.timer", "unit", "test-monotonic.timer")
        assert len(monotonic) == 1, monotonic
        remaining = monotonic[0]["body"]["next_elapse_seconds_until"]
        assert remaining is not None, monotonic
        assert 0 < remaining <= 3600, monotonic

        # test-boot-only fires once per boot and never rearms -- systemd reports `infinity` for
        # the monotonic side and nothing for the realtime one. Normal operation on the Pi, where
        # connectivity-fallback-check does exactly this, so it must not read as broken.
        elapsed = by_attr(measurements, "system.timer", "unit", "test-boot-only.timer")
        assert len(elapsed) == 1, elapsed
        assert elapsed[0]["body"]["next_elapse_seconds_until"] is None, elapsed

    with subtest("journal counts are per unit and per severity"):
        noisy = by_attr(measurements, "system.journal", "unit", "test-noisy.service")
        assert len(noisy) == 1, f"a unit that logged errors was not counted: {noisy}"
        assert noisy[0]["body"] == {"warning": 1, "err": 2, "crit": 1}, noisy

        # Quiet units produce no record at all, which is what keeps this from being 300 rows of
        # zeroes every fifteen minutes.
        assert not by_attr(measurements, "system.journal", "unit", "mp-collector.service"), (
            "a unit that logged nothing should not produce a journal record"
        )

    with subtest("SMART is split by drive family, and the shared record carries only what both have"):
        nvme = by_attr(measurements, "system.drive", "sn", "NVME-SERIAL-1")
        assert len(nvme) == 1, nvme
        assert nvme[0]["body"]["passed"] is True, nvme
        assert nvme[0]["body"]["power_on_hours"] == 4321, nvme
        assert nvme[0]["attributes"]["record.attributes.kind"] == "nvme", nvme
        assert nvme[0]["attributes"]["record.attributes.model"] == "FAKE-NVME-1TB", nvme

        health = by_attr(measurements, "system.drive.nvme", "sn", "NVME-SERIAL-1")
        assert len(health) == 1, health
        assert health[0]["body"]["percentage_used"] == 3, health
        assert health[0]["body"]["available_spare"] == 100, health

        sata = by_attr(measurements, "system.drive", "sn", "SATA-SERIAL-2")
        assert sata[0]["body"]["passed"] is False, sata
        assert sata[0]["attributes"]["record.attributes.kind"] == "sata", sata

        attributes = by_attr(measurements, "system.drive.sata", "sn", "SATA-SERIAL-2")[0]["body"]
        assert attributes["reallocated_sector_ct"] == 0, attributes
        assert attributes["current_pending_sector"] == 8, attributes
        # Not implemented by this drive: null, and distinguishable from a real zero above.
        assert attributes["reported_uncorrect"] is None, attributes
        assert attributes["command_timeout"] is None, attributes
        # The catch-all, which counts attributes this producer never names.
        assert attributes["failing_now"] == 1, attributes
        assert attributes["failed_past"] == 1, attributes

        # A drive family never contributes to the other's record.
        assert not by_attr(measurements, "system.drive.sata", "sn", "NVME-SERIAL-1")
        assert not by_attr(measurements, "system.drive.nvme", "sn", "SATA-SERIAL-2")

    with subtest("port 22 is reported closed until the failsafe opens it"):
        failsafe = bodies(measurements, "system.iroh_failsafe")[0]
        assert failsafe["port_22_open"] is False, failsafe
        assert failsafe["last_engaged_seconds_ago"] is None, failsafe

        # Exactly what the failsafe itself inserts. There is no static 22-accept anywhere, so
        # the tagged rule is the only thing that can make this true -- reading it needs
        # CAP_NET_ADMIN, which the sandbox grants only because this record is enabled.
        machine.succeed(
            "nft insert rule inet nixos-fw input-allow tcp dport 22 accept "
            "comment \"iroh-ssh-failsafe\"",
            "mkdir -p /var/lib/iroh-ssh-failsafe",
            "echo $(($(date +%s) - 120)) > /var/lib/iroh-ssh-failsafe/last-engaged",
            "chmod 0644 /var/lib/iroh-ssh-failsafe/last-engaged",
        )
        failsafe = bodies(collect_batch(), "system.iroh_failsafe")[0]
        assert failsafe["port_22_open"] is True, failsafe
        assert 60 < failsafe["last_engaged_seconds_ago"] < 400, failsafe

    with subtest("the generation number appears once a system profile exists"):
        # A VM never runs nixos-rebuild, so there is no /nix/var/nix/profiles/system yet and
        # the collector reports `current` as null rather than inventing a 0 -- which would be a
        # perfectly plausible generation number.
        generation = bodies(measurements, "system.generation")[0]
        assert "current" in generation and generation["current"] is None, generation
        assert generation["count"] == 0, generation

        machine.succeed("nix-env -p /nix/var/nix/profiles/system --set /run/current-system")
        generation = bodies(collect_batch(), "system.generation")[0]
        assert generation["current"] == 1, generation
        # A different fact from the generation number: how many are being retained, which is
        # what grows without bound when garbage collection stops.
        assert generation["count"] == 1, generation

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
