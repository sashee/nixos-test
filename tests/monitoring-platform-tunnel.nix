{ nixpkgs, pkgs, machineModule, stateVersion, dohStamps }:

let
  irohSsh = pkgs.callPackage ../packages/iroh-ssh/package.nix { };

  # The impersonated-n0 harness, identical in intent to tests/iroh-ssh.nix: the
  # relay hostnames and the endpoint-id discovery domain both resolve to nodes in
  # this test, so an id-only ticket -- the form the deployed client credential
  # holds -- can be dialed with the node under test left entirely stock.
  relayDomain = "relay.n0.iroh.link";
  discoveryDomain = "dns.iroh.link";
  discoveredRelayUrl = "https://euc1-1.${relayDomain}.";

  interceptor = import ./doh-interceptor.nix {
    inherit pkgs dohStamps;
    name = "mp-tunnel";
    respond = ''
      def respond(query, meta):
          name, qtype, _, _ = read_question(query)
          if name.endswith(".${relayDomain}") and qtype == 1:
              return a(query, ARGS[0])   # ARGS[0] = the relay node's IP
          if name.endswith(".${relayDomain}"):
              return nodata(query)       # fall back to A
          if name.startswith("_iroh.") and name.endswith(".${discoveryDomain}"):
              if qtype == 16:
                  return txt(query, "relay=${discoveredRelayUrl}")
              return nodata(query)       # fall back to TXT
          return nxdomain(query)         # bootstrap, everything else
    '';
  };
  dohIpv4Json = builtins.toJSON interceptor.dohIpv4;
  dohIpv6Json = builtins.toJSON interceptor.dohIpv6;

  relayCert = import ./test-cert.nix { inherit pkgs; } {
    name = "iroh-relay";
    sans = [ "*.${relayDomain}" ];
  };

  relayConfig = pkgs.writeText "iroh-relay.toml" ''
    http_bind_addr = "127.0.0.1:3340"

    [tls]
    https_bind_addr = "0.0.0.0:443"
    cert_mode = "Manual"
    manual_cert_path = "${relayCert.certFile}"
    manual_key_path = "${relayCert.keyFile}"
  '';
