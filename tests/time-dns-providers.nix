{ nixpkgs, pkgs, machineModule, stateVersion, globalTimeout ? 1200 }:

# The two upstream-health producers -- `system.time_provider` (chrony) and `system.dns_provider`
# (dnscrypt-proxy's journal) -- against the receiver the hosts actually deploy.
#
# Separate from tests/system-metrics.nix rather than folded into it, for a reason that is about
# the node and not about tidiness: that test drives its clock with timesyncd, and enabling chrony
# forces timesyncd off (modules/time-sync.nix). The two cannot share a node without one of them
# testing something other than what it claims to.
#
# What each half is actually for:
#
#   time_provider  -- the field offsets in `chronyc -c` output were read out of chrony's source,
#                     not observed. So the first subtest runs the REAL chronyc against the REAL
#                     chronyd and asserts the columns landed where the parser thinks they do. The
#                     unit tests in packages/system-metrics/src/chrony.rs cover the value
#                     handling; only a live daemon can say the layout is right.
#
#   dns_provider   -- `ok: false` is an absence, not a reading, so what has to be tested here is
#                     that a provider with no OK line in a real journal comes back false while the
#                     others come back true. The journal round trip is half the point: the lines
#                     have to survive systemd's stdout capture in the form the parser expects.

let
  inherit (nixpkgs) lib;

  ntsServers = import ../lib/nts-servers.nix { inherit lib; };

  # The raw binary, for the direct invocations below.
  #
  # NOT the `system-metrics` wrapper the module puts on PATH: that one already carries the unit's
  # whole argument list, and `--nts-provider` is repeatable -- so an invocation adding four more
  # would report eight providers, four of them twice. The wrapper is the right thing for an
  # operator asking "what would the next run send"; it is the wrong thing for asking a question
  # the unit is not configured for.
  systemMetrics = pkgs.callPackage ../packages/system-metrics/package.nix { };

  # Four NTS providers, exactly as lib/nts-servers.nix describes them -- picked from that file
  # rather than spelled out, so a rename there cannot leave this test asserting on a provider the
  # fleet no longer configures.
  providerKeys = builtins.attrNames ntsServers.providers;

  # Three DoH providers is enough to show the derivation: two that answer and one that does not.
  # Taken from lib/doh-stamps.nix for the same reason as above.
  dohStamps = import ../lib/doh-stamps.nix { inherit lib; };
  dohNames = builtins.attrNames dohStamps.endpoints;
  dohWorking = lib.take 2 dohNames;
  dohBroken = builtins.elemAt dohNames 2;

  # A chronyc whose output is fixed, for the cases a live daemon will not produce on demand: the
  # never-sentinel, a partially-decayed reachability register, and a reference clock present in
  # `sources` but absent from `authdata`. Every one of those is a silent wrong answer rather than
  # an error if the parser gets it wrong, and none can be arranged by pointing chrony somewhere.
  #
  # Only reachable through `--chronyc` on a direct invocation; the unit keeps the real binary.
  fixtureChronyc =
    let
      hostnames = map (k: ntsServers.providers.${k}.hostname) providerKeys;
      # Octal 17 = 15: the last four polls answered, the four before them lost. Decimal-parsed it
      # would read 17, which is not even a legal register value.
      sources = lib.concatMapStringsSep "\n" (h: "^,+,${h},2,6,17,42,0.000102334,0.000101998,0.000622110") hostnames;
      # 4294967295 is chrony's "never" in CSV mode, on both interval columns.
      authdata = lib.concatMapStringsSep "\n" (h: "${h},NTS,3,15,256,4294967295,5,0,0,100") hostnames;
    in
    pkgs.writeShellScriptBin "chronyc" ''
      case "$*" in
        # A reference clock leads the source report and is skipped by authdata, so a parser that
        # joined the two by row position would shift every provider by one.
        *sources*) printf '%s\n' '#,*,GPS0,0,4,377,11,-0.000000479,-0.000000621,0.000000134' ${lib.escapeShellArg sources} ;;
        *authdata*) printf '%s\n' ${lib.escapeShellArg authdata} ;;
        *) exit 1 ;;
      esac
    '';

  # Writes dnscrypt-proxy's refresh lines into the journal in dlog's exact stderr format, under a
  # unit of the configured name so `_SYSTEMD_UNIT` matches what the producer filters on.
  #
  # A unit rather than `systemd-cat` from the driver for the same reason tests/system-metrics.nix
  # gives: only a unit produces a predictable `_SYSTEMD_UNIT`, and that is what the read is keyed
  # by. The lines are deliberately NOT prefixed with a `<N>` priority -- dnscrypt-proxy does not
  # emit one either, which is exactly why every one of its lines lands at PRIORITY=6 and the
  # producer cannot narrow its read by priority.
  refreshScript = okNames: pkgs.writeShellScript "fake-dnscrypt-refresh" (
    lib.concatMapStringsSep "\n"
      (name: ''echo "[2026-09-17 12:00:00] [INFO] [${name}] OK (DoH) - rtt: 23ms"'')
      okNames
    + ''

      echo "[2026-09-17 12:00:00] [INFO] [${dohBroken}] [https://[2620:fe::fe]/dns-query]: dial tcp [2620:fe::fe]:443: connect: no route to host"
      echo "[2026-09-17 12:00:01] [NOTICE] Sorted latencies:"
      echo "[2026-09-17 12:00:01] [NOTICE] Server with the lowest initial latency: ${builtins.head okNames} (rtt: 23ms), live servers: ${toString (builtins.length okNames)}"
    ''
  );
