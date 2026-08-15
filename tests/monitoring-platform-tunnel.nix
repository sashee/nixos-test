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

  testScript = ''
    import json

    doh_ipv4 = json.loads('${dohIpv4Json}')
    doh_ipv6 = json.loads('${dohIpv6Json}')

    RECEIVER = "/run/monitoring-platform/monitoring-platform.sock"
    TUNNEL = "/run/mp-tunnel/upstream.sock"
    SERVER_CRED = "/etc/credentials/mp-tunnel/server"
    CLIENT_CRED = "/etc/credentials/mp-tunnel/client"


    def measurements(params="limit=5000"):
        # root is not in the monitoring-platform group but bypasses the 0750
        # runtime directory anyway, so no extra client user is needed.
        raw = machine.succeed(
            f"curl -sS --unix-socket {RECEIVER} 'http://localhost/v1/measurements?{params}'"
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

    with subtest("provisioning both blobs brings the tunnel up"):
        # At runtime, in the booted guest: systemd-creds binds the blob to the host
        # key in /var/lib/systemd/credential.secret, which does not exist in the
        # store and is not set up while activation runs.
        machine.succeed(f"install -d -m 0700 {SERVER_CRED} {CLIENT_CRED}")
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

        machine.succeed("systemctl start mp-tunnel-server.service mp-tunnel-client.service")
        machine.wait_for_unit("mp-tunnel-server.service")
        machine.wait_for_unit("mp-tunnel-client.service")

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
            f" {RECEIVER} 'http://localhost/v1/measurements?limit=1'"
            " | ${pkgs.jq}/bin/jq '.measurements | length')\" -ge 1",
            timeout=300,
        )
        types = {m["type"] for m in measurements()}
        assert "system.host" in types, f"no host record arrived through the tunnel: {types}"

    with subtest("the far side going away costs no data"):
        # What a real split deployment does all the time. The collector's kept
        # HTTP/1.1 connection dies with the tunnel, delivery fails, and the batch
        # stays queued rather than being dropped -- then lands once the far side
        # is back. This is also what proves the client half closes the local
        # connection on a failed dial: a socket held open would look to the
        # collector like a healthy peer that had merely gone quiet, and it would
        # sit in its 30-second timeout instead of retrying.
        before = len(measurements())
        failures_before = delivery_failures()
        machine.succeed("systemctl stop mp-tunnel-server.service")
        produce()
        for _ in range(90):
            if delivery_failures() > failures_before:
                break
            machine.sleep(2)
        else:
            raise Exception("the collector never reported a failed delivery")
        assert len(measurements()) == before, "a measurement arrived with the far side stopped"

        machine.succeed("systemctl reset-failed mp-tunnel-server.service")
        machine.succeed("systemctl start mp-tunnel-server.service")
        machine.wait_for_unit("mp-tunnel-server.service")
        machine.wait_until_succeeds(
            "test \"$(curl -sS --unix-socket"
            f" {RECEIVER} 'http://localhost/v1/measurements?limit=5000'"
            f" | ${pkgs.jq}/bin/jq '.measurements | length')\" -gt {before}",
            timeout=300,
        )

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
