{ nixpkgs, pkgs, machineModule, stateVersion, globalTimeout ? 2400 }:

let
  irohSsh = pkgs.callPackage ../packages/iroh-ssh/package.nix { };
  recorder = import ./thingspeak/recorder.nix { inherit pkgs; };

  # Not the eight production entries, which would mean emulating an inverter and a BMS over two
  # QEMU serial chardevs to put a single number in the store. The reporter does not know or care
  # which producer wrote a record, so system-metrics -- which runs on any node and can be
  # triggered on demand -- is a faithful stand-in for what it reads.
  #
  # The production list is asserted separately, by the `thingspeak-measurements` eval check: what
  # matters about it is the order, which is the ThingSpeak field numbering, and that is a
  # property of the configuration rather than of a running system.
  #
  # `no_such_reading` is deliberate. Its absence from every record is what proves a missing
  # reading becomes an omitted field rather than a zero -- and that the numbering is positional,
  # so field6 stays field6 with field5 gone.
  testMeasurements = [
    { type = "system.cpu"; field = "load1"; }
    { type = "system.cpu"; field = "cores"; }
    { type = "system.memory"; field = "total_bytes"; }
    { type = "system.memory"; field = "free_bytes"; }
    { type = "system.cpu"; field = "no_such_reading"; }
    { type = "system.memory"; field = "swap_total_bytes"; }
  ];