in

nixpkgs.lib.nixos.runTest {
  name = "time-dns-providers";
  hostPkgs = pkgs;
  inherit globalTimeout;

  nodes.machine = { lib, ... }: {
    imports = [ machineModule ];

    networking.hostName = "provider-test";
    common.autoUpgrade.enable = lib.mkForce false;
    common.monitoring.enable = lib.mkForce false;
    common.irohSsh.enable = lib.mkForce false;

    # The real thing, pointed at servers that are unreachable from a test net -- which is the
    # state this record is for. chronyd still enumerates every configured source and still reports
    # a register for it, so `reachable: false` here is chrony's own answer and not a fixture's.
    #
    # mkForce because the test base turns the feature off at priority 90 on every node (see
    # `testNodeTimeSyncOff` in flake.nix), deliberately leaving mkForce for the tests that are
    # about time and have to switch it back on. This is one of them.
    common.timeSync.enable = lib.mkForce true;

    # This node's clock is never synchronised -- chrony is pointed at NTS servers a test net
    # cannot reach, which is the whole point of it. The collector holds telemetry for
    # `bufferTimeoutSecs` waiting for a clock that has never been set, then ships it marked
    # `mp.clock.uncertain`, so at the 300-second default every batch here would sit for five
    # minutes before a read could see it.
    #
    # Shortened rather than worked around, because that hold is not this test's subject: the
    # collector's clock handling belongs to upstream's suite, and tests/system-metrics.nix owns
    # the seam. All this needs is for batches to arrive promptly enough to assert on.
    services.mp-collector.bufferTimeoutSecs = 5;

    common.systemMetrics = {
      hwmonRoot = "/run/fixture-hwmon";
      flakeLock.path = null;
      # Only the two records under test, so this node's batches are small and the assertions
      # cannot be confused by a sensor sweep or a filesystem that happens to vary.
      units = [ ];
      timers = [ ];
    };

    # Three of the twelve stamps. The producer reports exactly what it is given, so a subset is
    # the honest way to make "this one is missing from the pass" mean something.
    common.systemMetrics.dnsProviders = lib.mkForce (
      lib.genAttrs (dohWorking ++ [ dohBroken ]) (name: dohStamps.endpoints.${name}.hostname)
    );

    systemd.services.fake-dnscrypt-refresh = {
      description = "Replays a dnscrypt-proxy refresh pass into the journal";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = refreshScript dohWorking;
        # The unit name the producer reads is dnscrypt-proxy.service, so this one has to log
        # under it. SyslogIdentifier does not change `_SYSTEMD_UNIT`, so the read is pointed at
        # this unit instead -- see common.systemMetrics.dns.unit below.
      };
    };
    common.systemMetrics.dns.unit = "fake-dnscrypt-refresh.service";

    system.stateVersion = stateVersion;
  };

  # Concatenated rather than interpolated, for the reason tests/system-metrics.nix gives: `''`
  # strips each literal's own indentation, so a `${...}` inside this one would dedent the shared
  # helper's function bodies out of their own `def`s.
  testScript = (import ../lib/test-mp-auth.nix) + ''
    import json

    SOCKET = "/run/monitoring-platform/monitoring-platform.sock"


    def query(params):
        # --fail-with-body so an unauthenticated read is a failed command naming its status,
        # rather than a KeyError on the missing "measurements" key several frames later.
        raw = machine.succeed(
            f"curl -sS --fail-with-body {auth_header()}--unix-socket {SOCKET} "
            f"'http://localhost/v1/measurements?{params}'"
        )
        return json.loads(raw)["measurements"]


    def by_attr(kind, attribute, wanted):
        return [
            m for m in query(f"type={kind}&limit=500")
            if m["attributes"].get(f"record.attributes.{attribute}") == wanted
        ]


    def run(unit, kind):
        # Two things a bare `systemctl start` would get wrong. A oneshot started back to back
        # trips systemd's start rate limit, which fails the start instead of running the unit --
        # hence the reset-failed. And the run finishing is not the batch arriving: the collector
        # resolves, corrects and forwards asynchronously, so the read has to wait for the rows
        # rather than race them.
        before = len(query(f"type={kind}&limit=500"))
        machine.succeed(f"systemctl reset-failed {unit}")
        machine.succeed(f"systemctl start {unit}")
        result = machine.succeed(f"systemctl show -p Result --value {unit}").strip()
        assert result == "success", f"{unit} run failed: {result}"

        # Bounded, and it explains itself on the last attempt. An unbounded retry here would
        # spend the whole global timeout to report nothing but "the test ran out of time",
        # which says neither which hop dropped the batch nor why.
        def arrived(last):
            if len(query(f"type={kind}&limit=500")) > before:
                return True
            if last:
                raise Exception(
                    f"no {kind} records arrived after {unit}:\n"
                    + machine.succeed(f"journalctl -u {unit} -o cat --no-pager | tail -30")
                    + "\ncollector:\n"
                    + machine.succeed("journalctl -u mp-collector.service -o cat --no-pager | tail -20")
                )
            return False

        retry(arrived, timeout_seconds=90)


    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("monitoring-platform.service")
    machine.wait_for_unit("mp-collector.service")
    machine.wait_for_unit("chronyd.service")

    # Before anything has been posted: issuing a key restarts the collector, and a restart
    # discards whatever is in its outbox.
    authenticate(machine)

    with subtest("the real chronyc lays its columns out where the parser looks for them"):
        # The unit runs the REAL chronyc against the REAL chronyd. Everything asserted here is a
        # column position, which is the half the unit tests cannot cover.
        run("system-metrics.service", "system.time_provider")

        # Captured up front and attached to every failure below. A null field here means chronyc
        # said something other than what the parser expected -- and the only way to tell "the
        # command failed" from "the column moved" is to look at what it actually printed.
        raw = machine.succeed(
            "${pkgs.chrony}/bin/chronyc -c -N sources -a; "
            "echo '--- authdata ---'; "
            "${pkgs.chrony}/bin/chronyc -c -N authdata -a; "
            # Both must be group-WRITABLE, and this is the first thing to look at when the fields
            # below come back null. The producer reaches chronyd over the unix socket, which needs
            # write permission on the socket (connecting to a datagram socket is a write) and on
            # its directory (chronyc binds a reply socket beside it). chronyd's unit sets
            # UMask=0027, which takes both bits off, so modules/system-metrics.nix puts them back.
            # Without that chronyc falls back to the UDP port, where `authdata` is refused and
            # every NTS field below would be null while `sources` kept working.
            "echo '--- socket, must be group-writable ---'; "
            "ls -ld /run/chrony /run/chrony/chronyd.sock"
        )

        for key in ${builtins.toJSON providerKeys}:
            rows = by_attr("system.time_provider", "provider", key)
            assert rows, f"no system.time_provider record for {key}"
            body = rows[-1]["body"]

            # The operator is not a chrony concept at any level; it can only have come from
            # lib/nts-servers.nix by way of the module.
            operator = rows[-1]["attributes"]["record.attributes.operator"]
            assert operator, f"{key} carries no operator"

            # Unreachable from a test net, so this is the shape under test: chrony knows the
            # source, has never had an answer from it, and says so.
            assert body["reachable"] is False, (
                f"{key} reachable={body['reachable']}\nchronyc said:\n{raw}"
            )
            assert body["reach"] == 0, f"{key} reach={body['reach']}"
            # The never-sentinel, through the real tool: a raw read would make this 4294967295.
            assert body["last_rx_seconds"] is None, (
                f"{key} last_rx_seconds={body['last_rx_seconds']}, "
                "which means chrony's never-sentinel was read as a number"
            )
            # A stratum column read one field off would land on the poll exponent, so asserting
            # the pair is what pins the offsets.
            assert body["poll_seconds"] is not None and body["poll_seconds"] > 0, (
                f"{key} poll_seconds={body['poll_seconds']}"
            )
            assert body["state"] in (
                "selected", "combined", "selectable", "falseticker", "jittery", "unselectable"
            ), f"{key} state={body['state']}, which is not one of chrony's selection states"
            # NTS is configured for every one of these, so a `-` here would mean the authdata
            # join missed.
            assert body["auth_mode"] == "nts", f"{key} auth_mode={body['auth_mode']}"

    with subtest("a source chrony has not resolved still produces a record"):
        # `-a` is what keeps this row in the report. Without it a provider whose hostname does not
        # resolve -- which is every one of them on this node -- is absent from `chronyc sources`
        # entirely, and the record would vanish exactly when the provider is most broken.
        rows = query("type=system.time_provider&limit=500")
        providers = {r["attributes"]["record.attributes.provider"] for r in rows}
        assert providers == set(${builtins.toJSON providerKeys}), (
            f"expected one record per configured provider, got {sorted(providers)}"
        )

    with subtest("the fixture cases a live daemon will not produce on demand"):
        # Run the binary directly with --chronyc pointed at the fixture: --dry-run prints the
        # batch without storing it, so this cannot disturb the assertions above.
        planned = machine.succeed(
            "${systemMetrics}/bin/system-metrics --dry-run "
            "--chronyc ${fixtureChronyc}/bin/chronyc "
            + " ".join(
                f"--nts-provider {key}={host}@{op}"
                for key, host, op in ${builtins.toJSON (
                  map (k: [ k ntsServers.providers.${k}.hostname ntsServers.providers.${k}.operator ]) providerKeys
                )}
            )
            + " --only system.time_provider"
        )

        rows = [line for line in planned.splitlines() if "system.time_provider" in line]
        assert len(rows) == ${toString (builtins.length providerKeys)}, (
            f"expected one row per provider:\n{planned}"
        )
        for row in rows:
            # Octal 17 is 15. Read as decimal it would be 17 -- which is not a legal value for an
            # eight-bit register, and would still be reported without complaint.
            assert "reach=15" in row, f"reach was not read as octal:\n{row}"
            assert "reachable=true" in row, row
            # Both interval columns carry chrony's never-sentinel in the fixture.
            assert "last_rx_seconds=42" in row, row
            assert "nts_last_ke_seconds=null" in row, (
                f"the never-sentinel was read as a number:\n{row}"
            )
            # The fixture leads with a reference clock that authdata skips; a positional join
            # would shift every provider's auth fields by one row and this would be 0.
            assert "nts_ke_attempts=5" in row, f"the authdata join slipped:\n{row}"
            assert "nts_ke_count=3" in row, f"the authdata join slipped:\n{row}"

    with subtest("a provider absent from an observed pass reports ok=false"):
        machine.succeed("systemctl start fake-dnscrypt-refresh.service")
        run("system-metrics-dns.service", "system.dns_provider")

        for name in ${builtins.toJSON dohWorking}:
            rows = by_attr("system.dns_provider", "provider", name)
            assert rows, f"no system.dns_provider record for {name}"
            body = rows[-1]["body"]
            assert body["ok"] is True, f"{name} ok={body['ok']}"
            assert body["rtt_ms"] == 23, f"{name} rtt_ms={body['rtt_ms']}"
            assert body["last_fail_seconds"] is None, f"{name} was never absent from a pass"

        rows = by_attr("system.dns_provider", "provider", "${dohBroken}")
        assert rows, "no system.dns_provider record for the broken provider"
        body = rows[-1]["body"]
        # Nothing in the journal says this provider failed. It is false because the pass that
        # the other two appeared in did not include it.
        assert body["ok"] is False, f"ok={body['ok']}"
        assert body["rtt_ms"] is None, f"rtt_ms={body['rtt_ms']}"
        assert body["last_ok_seconds"] is None, f"last_ok_seconds={body['last_ok_seconds']}"
        # This one does log a named failure, and its URL is an IPv6 literal -- so the brackets
        # around the address are not the brackets that close the URL.
        assert body["error"] == "dial tcp [2620:fe::fe]:443: connect: no route to host", (
            f"error={body['error']!r}"
        )
        assert body["window_seconds"] == 21600, f"window_seconds={body['window_seconds']}"

        # The hostname comes from lib/doh-stamps.nix, not from dnscrypt-proxy -- which logs the
        # stamp NAME and never the host behind it.
        #
        # Deliberately the hostname and not the stamp's address family: two stamps sharing a
        # hostname share dnscrypt-proxy's single pinned-address slot, so the family in a name is
        # a label rather than a promise. This is the attribute that says which records are one
        # dial target, and it is a fact rather than the winner of a race.
        assert rows[-1]["attributes"]["record.attributes.hostname"] == (
            "${dohStamps.endpoints.${dohBroken}.hostname}"
        ), rows[-1]["attributes"]

    with subtest("every record identifies the host and the boot that produced it"):
        # The same invariant tests/system-metrics.nix asserts for the fifteen-minute producer,
        # restated here rather than assumed, because these two records come from units with
        # sandboxes of their own -- and the envelope is exactly the half every assertion above
        # cannot see. A producer that cannot read /proc/sys still posts a well-formed batch with
        # every body field right; it just posts it anonymously, which on a fleet is
        # indistinguishable from some other host's.
        #
        # Both record types, because the two run under DIFFERENT sandboxes: the time half rides
        # the main collector and the DoH half is its own unit, so one of them holding does not
        # make the other hold.
        boot_id = machine.succeed("cat /proc/sys/kernel/random/boot_id").strip()
        for kind in ("system.time_provider", "system.dns_provider"):
            rows = query(f"type={kind}&limit=500")
            assert rows, f"no {kind} records to check the envelope of"
            for m in rows:
                attributes = m["attributes"]
                # .get rather than [], so a missing attribute fails on the assertion with the
                # record attached instead of a KeyError several frames away from the cause.
                assert attributes.get("resource.attributes.host.name") == "provider-test", m
                assert attributes.get("resource.attributes.service.name") == "system-metrics", m
                assert attributes.get("scope.name") == "system-metrics", m
                # Grouping samples by boot is otherwise arithmetic on uptime across a sampling
                # grid, which cannot tell a reboot from a gap in collection.
                assert attributes.get("resource.attributes.boot_id") == boot_id, m

    with subtest("a window with no refresh pass reports unknown, not failed"):
        # Nothing has been replayed into this unit's journal, so no pass is witnessed. Every
        # provider must come back absent: reporting them as failed would turn a quiet window into
        # a fleet-wide outage, and a genuinely empty pool is connectivity-watchdog's job.
        planned = machine.succeed(
            "${systemMetrics}/bin/system-metrics --dry-run --only system.dns_provider "
            "--journalctl ${pkgs.systemd}/bin/journalctl "
            "--dnscrypt-unit fake-dnscrypt-quiet.service "
            + " ".join(
                f"--doh-provider {name}={host}"
                for name, host in ${builtins.toJSON (
                  map (n: [ n dohStamps.endpoints.${n}.hostname ]) (dohWorking ++ [ dohBroken ])
                )}
            )
        )
        rows = [line for line in planned.splitlines() if "system.dns_provider" in line]
        assert len(rows) == 3, f"expected one row per provider:\n{planned}"
        for row in rows:
            assert "ok=null" in row, f"a quiet window must not read as a failure:\n{row}"
            assert "last_ok_seconds=null" in row, row
            assert "last_fail_seconds=null" in row, row

    with subtest("the dns collection runs on its own six-hourly timer"):
        timer = machine.succeed("systemctl cat system-metrics-dns.timer")
        assert "OnUnitActiveSec=6h" in timer, timer
        # Nothing in this record describes a moment that could be caught up on, and the window is
        # relative to now, so a catch-up run would read a window that has already been read.
        assert "Persistent=" not in timer, timer

        # The DoH unit must not re-sample everything the fifteen-minute one already does: at four
        # runs a day that would be four extra copies of every host record.
        unit = machine.succeed("systemctl cat system-metrics-dns.service")
        assert "--only system.dns_provider" in unit, unit

        # That the flag is PRESENT, above; that it WORKED, here. The two are not the same
        # assertion, and only the second one fails if `--only` stops being honoured -- at which
        # point this unit quietly resumes posting cpu, memory, filesystem and sensor records four
        # times a day, which is the entire reason the flag exists.
        #
        # The unit's own rendered ExecStart with --dry-run appended, rather than a hand-written
        # argument list: a list spelled out here would pass while the deployed one regressed.
        exec_start = next(
            line.split("=", 1)[1]
            for line in unit.splitlines()
            if line.startswith("ExecStart=")
        )
        planned = machine.succeed(f"{exec_start} --dry-run")
        types = {
            line.split()[1] for line in planned.splitlines() if line.startswith("record ")
        }
        assert types == {"system.dns_provider"}, (
            f"--only did not hold, the run planned {sorted(types)}:\n{planned}"
        )

    with subtest("nothing was rejected on the way in"):
        receiver_log = machine.succeed("journalctl -u monitoring-platform.service -o cat")
        assert "with rejections" not in receiver_log, f"receiver rejected records:\n{receiver_log}"
  '';
}
