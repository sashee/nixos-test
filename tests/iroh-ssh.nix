{ nixpkgs, pkgs, machineModule, stateVersion, dohStamps }:

let
  irohSsh = pkgs.callPackage ../packages/iroh-ssh/package.nix { };

  # iroh's default (n0) relays all live under this domain with a single region
  # label in front (use1-1, euc1-1, ...). Match the whole domain by suffix /
  # wildcard rather than hardcoding the regional endpoints, so new or renamed
  # regions don't silently drift the test.
  relayDomain = "relay.n0.iroh.link";

  # DoH interception (shared harness): impersonate the deployed DoH upstreams so
  # the stock nodes resolve the relay hostnames to our relay node.
  interceptor = import ./doh-interceptor.nix {
    inherit pkgs dohStamps;
    name = "iroh-ssh";
    respond = ''
      def respond(query, meta):
          name, qtype, _, _ = read_question(query)
          if name.endswith(".${relayDomain}") and qtype == 1:
              return a(query, ARGS[0])   # ARGS[0] = the relay node's IP
          if name.endswith(".${relayDomain}"):
              return nodata(query)       # fall back to A
          return nxdomain(query)         # dns.iroh.link discovery, bootstrap, ...
    '';
  };
  dohIpv4Json = builtins.toJSON interceptor.dohIpv4;
  dohIpv6Json = builtins.toJSON interceptor.dohIpv6;

  # The impersonated relay's own cert (relay hostnames only) — a separate
  # concern from the DoH upstream, so a separate cert + CA. One wildcard SAN
  # covers every region (rustls matches a single leftmost label).
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

  # Applied to the stock nodes: trust both test CAs (DoH upstream + relay). No
  # DNS/hosts/relay config change -- resolution and relay selection stay as shipped.
  trustTestCa = { security.pki.certificateFiles = [ interceptor.caFile relayCert.caFile ]; };