in
nixpkgs.lib.nixos.runTest {
  name = "monitoring-platform-tunnel";
  hostPkgs = pkgs;
  skipTypeCheck = true;
  # Ceiling, not a wait: the aarch64 variant runs under TCG on the KVM-less CI
  # runner, and a relay handshake plus a producer round trip is not quick there.
  globalTimeout = 2400;

  nodes.dohpeer = { nodes, ... }: {
    networking = {
      hostName = "dohpeer";
      firewall.enable = false;
    };
    virtualisation.memorySize = 512;
    systemd.services.fake-doh = interceptor.mkService {
      args = [ nodes.relay.networking.primaryIPAddress ];
    };
    system.stateVersion = stateVersion;
  };

  nodes.relay = { ... }: {
    networking.hostName = "relay";
    virtualisation.memorySize = 512;
    networking.firewall.allowedTCPPorts = [ 443 ];
    systemd.services.iroh-relay = {
      description = "iroh relay impersonating the n0 relays";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig.ExecStart = "${pkgs.iroh-relay}/bin/iroh-relay -c ${relayConfig}";
    };
    system.stateVersion = stateVersion;
  };

  # Both ends of the tunnel plus the receiver, the collector and the producers --
  # the deployed rpi5 topology, which today really is one host. The far side of
  # the tunnel being local is not a shortcut: it is the configuration being
  # tested, and the only thing that changes when the receiver moves off-box is
  # which endpoint the client's ticket names.
  nodes.machine = { lib, ... }: {
    imports = [
      machineModule
      { security.pki.certificateFiles = [ interceptor.caFile relayCert.caFile ]; }
    ];

    networking.hostName = "mp-tunnel-host";
    common.autoUpgrade.enable = lib.mkForce false;
    common.monitoring.enable = lib.mkForce false;
    # Not the subject here, and its failsafe would spend the test opening port 22
    # against a credential this test never provisions.
    common.irohSsh.enable = lib.mkForce false;

    # Undo testNodeMpTunnelOff (flake.nix), which every other rpi node keeps: this
    # is the suite that has a relay, so it is the one that runs the real wiring.
    # mkForce against that module's priority-90 definitions, exactly as its
    # comment anticipates.
    common.mpTunnel.server.enable = lib.mkForce true;
    common.mpTunnel.client.enable = lib.mkForce true;
    services.mp-collector.forwardTo = lib.mkForce "/run/mp-tunnel/upstream.sock";
    services.mp-collector.forwardToGroup = lib.mkForce "mp-tunnel";

    # No time daemon runs on a test node (testNodeTimeSyncOff), so as far as the
    # collector is concerned this host's clock has never been set -- and it holds
    # telemetry for bufferTimeoutSecs before shipping it flagged rather than
    # letting it out stamped from an unknown frame. At the 300s default that gate
    # is the slowest thing in this file by an order of magnitude, and it is not
    # what is under test here: tests/system-metrics.nix owns the clock story, with
    # a real chrony peer. Five seconds keeps the gate in the path, still exercised,
    # without spending five minutes of every run waiting it out.
    services.mp-collector.bufferTimeoutSecs = 5;

    system.stateVersion = stateVersion;
  };

  # Concatenated rather than interpolated: `''` strips each literal's own indentation, so a
  # `${...}` inside this one would dedent the helper's function bodies out of their own `def`s.
  testScript = (import ../lib/test-mp-auth.nix) + ''
    import json
    import time

    doh_ipv4 = json.loads('${dohIpv4Json}')
    doh_ipv6 = json.loads('${dohIpv6Json}')

    RECEIVER = "/run/monitoring-platform/monitoring-platform.sock"
    TUNNEL = "/run/mp-tunnel/upstream.sock"
    SERVER_CRED = "/etc/credentials/mp-tunnel/server"
    CLIENT_CRED = "/etc/credentials/mp-tunnel/client"
    # The ThingSpeak reporter's own hop (modules/thingspeak.nix): the same binary with its own
    # ticket and socket, dialing the same listener. Here because this is the suite with a relay,
    # so the only one in which it can actually connect.
    TS_TUNNEL = "/run/thingspeak-tunnel/upstream.sock"
    TS_CRED = "/etc/credentials/thingspeak/tunnel"
    CLIENT = "mp-tunnel-client.service"
    SERVER = "mp-tunnel-server.service"
    TS_CLIENT = "thingspeak-tunnel.service"
    # RestartSec on both client units, in the microseconds RestartUSecNext is reported in.
    RESTART_SEC_USEC = 5_000_000


    def measurements(params="limit=5000"):
        # root is not in the monitoring-platform group but bypasses the 0750
        # runtime directory anyway, so no extra client user is needed.
        #
        # --fail-with-body, so an unauthenticated read is a failed command naming
        # its status rather than a KeyError on the missing "measurements" field:
        # curl exits 0 on a 401 without it. The header itself is empty until
        # authenticate() has run, which is what makes forgetting it fail loudly.
        raw = machine.succeed(
            f"curl -sS --fail-with-body {auth_header()}--unix-socket {RECEIVER} "
            f"'http://localhost/v1/measurements?{params}'"
        )
        return json.loads(raw)["measurements"]


    def produce():
        # A oneshot started back to back trips systemd's start rate limit, which
        # would fail the start rather than run the unit.
        machine.succeed("systemctl reset-failed system-metrics.service")
        machine.succeed("systemctl start system-metrics.service")


    # The collector's own wording when a flush does not land (runtime.rs). Matched
    # exactly rather than by a loose "error|failed" pattern, which its startup
    # banner -- it logs forward_to= with the tunnel's path in it -- would satisfy
    # without a single delivery having been attempted.
    FAILED = "forwarding failed; will retry"


    def delivery_failures():
        # Counted rather than sampled, so a window can be asserted over rather
        # than an instant. grep -c exits 1 on zero matches while still printing 0,
        # hence the `|| true`.
        return int(machine.succeed(
            f"journalctl -u mp-collector.service -o cat | grep -cF '{FAILED}' || true"
        ).strip())


    def show(unit, prop):
        return machine.succeed(f"systemctl show -P {prop} {unit}").strip()


    def restart_delay_usec(unit):
        # The delay before the unit's next automatic restart, which is where RestartSteps= shows.
        # Raw microseconds over D-Bus: `systemctl show` renders a span for humans ("9.306049s").
        path = "/org/freedesktop/systemd1/unit/" + "".join(
            c if c.isalnum() else f"_{ord(c):02x}" for c in unit
        )
        kind, value = machine.succeed(
            f"busctl get-property org.freedesktop.systemd1 {path}"
            " org.freedesktop.systemd1.Service RestartUSecNext"
        ).split()
        assert kind == "t", (kind, value)
        return int(value)


    def cursor():
        # -n 1 rather than -n 0: the cursor is printed after the last entry shown, so with none
        # shown there is none to print.
        return machine.succeed("journalctl -q -n 1 --show-cursor -o cat").splitlines()[-1].removeprefix(
            "-- cursor: "
        )


    def journal_since(after, *units):
        machine.succeed("journalctl --sync")
        selected = " ".join(f"-u {unit}" for unit in units)
        return machine.succeed(f"journalctl -q {selected} --after-cursor='{after}' -o cat")


    def accepted_connections(after=None):
        # The listener logs one line per QUIC connection and none per stream, so this counts
        # connections -- the quantity the dialers are meant to keep at one apiece.
        machine.succeed("journalctl --sync")
        since = f"--after-cursor='{after}'" if after else ""
        return [
            line for line in machine.succeed(
                f"journalctl -q -u {SERVER} {since} -o cat"
            ).splitlines()
            if line.startswith("Accepted connection from ")
        ]


    def request(socket):
        # A fresh local connection per call, exactly what the ThingSpeak reporter makes every
        # minute: curl opens the socket, sends one request and closes it.
        return machine.succeed(
            f"curl -sS --fail-with-body --unix-socket {socket} {auth_header()}"
            "'http://localhost/v1/measurements?limit=1'"
        )


    def close_reasons(after, unit):
        # Why each of the unit's processes since the cursor said its connection ended: the tail
        # of iroh-uds-connect's exit line, "error: connection to <id> closed: <reason>". Only
        # those lines -- a failed redial afterwards says "timed out" for a different reason.
        return [
            line.split(" closed: ", 1)[1]
            for line in journal_since(after, unit).splitlines()
            if line.startswith("error: connection to ") and " closed: " in line
        ]


    def connected_again(unit, old_pid):
        # Back up as a new process: the old one exited with its connection, and Type=notify
        # makes `active` mean the replacement has dialed and bound its socket.
        return show(unit, "ActiveState") == "active" and show(unit, "MainPID") not in ("0", old_pid)


    dohpeer.start()
    relay.start()
    dohpeer.wait_for_unit("fake-doh.service")
    relay.wait_for_unit("iroh-relay.service")

    def vlan_ip(node):
        # eth1's static address is assigned by network-addresses-eth1.service,
        # which under slow TCG boots can land seconds after the units we wait
        # for; retry until it appears.
        return node.wait_until_succeeds(
            "${pkgs.iproute2}/bin/ip -j -4 addr show dev eth1 "
            "| ${pkgs.jq}/bin/jq -r '.[0].addr_info[] | select(.prefixlen==24) | .local' "
            "| ${pkgs.gnugrep}/bin/grep .",
            timeout=120,
        ).strip()

    dohpeer_ip = vlan_ip(dohpeer)

    machine.start()
    machine.wait_for_unit("multi-user.target")
    for ip in doh_ipv4:
        machine.succeed(f"${pkgs.iproute2}/bin/ip route replace {ip}/32 via {dohpeer_ip} dev eth1")
    for ip in doh_ipv6:
        machine.succeed(f"${pkgs.iproute2}/bin/ip -6 route replace {ip}/128 dev eth1")
    machine.succeed("systemctl restart dnscrypt-proxy.service")

    # Type=notify on both, so `active` means each socket is bound and accepting.
    machine.wait_for_unit("mp-collector.service")
    machine.wait_for_unit("monitoring-platform.service")

    # Before the first subtest, because the first one to read the receiver is the
    # unprovisioned-tunnel case below and every endpoint but /healthz refuses an
    # unauthenticated request. Safe this early even though the tunnel is deliberately
    # down: this talks to the receiver's database and the collector's own socket, not
    # through the hop. It restarts the collector -- which discards the outbox, and must
    # therefore precede every produce() in this file.
    authenticate(machine)

    with subtest("the collector posts to the tunnel, not to the receiver"):
        # The claim the whole change rests on: nothing on this host names the
        # receiver's socket except the tunnel's server half. Asserted on the
        # rendered units rather than the Nix, because it is a claim about the
        # command lines that actually run.
        collector = machine.succeed("systemctl cat mp-collector.service")
        assert TUNNEL in collector, (
            f"the collector does not forward to the tunnel socket:\n{collector}"
        )
        assert RECEIVER not in collector, (
            f"the collector still names the receiver's socket, so moving the receiver "
            f"would edit it too:\n{collector}"
        )
        server_unit = machine.succeed("systemctl cat mp-tunnel-server.service")
        assert RECEIVER in server_unit, (
            f"the tunnel server does not forward to the receiver:\n{server_unit}"
        )

        # And the group membership that opens the two 0750 directories, which is
        # the actual access control on both hops.
        assert "SupplementaryGroups=mp-tunnel" in collector, (
            f"the collector cannot reach the tunnel's socket directory:\n{collector}"
        )
        assert "SupplementaryGroups=monitoring-platform" in server_unit, (
            f"the tunnel server cannot reach the receiver's socket directory:\n{server_unit}"
        )

    with subtest("both halves are encrypted-credential shaped and sandboxed"):
        machine.succeed(
            "systemctl cat mp-tunnel-server.service"
            f" | grep -F 'LoadCredentialEncrypted=iroh-secret:{SERVER_CRED}/iroh-secret'"
        )
        machine.succeed(
            "systemctl cat mp-tunnel-client.service"
            f" | grep -F 'LoadCredentialEncrypted=iroh-ticket:{CLIENT_CRED}/iroh-ticket'"
        )
        machine.succeed("systemctl cat mp-tunnel-server.service | grep -F 'DynamicUser=true'")
        # The client's is a real user, and that is load-bearing twice over: a
        # dynamic group does not exist at eval time for mp-collector's
        # forwardToGroup assertion, and a dynamic user's runtime directory can
        # end up behind /run/private, which no group membership gets through.
        machine.fail("systemctl cat mp-tunnel-client.service | grep -F 'DynamicUser=true'")
        machine.succeed("systemctl cat mp-tunnel-client.service | grep -F 'User=mp-tunnel'")
        for unit in ["mp-tunnel-server", "mp-tunnel-client"]:
            machine.succeed(f"systemctl cat {unit}.service | grep -F 'MemoryDenyWriteExecute=true'")
            machine.succeed(f"systemctl cat {unit}.service | grep -F '~@resources'")
        # Both dialing units run the same binary from two modules, and the restart policy is
        # its reconnect loop, so the two must not drift: the backoff is exercised below on the
        # collector's client only.
        for unit in [CLIENT, TS_CLIENT]:
            policy = {
                prop: show(unit, prop)
                for prop in ["Type", "Restart", "RestartUSec", "RestartSteps", "RestartMaxDelayUSec"]
            }
            assert policy == {
                "Type": "notify",
                "Restart": "always",
                "RestartUSec": "5s",
                "RestartSteps": "4",
                "RestartMaxDelayUSec": "1min",
            }, f"{unit}: {policy}"

    with subtest("an unprovisioned tunnel skips rather than crash-loops"):
        # ConditionPathExists, so a host that has not been given its blobs yet
        # sits inert instead of restarting every five seconds -- and the failure
        # mode an operator sees is "condition failed", not a crash.
        for unit in ["mp-tunnel-server", "mp-tunnel-client"]:
            machine.fail(f"systemctl is-active --quiet {unit}.service")
            machine.fail(f"systemctl is-failed --quiet {unit}.service")
        machine.fail(f"test -e {TUNNEL}")

        # The consequence for the data path: the collector has nowhere to deliver
        # and holds what it has rather than dropping it. A baseline rather than an
        # empty-list assertion, so a receiver that records something of its own
        # does not read as data having crossed a tunnel that is not running.
        baseline = len(measurements())
        produce()
        machine.wait_until_succeeds(
            f"journalctl -u mp-collector.service -o cat | grep -qF '{FAILED}'",
            timeout=180,
        )
        assert len(measurements()) == baseline, "a measurement landed with no tunnel running"

    with subtest("provisioning the blobs"):
        # At runtime, in the booted guest: systemd-creds binds the blob to the host
        # key in /var/lib/systemd/credential.secret, which does not exist in the
        # store and is not set up while activation runs.
        machine.succeed(f"install -d -m 0700 {SERVER_CRED} {CLIENT_CRED} {TS_CRED}")
        machine.succeed("${irohSsh}/bin/iroh-ssh-generate-secret > /root/k 2>/dev/null")
        machine.succeed(
            "${pkgs.systemd}/bin/systemd-creds encrypt --name=iroh-secret"
            f" /root/k {SERVER_CRED}/iroh-secret"
        )

        # The address half, derived from the very key the server half will load --
        # a pure function of it, so the two can never name different endpoints.
        # This pipeline is the one hosts/rpi5 documents for the operator.
        ticket = machine.succeed("${irohSsh}/bin/iroh-ssh-ticket /root/k").strip()
        assert ticket.startswith("endpoint"), f"unexpected ticket: {ticket}"
        machine.succeed(
            f"printf '%s' '{ticket}' | ${pkgs.systemd}/bin/systemd-creds encrypt"
            f" --name=iroh-ticket - {CLIENT_CRED}/iroh-ticket"
        )
        machine.succeed("rm -f /root/k")
        # The ThingSpeak tunnel names the same endpoint, by the decrypt-and-re-encrypt pipeline
        # hosts/rpi5 documents: no secret and no iroh-ssh-ticket needed.
        machine.succeed(
            f"systemd-creds decrypt --name=iroh-ticket {CLIENT_CRED}/iroh-ticket -"
            f" | systemd-creds encrypt --name=iroh-ticket - {TS_CRED}/iroh-ticket"
        )

    with subtest("a client with nothing to dial serves no socket, and backs off"):
        # The far side is not running yet. The client dials once per process and binds its
        # socket only once that dial has worked, so all it can do here is fail, exit, and be
        # restarted -- and nothing may look connected while it does.
        machine.succeed(f"systemctl start --no-block {CLIENT}")

        def retrying(_):
            # Sampled on every poll rather than once, so a socket that appeared and vanished
            # between two attempts is not missed.
            state = show(CLIENT, "ActiveState")
            assert state != "active", "the client reported ready with no far side"
            machine.fail(f"test -e {TUNNEL}")
            return int(show(CLIENT, "NRestarts")) >= 2

        retry(retrying, timeout_seconds=600)
        # It really ran -- this is a dial failing, not the credential condition skipping it.
        assert show(CLIENT, "ConditionResult") == "yes"

        # The backoff is engaged: two failures in, the next delay is past RestartSec. Without
        # it a dial that fails fast restarts the unit every five seconds for as long as the far
        # side is down, at several journal lines a time.
        delay = restart_delay_usec(CLIENT)
        assert delay > RESTART_SEC_USEC, f"no backoff after two failed dials: {delay}us"

        # What a client of the socket sees: refused at once (curl's 7, "couldn't connect"),
        # where the tunnel used to accept the connection and hold it for a 30-second dial.
        started = time.monotonic()
        status, _ = machine.execute(f"curl -sS --unix-socket {TUNNEL} http://localhost/healthz")
        elapsed = time.monotonic() - started
        assert status == 7, f"curl exited {status} against a tunnel that is down"
        assert elapsed < 10, f"a client of a down tunnel waited {elapsed:.1f}s to be refused"

    with subtest("the client connects once the far side is up, and its backoff starts over"):
        machine.succeed(f"systemctl start {SERVER}")
        machine.wait_for_unit(SERVER)
        # Type=notify: `active` means dialed and bound, so this waits on exactly the claim --
        # through whatever restart delay the client had backed off to.
        machine.wait_for_unit(CLIENT, timeout=600)
        machine.succeed(f"test -S {TUNNEL}")
        # RESTART_RESET=1 rode in with READY=1. Without it systemd counts restarts for the
        # unit's whole life, and every later outage would start at the 60s ceiling.
        assert show(CLIENT, "NRestarts") == "0", show(CLIENT, "NRestarts")
        assert restart_delay_usec(CLIENT) == RESTART_SEC_USEC, restart_delay_usec(CLIENT)

    with subtest("the tunnel's socket is group-reachable, not world-reachable"):
        machine.wait_until_succeeds(f"test -S {TUNNEL}", timeout=60)
        owner = machine.succeed(f"stat -c '%U:%G %a' {TUNNEL}").strip()
        assert owner == "mp-tunnel:mp-tunnel 660", f"tunnel socket is {owner}"
        parent = machine.succeed("stat -c '%U:%G %a' /run/mp-tunnel").strip()
        assert parent == "mp-tunnel:mp-tunnel 750", f"/run/mp-tunnel is {parent}"
        # The directory mode is the real access control, so prove it by reading
        # rather than by trusting the bits: a user outside the group cannot get in.
        machine.fail(
            "${pkgs.util-linux}/bin/runuser -u nobody --"
            f" ${pkgs.curl}/bin/curl -sS --unix-socket {TUNNEL} http://localhost/"
        )

    with subtest("a measurement traverses collector -> iroh -> receiver"):
        # The end-to-end claim. Nothing here reaches the receiver's socket except
        # through the tunnel: the collector cannot even see it (no group), and the
        # bytes cross a QUIC connection that was dialed through endpoint-id
        # discovery against the impersonated relay.
        produce()
        machine.wait_until_succeeds(
            "test \"$(curl -sS --unix-socket"
            f" {RECEIVER} {auth_header()}'http://localhost/v1/measurements?limit=1'"
            " | ${pkgs.jq}/bin/jq '.measurements | length')\" -ge 1",
            timeout=300,
        )
        types = {m["type"] for m in measurements()}
        assert "system.host" in types, f"no host record arrived through the tunnel: {types}"

    with subtest("the ThingSpeak tunnel is a connection of its own to the same listener"):
        before = accepted_connections()
        # Blocking, and Type=notify: this returns once the tunnel has dialed and bound its
        # socket, or fails the test if it cannot.
        machine.succeed(f"systemctl start {TS_CLIENT}")
        machine.wait_for_unit(TS_CLIENT)
        after = accepted_connections()
        assert len(after) == len(before) + 1, f"expected one new connection:\n{after}"
        # Its own endpoint, so its own connection: the two hops can be pointed at different
        # receivers, or revoked, independently.
        assert len(set(after)) == len(after), f"two dialers shared an endpoint id:\n{after}"

        owner = machine.succeed(f"stat -c '%U:%G %a' {TS_TUNNEL}").strip()
        assert owner == "thingspeak-tunnel:thingspeak-tunnel 660", f"socket is {owner}"
        parent = machine.succeed("stat -c '%U:%G %a' /run/thingspeak-tunnel").strip()
        assert parent == "thingspeak-tunnel:thingspeak-tunnel 750", f"directory is {parent}"
        # The directory mode is the real access control, so prove it by reading rather than by
        # trusting the bits.
        machine.fail(
            "${pkgs.util-linux}/bin/runuser -u nobody --"
            f" ${pkgs.curl}/bin/curl -sS --unix-socket {TS_TUNNEL} http://localhost/"
        )
        assert "measurements" in json.loads(request(TS_TUNNEL)), "no read through the ThingSpeak tunnel"

    with subtest("every request rides its tunnel's one connection, and none is logged"):
        # The reporter's pattern -- a fresh local connection per request -- used to be a fresh
        # QUIC connection per request too: a dial, discovery and a handshake every minute, all
        # through one long-lived iroh endpoint. That endpoint wedged on 2026-10-11 and failed
        # every dial for fourteen hours. Each local connection is now a stream on the
        # connection the tunnel already holds, so the listener sees no new connection at all.
        since = cursor()
        pids = {unit: show(unit, "MainPID") for unit in [CLIENT, TS_CLIENT]}
        for socket in [TUNNEL, TS_TUNNEL]:
            for _ in range(5):
                request(socket)
            # And concurrently: streams are independent, so overlapping local connections must
            # not serialise behind one another or interfere.
            codes = machine.succeed(
                "seq 5 | xargs -P 5 -I{} curl -sS -o /dev/null -w '%{http_code}\\n'"
                f" --unix-socket {socket} {auth_header()}'http://localhost/v1/measurements?limit=1'"
            ).split()
            assert codes == ["200"] * 5, f"concurrent requests through {socket}: {codes}"

        new = accepted_connections(since)
        assert new == [], f"requests opened new connections:\n{new}"
        for unit, pid in pids.items():
            assert show(unit, "MainPID") == pid, f"{unit} restarted while serving requests"

        # The server half used to close the QUIC connection as soon as its side of a request
        # was done, and noq lets a peer drop undelivered stream data on a CONNECTION_CLOSE -- so
        # the client half's last read failed with "connection lost" on every request that had
        # succeeded. An absence, so there is nothing to wait on: such an error is logged as the
        # request ends, and a few seconds covers a slow runner.
        machine.sleep(5)
        logged = journal_since(since, CLIENT, TS_CLIENT, SERVER)
        assert "error" not in logged, f"a successful request logged:\n{logged}"

    with subtest("a dialer that opens a connection per request is still served"):
        # Stock dumbpipe's shape, and iroh-ssh-connect's: one connection, one stream, then
        # close. The listener serves every stream a connection carries, and this is the
        # one-stream case of that -- so the wire format is unchanged for anything that dials
        # the old way.
        quiet_since = cursor()
        # stdin held open a few seconds past the request, as an interactive client's would be:
        # an EOF straight after it is a half-close, which the receiver may take as the client
        # going away before it has answered.
        reply = machine.succeed(
            "{ printf 'GET /healthz HTTP/1.0\\r\\n\\r\\n'; sleep 5; }"
            f" | timeout 120 ${irohSsh}/bin/iroh-ssh-connect {ticket}"
        )
        status_line = reply.split("\r\n", 1)[0]
        assert status_line.split()[1] == "200", f"unexpected reply:\n{reply}"
        assert len(accepted_connections(quiet_since)) == 1, accepted_connections(quiet_since)

    with subtest("dialers that leave on purpose leave nothing for the listener to report"):
        # A client stopped by systemd closes its endpoint on the way out, as iroh-ssh-connect
        # just did on finishing, so the listener sees a CONNECTION_CLOSE rather than silence.
        # Without it the listener would find out from its idle timeout and log the connection
        # as lost -- once per restart of a unit that is now meant to restart.
        old_pid = show(CLIENT, "MainPID")
        machine.succeed(f"systemctl restart {CLIENT}")
        retry(lambda _: connected_again(CLIENT, old_pid), timeout_seconds=300)
        # An absence with a known bound: a connection dropped without a goodbye is reported
        # when the listener's idle timeout -- 30s -- fires, so wait that out with margin. The
        # window opened before iroh-ssh-connect's connection above, so it covers that too.
        machine.sleep(40)
        logged = journal_since(quiet_since, SERVER)
        assert "lost" not in logged and "error" not in logged, f"the listener reported:\n{logged}"

    with subtest("the far side going away is a reconnect, and costs no data"):
        # What a real split deployment does all the time. The listener closes its connections
        # on the way out, so each client learns of it from a CONNECTION_CLOSE ("closed by peer")
        # rather than an idle timeout ("timed out"), and exits; its socket goes with it. The
        # collector's kept HTTP/1.1 connection dies with the tunnel, delivery fails, and the
        # batch stays queued rather than being dropped -- then lands once the far side is back
        # and the restarted client has dialed it.
        before = len(measurements())
        failures_before = delivery_failures()
        since = cursor()
        pids = {unit: show(unit, "MainPID") for unit in [CLIENT, TS_CLIENT]}
        machine.succeed(f"systemctl stop {SERVER}")
        for unit in [CLIENT, TS_CLIENT]:
            retry(lambda _, unit=unit: close_reasons(since, unit) != [], timeout_seconds=120)
            reasons = close_reasons(since, unit)
            assert all(r.startswith("closed by peer") for r in reasons), (
                f"{unit} did not hear the listener leave: {reasons}"
            )
        machine.wait_until_fails(f"test -e {TUNNEL}", timeout=60)

        produce()
        for _ in range(90):
            if delivery_failures() > failures_before:
                break
            machine.sleep(2)
        else:
            raise Exception("the collector never reported a failed delivery")
        assert len(measurements()) == before, "a measurement arrived with the far side stopped"

        machine.succeed(f"systemctl start {SERVER}")
        machine.wait_for_unit(SERVER)
        for unit, pid in pids.items():
            retry(lambda _, unit=unit, pid=pid: connected_again(unit, pid), timeout_seconds=600)
        machine.wait_until_succeeds(
            "test \"$(curl -sS --unix-socket"
            f" {RECEIVER} {auth_header()}'http://localhost/v1/measurements?limit=5000'"
            f" | ${pkgs.jq}/bin/jq '.measurements | length')\" -gt {before}",
            timeout=300,
        )

    with subtest("a far side that vanishes without a goodbye is noticed, and reconnected to"):
        # SIGKILL leaves no CONNECTION_CLOSE, and the listener's replacement -- Restart=always,
        # same key, same endpoint id -- knows nothing of the old connections. Only the client's
        # own idle timeout can tell it the connection is gone. A client that kept a dead
        # connection would sit `active` with a bound socket forever, every request through it
        # hanging: the quiet version of the wedge this design exists to escape.
        since = cursor()
        pid = show(CLIENT, "MainPID")
        machine.succeed(f"systemctl kill --signal=KILL {SERVER}")
        retry(lambda _: connected_again(CLIENT, pid), timeout_seconds=600)
        reasons = close_reasons(since, CLIENT)
        assert reasons != [], "the client reconnected without reporting its connection closing"
        assert not any(r.startswith("closed by peer") for r in reasons), (
            f"a SIGKILLed listener said goodbye? {reasons}"
        )
        assert "measurements" in json.loads(request(TUNNEL)), "no read through the reconnected tunnel"

    with subtest("the tunnel never sees the secret it was given"):
        # load_secret has no random fallback, so a mis-read credential fails the
        # unit outright rather than silently swapping identity -- but the key must
        # also not leak into the journal, the environment or argv on the way in.
        secret = machine.succeed(
            "${pkgs.systemd}/bin/systemd-creds decrypt --name=iroh-secret"
            f" {SERVER_CRED}/iroh-secret -"
        ).strip()
        machine.fail(f"journalctl -u mp-tunnel-server.service | grep -F '{secret}'")
        machine.fail(f"systemctl show mp-tunnel-server.service -p Environment | grep -F '{secret}'")
        machine.fail(f"ps axww | grep -v grep | grep -F '{secret}'")
  '';
}