in
nixpkgs.lib.nixos.runTest {
  name = "thingspeak";
  hostPkgs = pkgs;
  skipTypeCheck = true;
  # Ceiling, not a wait. Several subtests have to wait out an interval boundary -- the window a
  # run reads is the *previous* whole interval -- and the aarch64 leg does that under TCG.
  inherit globalTimeout;

  # api.thingspeak.com, as far as the node under test is concerned. Plain HTTP because the
  # endpoint is an option; see tests/thingspeak/recorder.nix for why that beats intercepting TLS
  # for the real hostname.
  nodes.thingspeak = { ... }: {
    networking.hostName = "thingspeak";
    networking.firewall.allowedTCPPorts = [ 8080 ];
    virtualisation.memorySize = 512;
    systemd.services.thingspeak-recorder = {
      description = "Recording stand-in for api.thingspeak.com";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${recorder}";
        StateDirectory = "thingspeak-recorder";
      };
    };
    system.stateVersion = stateVersion;
  };

  nodes.machine = { config, lib, ... }: {
    imports = [ machineModule ];

    networking.hostName = "thingspeak-host";
    common.autoUpgrade.enable = lib.mkForce false;
    common.monitoring.enable = lib.mkForce false;
    common.irohSsh.enable = lib.mkForce false;
    # No serial adapters in a guest, and no radios either. None of the three is what is under
    # test: the reporter reads whatever is in the store, and system-metrics can put records
    # there on demand without emulating any hardware.
    common.inverterMonitoring.enable = lib.mkForce false;
    common.bmsMonitoring.enable = lib.mkForce false;
    common.detectedDevices.enable = lib.mkForce false;

    # No time daemon runs on a test node (testNodeTimeSyncOff), so the collector holds every
    # batch for bufferTimeoutSecs before shipping it flagged rather than letting it out stamped
    # from an unknown frame. At the 300s default that gate would dominate this file; two seconds
    # keeps it in the path without spending five minutes per record.
    services.mp-collector.bufferTimeoutSecs = 2;

    common.thingspeak = {
      updateUrl = "http://thingspeak:8080/update";
      measurements = testMeasurements;
      # Straight at the receiver, bypassing this module's own iroh hop: reaching it needs a
      # relay and endpoint-id discovery, which is an entire impersonated n0 that
      # tests/monitoring-platform-tunnel.nix builds for the same binary. What that suite proves
      # about iroh-uds-connect holds here; what is left for this one is the reporter, so the
      # socket it reads is the one the receiver already serves.
      platform.socketPath = config.services.monitoring-platform.socketPath;
      platform.socketGroup = config.services.monitoring-platform.group;
    };

    system.stateVersion = stateVersion;
  };

  # Concatenated rather than interpolated: `''` strips each literal's own indentation, so a
  # `${...}` inside the helper string would dedent its function bodies out of their own `def`s.
  testScript = (import ../lib/test-mp-auth.nix) + ''
    import json
    import re
    import urllib.parse

    RECEIVER = "/run/monitoring-platform/monitoring-platform.sock"
    PLATFORM_CRED = "/etc/credentials/thingspeak/platform"
    CHANNEL_CRED = "/etc/credentials/thingspeak/channel"
    TUNNEL_CRED = "/etc/credentials/thingspeak/tunnel"
    TUNNEL_SOCKET = "/run/thingspeak-tunnel/upstream.sock"
    # hosts/rpi5 points the gate at chrony's marker, and no chrony runs on a test node -- so
    # creating and removing this file by hand is how the gate itself gets tested rather than
    # switched off.
    MARKER = "/run/chrony-wait/synchronized"
    RECORDER_STATE = "/var/lib/thingspeak-recorder"
    LOG = f"{RECORDER_STATE}/requests.log"
    CHANNEL_KEY = "TSWRITEKEY0000000000"


    def sent_requests():
        return [
            line for line in thingspeak.succeed(f"cat {LOG}").splitlines() if line.strip()
        ]


    def query_of(line):
        # "POST /update?api_key=...&created_at=...&field1=..." -- everything worth asserting on
        # is in the query string, because that is where the spec puts it.
        assert "?" in line, f"no query string in the recorded request: {line!r}"
        return dict(urllib.parse.parse_qsl(line.split("?", 1)[1]))


    def measurements(params):
        raw = machine.succeed(
            f"curl -sS --fail-with-body {auth_header()}--unix-socket {RECEIVER} "
            f"'http://localhost/v1/measurements?{params}'"
        )
        return json.loads(raw)["measurements"]


    def produce():
        # A oneshot started back to back trips systemd's start rate limit, which fails the start
        # rather than running the unit.
        machine.succeed("systemctl reset-failed system-metrics.service")
        machine.succeed("systemctl start system-metrics.service")


    def run_reporter():
        machine.succeed("systemctl reset-failed thingspeak.service")
        return machine.execute("systemctl start thingspeak.service")[0]


    def report():
        """Drive runs until one actually posts; return its query parameters and exit status.

        The window a run reads is the *previous* whole interval, so a record produced now is
        invisible until the next boundary and invisible again after the one after it. There is
        therefore no single moment at which one run is guaranteed to have something to send.
        Producing on every attempt is what keeps a record inside whichever window the next run
        reads, instead of waiting on a boundary this test cannot observe.
        """
        before = len(sent_requests())
        for _ in range(80):
            produce()
            status = run_reporter()
            lines = sent_requests()
            if len(lines) > before:
                return query_of(lines[-1]), status
            machine.sleep(2)
        raise Exception("the reporter never posted anything")


    thingspeak.start()
    thingspeak.wait_for_unit("thingspeak-recorder.service")
    thingspeak.wait_until_succeeds(
        "${pkgs.curl}/bin/curl -sS --fail http://localhost:8080/healthz", timeout=60
    )
    # So the readers below can `cat` it before the first report rather than special-casing an
    # absent file.
    thingspeak.succeed(f"touch {LOG}")

    machine.start()
    machine.wait_for_unit("multi-user.target")
    # Type=notify on both, so `active` means each socket is bound and accepting.
    machine.wait_for_unit("mp-collector.service")
    machine.wait_for_unit("monitoring-platform.service")

    # Before anything has been produced: this restarts the collector, and a restart discards its
    # outbox.
    authenticate(machine)

    # Every subtest below asserts on what one run did, and the timer would run the reporter
    # underneath them. Stopped rather than masked, so the timer's own wiring stays assertable.
    machine.succeed("systemctl stop thingspeak.timer")

    with subtest("the reporter is credential-gated, group-scoped and sandboxed"):
        unit = machine.succeed("systemctl cat thingspeak.service")
        assert f"LoadCredentialEncrypted=mp-api-key:{PLATFORM_CRED}/mp-api-key" in unit, unit
        assert (
            f"LoadCredentialEncrypted=thingspeak-key:{CHANNEL_CRED}/thingspeak-key" in unit
        ), unit
        # No identity and no state; the one privilege it has is the group gating the socket it
        # reads, which is the actual access control on that 0750 directory.
        assert "DynamicUser=true" in unit, unit
        assert "SupplementaryGroups=monitoring-platform" in unit, unit
        assert "CapabilityBoundingSet=" in unit, unit
        assert "MemoryDenyWriteExecute=true" in unit, unit
        # Conditions, not checks inside the script: an unprovisioned or unsynchronised host is
        # quiet rather than failing every interval forever.
        assert f"ConditionPathExists={MARKER}" in unit, unit
        assert f"ConditionPathExists={PLATFORM_CRED}/mp-api-key" in unit, unit

    with subtest("the timer catches up on nothing"):
        timer = machine.succeed("systemctl cat thingspeak.timer")
        assert "OnUnitActiveSec=60s" in timer, timer
        # No Persistent. Catching up after downtime would post a burst of stale created_at
        # stamps to a third party, and the missing minutes are the honest record.
        assert "Persistent" not in timer, timer

    with subtest("an unprovisioned reporter skips rather than fails"):
        before = len(sent_requests())
        machine.succeed("systemctl start thingspeak.service")
        # A oneshot without RemainAfterExit is inactive whether it ran or not, so the state
        # worth asserting on is the condition, not is-active.
        result = machine.succeed(
            "systemctl show -p ConditionResult --value thingspeak.service"
        ).strip()
        assert result == "no", f"the unit ran with no credentials provisioned: {result}"
        machine.fail("systemctl is-failed --quiet thingspeak.service")
        assert len(sent_requests()) == before, "a report went out with nothing provisioned"

    with subtest("provisioning the credentials and the marker lets a report go out"):
        # At runtime, in the booted guest: systemd-creds binds a blob to the host key in
        # /var/lib/systemd/credential.secret, which is not in the store and does not exist while
        # activation runs.
        machine.succeed(f"install -d -m 0700 {PLATFORM_CRED} {CHANNEL_CRED}")
        # The reader gets its own blob holding the same token, which is the deployed shape: the
        # receiver's keys carry no scope, so separate keys buy blast radius rather than
        # permission, and this one is encrypted under its own path and credential id.
        machine.succeed(
            f"printf '%s' '{API_KEY}' | systemd-creds encrypt --name=mp-api-key -"
            f" {PLATFORM_CRED}/mp-api-key"
        )
        machine.succeed(
            f"printf '%s' '{CHANNEL_KEY}' | systemd-creds encrypt --name=thingspeak-key -"
            f" {CHANNEL_CRED}/thingspeak-key"
        )
        machine.succeed(f"mkdir -p $(dirname {MARKER}) && touch {MARKER}")

        sent, status = report()
        assert status == 0, "the reporter failed on an update the recorder accepted"

    with subtest("the update carries the key, an aligned stamp and positional field numbers"):
        assert sent["api_key"] == CHANNEL_KEY, sent
        # Truncated to the interval, so the seconds are always :00 at a 60-second interval. This
        # is what makes the point in the channel the window's end rather than whenever systemd
        # happened to run the unit.
        assert re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:00Z", sent["created_at"]), sent

        # field5 is common.thingspeak.measurements' `no_such_reading`, which no record carries.
        # Its absence and field6's presence together are the claim: a missing reading is an
        # omitted parameter, not a zero, and the numbering does not slide up to close the gap.
        assert "field5" not in sent, sent
        for name in ["field1", "field2", "field3", "field4", "field6"]:
            assert name in sent, (name, sent)

        assert float(sent["field1"]) >= 0.0, sent
        assert int(sent["field2"]) >= 1, sent
        # And the values are the ones in the store, not plausible-looking numbers. total_bytes
        # is the same in every record on a running host, so the newest one is a sound
        # comparison even though it need not be the record this update was built from.
        stored = measurements("type=system.memory&limit=1")[0]["body"]
        assert int(sent["field3"]) == stored["total_bytes"], (sent, stored)

    with subtest("a window with no records sends nothing at all"):
        def silent():
            before = len(sent_requests())
            if run_reporter() != 0:
                return False
            if len(sent_requests()) != before:
                return False
            # The reporter's own wording as well as the recorder's silence, so a run skipped
            # for some unrelated reason cannot pass as a deliberate no-op.
            # Ten lines rather than one: `-u` includes systemd's own Starting/Finished pair
            # around the run, so the reporter's single line is not the last one.
            return "nothing to send" in machine.succeed(
                "journalctl -u thingspeak.service -o cat -n 10"
            )

        # Nothing is produced from here, so the previous whole interval empties out within two
        # boundaries. An empty update -- api_key and created_at and no fields -- would be a
        # request against a channel's rate limit that carries no data.
        retry(lambda _: silent(), timeout_seconds=240)

    with subtest("a 200 carrying a body of 0 is a failure, not a success"):
        # How ThingSpeak rejects an update. A status check alone cannot see it, which is why the
        # reporter judges the response rather than curl's exit code.
        thingspeak.succeed(f"printf '0' > {RECORDER_STATE}/response")
        _, status = report()
        assert status != 0, "a rejected update was reported as a success"
        machine.succeed(
            "journalctl -u thingspeak.service -o cat -n 20 | grep -F 'rejected by ThingSpeak'"
        )
        thingspeak.succeed(f"rm -f {RECORDER_STATE}/response")

    with subtest("a non-2XX response is a failure"):
        thingspeak.succeed(f"printf '500' > {RECORDER_STATE}/status")
        _, status = report()
        assert status != 0, "an HTTP 500 was reported as a success"
        machine.succeed(
            "journalctl -u thingspeak.service -o cat -n 20 | grep -F 'update failed: HTTP 500'"
        )
        thingspeak.succeed(f"rm -f {RECORDER_STATE}/status")

    with subtest("an unsynchronised clock skips the run"):
        # created_at goes to a third party that has no notion of an uncertain timestamp and no
        # way to correct one later, so a host that does not yet know the time must not report.
        machine.succeed(f"rm -f {MARKER}")
        before = len(sent_requests())
        assert run_reporter() == 0, "a skipped unit reported a failure"
        result = machine.succeed(
            "systemctl show -p ConditionResult --value thingspeak.service"
        ).strip()
        assert result == "no", f"the unit ran with no clock marker: {result}"
        machine.fail("systemctl is-failed --quiet thingspeak.service")
        assert len(sent_requests()) == before, "a report went out with an unsynchronised clock"
        machine.succeed(f"touch {MARKER}")

    with subtest("neither key leaks out of its credential"):
        for secret in [API_KEY, CHANNEL_KEY]:
            machine.fail(f"systemctl cat thingspeak.service | grep -F '{secret}'")
            machine.fail(f"journalctl -u thingspeak.service | grep -F '{secret}'")
            machine.fail(f"systemctl show thingspeak.service -p Environment | grep -F '{secret}'")
            machine.fail(f"ps axww | grep -v grep | grep -F '{secret}'")

    with subtest("the tunnel is a second endpoint, not a share of the collector's"):
        unit = machine.succeed("systemctl cat thingspeak-tunnel.service")
        assert f"iroh-uds-connect {TUNNEL_SOCKET}" in unit, unit
        assert f"LoadCredentialEncrypted=iroh-ticket:{TUNNEL_CRED}/iroh-ticket" in unit, unit
        # A real user, not DynamicUser, for the two reasons the module states: a dynamic group
        # does not exist at evaluation time, and a dynamic user's RuntimeDirectory can land
        # behind /run/private, a 0700 root:root gate no group membership gets through.
        assert "User=thingspeak-tunnel" in unit, unit
        machine.fail("systemctl cat thingspeak-tunnel.service | grep -F 'DynamicUser=true'")
        # Independence, stated as an absence: nothing here names the collector's tunnel, so
        # moving or revoking either one leaves the other alone.
        assert "mp-tunnel" not in unit, unit

    with subtest("an unprovisioned tunnel skips, a provisioned one serves a group-only socket"):
        result = machine.succeed(
            "systemctl show -p ConditionResult --value thingspeak-tunnel.service"
        ).strip()
        assert result == "no", f"the tunnel started with no ticket: {result}"
        machine.fail("systemctl is-failed --quiet thingspeak-tunnel.service")
        machine.fail(f"test -e {TUNNEL_SOCKET}")

        machine.succeed(f"install -d -m 0700 {TUNNEL_CRED}")
        machine.succeed("${irohSsh}/bin/iroh-ssh-generate-secret > /root/k 2>/dev/null")
        ticket = machine.succeed("${irohSsh}/bin/iroh-ssh-ticket /root/k").strip()
        machine.succeed("rm -f /root/k")
        assert ticket.startswith("endpoint"), f"unexpected ticket: {ticket}"
        machine.succeed(
            f"printf '%s' '{ticket}' | systemd-creds encrypt --name=iroh-ticket -"
            f" {TUNNEL_CRED}/iroh-ticket"
        )

        # It binds the local socket before it dials anything, so this holds with no relay in
        # this test at all. What is on the far side of that socket is not asserted here -- that
        # is tests/monitoring-platform-tunnel.nix, which builds an impersonated n0 for the same
        # binary.
        machine.succeed("systemctl start thingspeak-tunnel.service")
        machine.wait_for_unit("thingspeak-tunnel.service", timeout=120)
        machine.wait_until_succeeds(f"test -S {TUNNEL_SOCKET}", timeout=60)
        owner = machine.succeed(f"stat -c '%U:%G %a' {TUNNEL_SOCKET}").strip()
        assert owner == "thingspeak-tunnel:thingspeak-tunnel 660", f"socket is {owner}"
        parent = machine.succeed("stat -c '%U:%G %a' /run/thingspeak-tunnel").strip()
        assert parent == "thingspeak-tunnel:thingspeak-tunnel 750", f"directory is {parent}"
        # The directory mode is the real access control, so prove it by reading rather than by
        # trusting the bits.
        machine.fail(
            "${pkgs.util-linux}/bin/runuser -u nobody --"
            f" ${pkgs.curl}/bin/curl -sS --unix-socket {TUNNEL_SOCKET} http://localhost/"
        )

    with subtest("a reboot leaves nothing to do by hand"):
        # The operator's actual question: provision the blobs, let the nightly auto-upgrade
        # rebuild and reboot, and is there a manual step left afterwards? Two halves to it, and
        # they answer differently -- the credentials live in /etc, outside the store and outside
        # the generation, so they outlive both; the clock marker lives in /run and does not.
        #
        # virtualisation.diskImage defaults to a qcow2 that survives shutdown/start within a run,
        # so /etc here outlives the reboot exactly as it does on the Pi's SD card. (Which is also
        # why any journal read after this point would have to be scoped with `-b`.)
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("multi-user.target")
        machine.wait_for_unit("mp-collector.service")
        machine.wait_for_unit("monitoring-platform.service")

        # Nobody started either of these. The tunnel is wantedBy=multi-user.target with a
        # ConditionPathExists the blob provisioned above now satisfies, and the timer is
        # wantedBy=timers.target -- so a host that was provisioned before the upgrade comes back
        # reporting, with no start command anywhere.
        machine.wait_for_unit("thingspeak-tunnel.service", timeout=180)
        machine.wait_until_succeeds(f"test -S {TUNNEL_SOCKET}", timeout=60)
        machine.succeed("systemctl is-active --quiet thingspeak.timer")
        # Stopped again so what follows counts only the runs this test drives: OnBootSec is 60s,
        # which the rest of this subtest would otherwise race.
        machine.succeed("systemctl stop thingspeak.timer")

        # The reporter itself is held back, because the marker went with /run. This is precisely
        # where an RTC-less Pi sits between boot and chrony's first sync, and being quiet there
        # is the point -- created_at goes somewhere that cannot be corrected later.
        machine.fail(f"test -e {MARKER}")
        before = len(sent_requests())
        assert run_reporter() == 0, "a skipped run reported a failure"
        assert len(sent_requests()) == before, "a report went out before the clock was known"

        # And that clears itself, with no intervention, the moment the clock is known.
        machine.succeed(f"mkdir -p $(dirname {MARKER}) && touch {MARKER}")
        _, status = report()
        assert status == 0, "the reporter did not recover once the clock came back"
  '';
}
