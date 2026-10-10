{ nixpkgs, pkgs, machineModule, stateVersion, dohStamps }:

let
  irohSsh = pkgs.callPackage ../packages/iroh-ssh/package.nix { };

  # The impersonated-n0 harness of tests/monitoring-platform-tunnel.nix, unchanged: the
  # relay hostnames and the endpoint-id discovery domain resolve to nodes in this test,
  # so an id-only ticket -- the form a device saves -- can be dialed with the node under
  # test left stock.
  relayDomain = "relay.n0.iroh.link";
  discoveryDomain = "dns.iroh.link";
  discoveredRelayUrl = "https://euc1-1.${relayDomain}.";

  interceptor = import ./doh-interceptor.nix {
    inherit pkgs dohStamps;
    name = "pw-mgr-tunnel";
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
  name = "pw-mgr-tunnel";
  hostPkgs = pkgs;
  skipTypeCheck = true;
  # Ceiling, not a wait: the aarch64 variant runs under TCG on the KVM-less CI
  # runner, and relay handshakes are not quick there.
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

  # The deployed rpi5 config, plus the laptop's half of the path run beside it in
  # transient units: one fewer VM under TCG, and the bytes still cross a QUIC
  # connection dialed by endpoint-id discovery against the impersonated relay -- the
  # same shortcut, and the same reasoning, as tests/monitoring-platform-tunnel.nix.
  nodes.machine = { lib, ... }: {
    imports = [
      machineModule
      { security.pki.certificateFiles = [ interceptor.caFile relayCert.caFile ]; }
    ];

    networking.hostName = "pw-mgr-tunnel-host";
    common.autoUpgrade.enable = lib.mkForce false;
    common.monitoring.enable = lib.mkForce false;
    # Not the subject here, and its failsafe would spend the test opening port 22
    # against a credential this test never provisions.
    common.irohSsh.enable = lib.mkForce false;

    system.stateVersion = stateVersion;
  };

  testScript = { nodes, ... }:
    let
      backend = nodes.machine.services.pw-mgr;
    in
    ''
    import json

    doh_ipv4 = json.loads('${dohIpv4Json}')
    doh_ipv6 = json.loads('${dohIpv6Json}')

    # Read off the node's own options rather than restated, so this asserts the
    # wiring against whatever upstream's module defaults to.
    BACKEND = "${backend.socketPath}"
    BACKEND_GROUP = "${backend.group}"
    CRED = "/etc/credentials/pw-mgr-tunnel"

    # The laptop's half of the path (hosts/rpi5 documents it for the operator):
    # iroh-uds-connect serving a local socket, socat putting a loopback port in front.
    LAPTOP_SOCKET = "/run/pwm-laptop/pw-mgr.sock"
    PORT = 8080


    def via_shim(args, host=None):
        header = f"-H 'Host: {host}' " if host else ""
        return machine.succeed(f"curl -sS -i {header}{args}")


    def status(response):
        return int(response.splitlines()[0].split()[1])


    def body(response):
        return response.split("\r\n\r\n", 1)[1]


    def login_start(host, origin):
        # A passkey ceremony's first step: it needs no account, writes the ceremony to
        # the database, and answers with an RP ID derived from the Host header. So one
        # request shows the Host survived the tunnel, the Origin check judged it, and
        # the backend can write its state from inside its sandbox.
        return via_shim(
            f"-X POST -H 'Content-Type: application/json' -H 'Origin: {origin}' "
            f"--data '{{}}' http://127.0.0.1:{PORT}/api/v1/auth/login/start",
            host=host,
        )


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

    machine.wait_for_unit("pw-mgr.service")
    machine.wait_until_succeeds(f"test -S {BACKEND}", timeout=120)

    with subtest("the tunnel forwards to the backend's socket, sandboxed"):
        unit = machine.succeed("systemctl cat pw-mgr-tunnel.service")
        assert f"iroh-uds-listen {BACKEND}" in unit, f"not forwarding to the backend:\n{unit}"
        # The group whose 0750 socket directory is the actual access control.
        assert f"SupplementaryGroups={BACKEND_GROUP}" in unit, unit
        assert f"LoadCredentialEncrypted=iroh-secret:{CRED}/iroh-secret" in unit, unit
        assert "DynamicUser=true" in unit, unit
        assert "MemoryDenyWriteExecute=true" in unit, unit
        assert "~@resources" in unit, unit

    with subtest("an unprovisioned tunnel skips rather than crash-loops"):
        result = machine.succeed(
            "systemctl show pw-mgr-tunnel.service -p ConditionResult --value"
        ).strip()
        assert result == "no", f"ConditionResult={result}"
        machine.fail("systemctl is-active --quiet pw-mgr-tunnel.service")
        machine.fail("systemctl is-failed --quiet pw-mgr-tunnel.service")

    with subtest("provisioning the secret brings the tunnel up"):
        # At runtime, in the booted guest: systemd-creds binds the blob to the host
        # key in /var/lib/systemd/credential.secret, which does not exist in the
        # store and is not set up while activation runs.
        machine.succeed(f"install -d -m 0700 {CRED}")
        machine.succeed("${irohSsh}/bin/iroh-ssh-generate-secret > /root/k 2>/dev/null")
        machine.succeed(
            "${pkgs.systemd}/bin/systemd-creds encrypt --name=iroh-secret"
            f" /root/k {CRED}/iroh-secret"
        )
        machine.succeed("rm -f /root/k")
        machine.succeed("systemctl start pw-mgr-tunnel.service")
        machine.wait_for_unit("pw-mgr-tunnel.service")

        # The ticket a device saves, re-derived from the blob exactly as hosts/rpi5
        # tells the operator to.
        ticket = machine.succeed(
            "${pkgs.systemd}/bin/systemd-creds decrypt --name=iroh-secret"
            f" {CRED}/iroh-secret - | ${irohSsh}/bin/iroh-ssh-ticket /dev/stdin"
        ).strip()
        assert ticket.startswith("endpoint"), f"unexpected ticket: {ticket}"

    with subtest("a browser on the laptop's loopback port reaches the backend over iroh"):
        machine.succeed(
            "systemd-run --unit=pwm-laptop-connect -p RuntimeDirectory=pwm-laptop"
            f" ${irohSsh}/bin/iroh-uds-connect {LAPTOP_SOCKET} {ticket}"
        )
        machine.wait_until_succeeds(f"test -S {LAPTOP_SOCKET}", timeout=60)
        machine.succeed(
            "systemd-run --unit=pwm-laptop-shim ${pkgs.socat}/bin/socat"
            f" TCP-LISTEN:{PORT},bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:{LAPTOP_SOCKET}"
        )
        machine.wait_for_open_port(PORT)

        # The first stream pays for relay registration and discovery, so retry it.
        machine.wait_until_succeeds(
            f"curl -sS --fail -H 'Host: localhost:{PORT}' http://127.0.0.1:{PORT}/healthz",
            timeout=300,
        )

        # The frontend comes through the same socket (SPEC §8.6), with its CSP.
        page = via_shim(f"http://127.0.0.1:{PORT}/", host=f"localhost:{PORT}")
        assert status(page) == 200, page
        assert "content-security-policy:" in page.lower(), page
        assert "<html" in body(page).lower(), page

    with subtest("the Host header crosses the tunnel intact, and the backend judges it"):
        # `localhost` with the laptop's port -- the origin a passkey is registered on.
        started = login_start(f"localhost:{PORT}", f"http://localhost:{PORT}")
        assert status(started) == 200, started
        assert json.loads(body(started))["options"]["rpId"] == "localhost", started

        # A `<label>.localhost` name is its own RP ID: the Android app's path.
        started = login_start(f"vault.localhost:{PORT}", f"http://vault.localhost:{PORT}")
        assert status(started) == 200, started
        assert json.loads(body(started))["options"]["rpId"] == "vault.localhost", started

        # An Origin on another port of the same host is refused (SPEC §6.1), so another
        # page on the laptop's loopback cannot drive the vault through the shim.
        refused = login_start(f"localhost:{PORT}", "http://localhost:3000")
        assert status(refused) == 403, refused

        # An IP literal is not a loopback name: refused before anything else.
        refused = via_shim(f"http://127.0.0.1:{PORT}/healthz", host=f"127.0.0.1:{PORT}")
        assert status(refused) == 400, refused
        assert "unknown_host" in refused, refused

    with subtest("the backend restarting under the tunnel costs nothing"):
        # As a deploy or a crash does. The tunnel dials the socket per stream, so it
        # must ride the restart out without being restarted itself.
        tunnel_pid = machine.succeed("systemctl show pw-mgr-tunnel.service -p MainPID --value").strip()
        machine.succeed("systemctl restart pw-mgr.service")
        machine.wait_for_unit("pw-mgr.service")
        machine.wait_until_succeeds(
            f"curl -sS --fail -H 'Host: localhost:{PORT}' http://127.0.0.1:{PORT}/healthz",
            timeout=120,
        )
        after = machine.succeed("systemctl show pw-mgr-tunnel.service -p MainPID --value").strip()
        assert after == tunnel_pid, f"the tunnel restarted with the backend: {tunnel_pid} -> {after}"

    with subtest("a saved ticket survives the tunnel restarting"):
        # The identity comes from the credential, not from the process, so the ticket
        # every device has saved keeps working -- the property the app depends on.
        machine.succeed("systemctl restart pw-mgr-tunnel.service")
        machine.wait_for_unit("pw-mgr-tunnel.service")
        machine.wait_until_succeeds(
            f"curl -sS --fail -H 'Host: localhost:{PORT}' http://127.0.0.1:{PORT}/healthz",
            timeout=300,
        )

    with subtest("the tunnel never exposes the secret it was given"):
        secret = machine.succeed(
            "${pkgs.systemd}/bin/systemd-creds decrypt --name=iroh-secret"
            f" {CRED}/iroh-secret -"
        ).strip()
        machine.fail(f"journalctl -u pw-mgr-tunnel.service | grep -F '{secret}'")
        machine.fail(f"systemctl show pw-mgr-tunnel.service -p Environment | grep -F '{secret}'")
        machine.fail(f"ps axww | grep -v grep | grep -F '{secret}'")
  '';
}