in
nixpkgs.lib.nixos.runTest {
  name = "iroh-ssh";
  hostPkgs = pkgs;
  skipTypeCheck = true;
  # Ceiling, not a wait: the rpi variant runs under TCG emulation on the
  # KVM-less aarch64 CI runner and needs the room (4 nodes).
  globalTimeout = 2400;

  # The DoH interceptor: hijacks the DoH upstream IPs and answers the relay
  # hostnames with the relay node's address. Binds 0.0.0.0:443, so it lives on
  # its own node (not sharing 443 with the relay). Not a laptop node.
  nodes.dohpeer = { nodes, ... }: {
    networking = {
      hostName = "dohpeer";
      firewall.enable = false;
    };

    # Helper node, tiny workload: keep the 4-node test within the 4 GB Pi.
    virtualisation.memorySize = 512;

    # Assigns the DoH provider IPs and answers the relay hostnames with the
    # relay node's IP (passed as the server's argv).
    systemd.services.fake-doh = interceptor.mkService {
      args = [ nodes.relay.networking.primaryIPAddress ];
    };

    system.stateVersion = stateVersion;
  };

  # The impersonated relay. Plain node, 443 free for iroh-relay.
  nodes.relay = { ... }: {
    networking.hostName = "relay";

    # Helper node, tiny workload: keep the 4-node test within the 4 GB Pi.
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

  # The machine under test: the real host module (laptop or rpi), unmodified
  # except for the required credential dir and trusting the test CA.
  # Default-deny firewall ON. mkForce: the rpi config enables auto-upgrade.
  nodes.server = { lib, ... }: {
    imports = [ machineModule trustTestCa ];

    networking.hostName = "iroh-server";
    common.autoUpgrade.enable = lib.mkForce false;
    common.monitoring.enable = lib.mkForce false;
    common.irohSsh.credentialDirectory = "/etc/credentials/iroh-ssh";

    system.stateVersion = stateVersion;
  };

  # The connecting machine: the same stock config (so it resolves and dials
  # the relay through the same real path), plus the iroh-ssh client.
  nodes.client = { lib, ... }: {
    imports = [ machineModule trustTestCa ];

    networking.hostName = "iroh-client";
    common.autoUpgrade.enable = lib.mkForce false;
    common.monitoring.enable = lib.mkForce false;
    common.irohSsh.enable = lib.mkForce false;
    environment.systemPackages = [ irohSsh ];

    system.stateVersion = stateVersion;
  };

  testScript = ''
    import json
    import os

    doh_ipv4 = json.loads('${dohIpv4Json}')
    doh_ipv6 = json.loads('${dohIpv6Json}')

    dohpeer.start()
    relay.start()
    dohpeer.wait_for_unit("fake-doh.service")
    relay.wait_for_unit("iroh-relay.service")

    def vlan_ip(node):
        return node.succeed(
            "${pkgs.iproute2}/bin/ip -j -4 addr show dev eth1 "
            "| ${pkgs.jq}/bin/jq -r '.[0].addr_info[] | select(.prefixlen==24) | .local'"
        ).strip()

    dohpeer_ip = vlan_ip(dohpeer)

    def redirect_doh(node):
        # Route the DoH upstream IPs to the interceptor. dnscrypt-proxy then
        # reaches the fake DoH server without the node knowing anything changed.
        for ip in doh_ipv4:
            node.succeed(f"${pkgs.iproute2}/bin/ip route replace {ip}/32 via {dohpeer_ip} dev eth1")
        for ip in doh_ipv6:
            node.succeed(f"${pkgs.iproute2}/bin/ip -6 route replace {ip}/128 dev eth1")

    for node in [server, client]:
        node.start()
        node.wait_for_unit("multi-user.target")
        redirect_doh(node)
        node.succeed("systemctl restart dnscrypt-proxy.service")

    server.wait_for_unit("sshd.service")

    # Provision the iroh key at runtime with iroh's own generator (no hardcoded
    # key size, future-proof). Generated to a file so the secret never lands in
    # argv; the plaintext is captured only to assert later that it does not
    # leak, then removed. This mirrors the operator flow in the README.
    server.succeed("install -d -m 0700 /etc/credentials/iroh-ssh")
    server.succeed("${irohSsh}/bin/iroh-ssh-generate-secret > /root/k 2>/dev/null")
    secret = server.succeed("cat /root/k").strip()
    server.succeed(
        "${pkgs.systemd}/bin/systemd-creds encrypt --name=iroh-secret"
        " /root/k /etc/credentials/iroh-ssh/iroh-secret"
    )
    server.succeed("rm -f /root/k")

    # Unit shape: encrypted credential, sandboxed dynamic user.
    server.succeed("systemctl cat iroh-ssh.service | grep -F 'LoadCredentialEncrypted=iroh-secret:/etc/credentials/iroh-ssh/iroh-secret'")
    server.succeed("systemctl cat iroh-ssh.service | grep -F 'DynamicUser=true'")
    server.succeed("systemctl cat iroh-ssh.service | grep -F 'MemoryDenyWriteExecute=true'")
    server.succeed("systemctl cat iroh-ssh.service | grep -F 'ProcSubset=pid'")
    server.succeed("systemctl cat iroh-ssh.service | grep -F '~@resources'")

    # Fetch this run's short ticket (node id + relay url). The listener prints it
    # only after reaching the (impersonated) relay; if the 5s online timeout
    # expires under boot load it logs a warning and prints a relay-less ticket,
    # so restart until an invocation connects cleanly (no warning).
    def relay_ticket():
        for _ in range(6):
            server.succeed("systemctl restart iroh-ssh.service")
            inv = server.succeed("systemctl show -p InvocationID --value iroh-ssh.service").strip()
            j = f"journalctl _SYSTEMD_INVOCATION_ID={inv} -o cat"
            server.wait_until_succeeds(f"test \"$({j} | grep -cE 'endpoint[a-z0-9]+')\" -ge 2", timeout=60)
            if server.execute(f"{j} | grep -qF 'Failed to connect to the home relay'")[0] != 0:
                return server.succeed(f"{j} | grep -oE 'endpoint[a-z0-9]+' | tail -n1").strip()
        raise Exception("listener never reached the impersonated relay")

    ticket = relay_ticket()

    # The provisioned secret never leaks into the service journal, environment,
    # or argv. (load_secret has no random fallback, so a mis-read credential
    # fails the service outright rather than silently swapping identity.)
    server.fail(f"journalctl -u iroh-ssh.service | grep -F '{secret}'")
    server.fail(f"systemctl show iroh-ssh.service -p Environment | grep -F '{secret}'")
    server.fail(f"ps axww | grep -v grep | grep -F '{secret}'")

    # Stable identity: a restart reproduces the same node id. iroh may pick a
    # different home relay among the impersonated hostnames, changing the
    # relay-url tail of the short ticket, so compare the node-id prefix (~59
    # base32 chars) rather than the whole ticket.
    second = relay_ticket()
    assert len(os.path.commonprefix([ticket, second])) >= 50, \
        f"node id changed across restart: {ticket} vs {second}"

    # Port 22 stays closed to the network; the tunnel is the only way in.
    client.fail("${pkgs.python3}/bin/python3 -c \"import socket; socket.create_connection(('iroh-server', 22), timeout=2)\"")

    # End-to-end: ssh through the tunnel with the short ticket, stock client.
    client.succeed("mkdir -p /root/.ssh && ssh-keygen -t ed25519 -N \"\" -f /root/.ssh/id_ed25519")
    pubkey = client.succeed("cat /root/.ssh/id_ed25519.pub").strip()
    server.succeed(f"install -d -m 0700 /root/.ssh && printf '%s\n' '{pubkey}' > /root/.ssh/authorized_keys && chmod 0600 /root/.ssh/authorized_keys")

    hostname = client.wait_until_succeeds(
        "ssh -o StrictHostKeyChecking=no"
        f" -o ProxyCommand='iroh-ssh-connect {ticket}' root@tunnel hostname",
        timeout=180,
    ).strip()
    assert hostname == "iroh-server", f"unexpected hostname: {hostname}"
  '';
}
