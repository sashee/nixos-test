{ nixpkgs, pkgs, machineModule, stateVersion, dohStamps }:

let
  irohSsh = pkgs.callPackage ../packages/iroh-ssh/package.nix { };

  # iroh's default (n0) relays all live under this domain with a single region
  # label in front (use1-1, euc1-1, ...). Match the whole domain by suffix /
  # wildcard rather than hardcoding the regional endpoints, so new or renamed
  # regions don't silently drift the test.
  relayDomain = "relay.n0.iroh.link";

  # Endpoint-id discovery lives under this domain: the canonical (id-only) ticket
  # carries no relay url, so the dialing side resolves
  # `_iroh.<z32-endpoint-id>.dns.iroh.link TXT` to find the endpoint.
  discoveryDomain = "dns.iroh.link";

  # Handed back as the discovered home relay. Every relay hostname resolves to the
  # one impersonated relay node, so which region label we advertise does not
  # matter -- the relay routes by endpoint id. Trailing dot matches how iroh's own
  # defaults spell these urls.
  discoveredRelayUrl = "https://euc1-1.${relayDomain}.";

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
          # Endpoint-id discovery, for any id: the canonical ticket has no relay
          # url, so this is the only way the dialing side finds the listener.
          # Answering statically keeps the node stock -- it still publishes to the
          # (unreachable) real pkarr relay and resolves through its own DoH path.
          if name.startswith("_iroh.") and name.endswith(".${discoveryDomain}"):
              if qtype == 16:
                  return txt(query, "relay=${discoveredRelayUrl}")
              return nodata(query)       # fall back to TXT
          return nxdomain(query)         # bootstrap, everything else
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
    # Short failsafe timings so the no-credential phase reaches the port-22
    # opening quickly and the close-on-recovery lands within one short probe
    # (production defaults: 15 minutes / hourly / 30 seconds).
    common.irohSsh.failsafe.delaySeconds = 15;
    common.irohSsh.failsafe.probeIntervalSeconds = 5;
    common.irohSsh.failsafe.recheckIntervalSeconds = 5;

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
        # eth1's static address is assigned by network-addresses-eth1.service,
        # which under slow TCG boots can land seconds after the units we wait
        # for; retry until it appears. grep . turns empty jq output (exit 0)
        # into a failure so a missing address can't leak out as "".
        return node.wait_until_succeeds(
            "${pkgs.iproute2}/bin/ip -j -4 addr show dev eth1 "
            "| ${pkgs.jq}/bin/jq -r '.[0].addr_info[] | select(.prefixlen==24) | .local' "
            "| ${pkgs.gnugrep}/bin/grep .",
            timeout=120,
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

    # Authorize the client's key up front: used first to prove the failsafe
    # opening really admits an operator over the LAN, later through the tunnel.
    client.succeed("mkdir -p /root/.ssh && ssh-keygen -t ed25519 -N \"\" -f /root/.ssh/id_ed25519")
    pubkey = client.succeed("cat /root/.ssh/id_ed25519.pub").strip()
    server.succeed(f"install -d -m 0700 /root/.ssh && printf '%s\n' '{pubkey}' > /root/.ssh/authorized_keys && chmod 0600 /root/.ssh/authorized_keys")

    # Failsafe: no credential yet, so the tunnel cannot come up; after
    # delaySeconds of not-ready the watchdog opens port 22 in the firewall so
    # the operator can still ssh in over the local network (sshd is key-only).
    nft_chain = "${pkgs.nftables}/bin/nft list chain inet nixos-fw input-allow"
    server.wait_for_unit("iroh-ssh-failsafe.service")
    server.wait_until_succeeds(f"{nft_chain} | grep -F 'iroh-ssh-failsafe'", timeout=120)
    client.wait_until_succeeds(
        "ssh -o StrictHostKeyChecking=no root@iroh-server hostname | grep -qx iroh-server",
        timeout=60,
    )

    # The engagement leaves a timestamp on disk (read by monitoring so a
    # fallback that recovered before the next run is still reported).
    first_engaged = int(server.succeed("cat /var/lib/iroh-ssh-failsafe/last-engaged").strip())

    # The grace period is honored: the watchdog logs the downtime it counted
    # when opening, so the first opening must not have come earlier than
    # delaySeconds. Log-based, so no racy wall-clock window measuring.
    downtime = int(server.succeed(
        "journalctl -u iroh-ssh-failsafe.service -o cat"
        " | grep -oE 'not answering for [0-9]+ seconds' | head -n1"
        " | grep -oE '[0-9]+'"
    ).strip())
    assert downtime >= 15, f"failsafe opened after only {downtime}s (delaySeconds=15)"

    # A firewall reload atomically replaces the nixos-fw table, wiping the
    # runtime rule; while the tunnel is still down the watchdog re-inserts it
    # within one recheck. (No rule-absent assertion in between — it would
    # race the short recheck interval.)
    server.succeed("systemctl restart nftables.service")
    server.wait_until_succeeds(f"{nft_chain} | grep -F 'iroh-ssh-failsafe'", timeout=60)

    # Provision the iroh key at runtime with iroh's own generator (no hardcoded
    # key size, future-proof). Generated to a file so the secret never lands in
    # argv; the plaintext is captured only to assert later that it does not
    # leak, then removed. This mirrors the operator flow in the README.
    #
    # The generator's stderr is kept, not discarded: it prints the connect
    # command operators are told to save (docs/rpi5-rescue.md), and that ticket
    # must be byte-identical to the one the provisioned host publishes — both
    # derive it from the key with id_ticket. Nothing else pins that promise.
    server.succeed("install -d -m 0700 /etc/credentials/iroh-ssh")
    server.succeed("${irohSsh}/bin/iroh-ssh-generate-secret > /root/k 2>/root/k.ticket")
    secret = server.succeed("cat /root/k").strip()
    generated = server.succeed(
        "grep -oE 'endpoint[a-z0-9]+' /root/k.ticket | tail -n1"
    ).strip()
    server.succeed(
        "${pkgs.systemd}/bin/systemd-creds encrypt --name=iroh-secret"
        " /root/k /etc/credentials/iroh-ssh/iroh-secret"
    )
    server.succeed("rm -f /root/k /root/k.ticket")

    # Unit shape: encrypted credential, sandboxed dynamic user.
    server.succeed("systemctl cat iroh-ssh.service | grep -F 'LoadCredentialEncrypted=iroh-secret:/etc/credentials/iroh-ssh/iroh-secret'")
    server.succeed("systemctl cat iroh-ssh.service | grep -F 'DynamicUser=true'")
    server.succeed("systemctl cat iroh-ssh.service | grep -F 'MemoryDenyWriteExecute=true'")
    server.succeed("systemctl cat iroh-ssh.service | grep -F 'ProcSubset=pid'")
    server.succeed("systemctl cat iroh-ssh.service | grep -F '~@resources'")

    # The listener publishes the ticket the failsafe probes (ExecStartPre), so it
    # cannot drift from the credential the listener loaded.
    server.succeed("systemctl cat iroh-ssh.service | grep -F 'RuntimeDirectory=iroh-ssh'")
    server.succeed("systemctl cat iroh-ssh.service | grep -F 'RuntimeDirectoryMode=0700'")
    # The long-running failsafe must never be handed the secret; it reads the file.
    server.fail("systemctl cat iroh-ssh-failsafe.service | grep -F 'LoadCredential'")

    # Fetch this run's short ticket (node id + relay url). The listener prints it
    # only after reaching the (impersonated) relay; if the 5s online timeout
    # expires under boot load it logs a warning and prints a relay-less ticket,
    # so restart until an invocation connects cleanly (no warning).
    def relay_ticket():
        for _ in range(6):
            # reset-failed: this helper is called several times and retries
            # inside, and enough back-to-back restarts trip the unit's default
            # start rate limit — which would fail the restart itself rather than
            # the thing under test.
            server.succeed("systemctl reset-failed iroh-ssh.service")
            server.succeed("systemctl restart iroh-ssh.service")
            inv = server.succeed("systemctl show -p InvocationID --value iroh-ssh.service").strip()
            j = f"journalctl _SYSTEMD_INVOCATION_ID={inv} -o cat"
            server.wait_until_succeeds(f"test \"$({j} | grep -cE 'endpoint[a-z0-9]+')\" -ge 2", timeout=60)
            if server.execute(f"{j} | grep -qF 'Failed to connect to the home relay'")[0] != 0:
                return server.succeed(f"{j} | grep -oE 'endpoint[a-z0-9]+' | tail -n1").strip()
        raise Exception("listener never reached the impersonated relay")

    ticket = relay_ticket()

    # Published in ExecStartPre, so it exists as soon as the listener has started
    # — no wait, no relay contact, and no unit started by hand. grep .: an empty
    # file must not pass as a ticket.
    published = server.succeed("grep . /run/iroh-ssh/ticket").strip()
    assert published.startswith("endpoint"), f"unexpected ticket: {published}"

    # What the generator printed when the key was created is what the host now
    # publishes. This is the promise docs/rpi5-rescue.md asks operators to rely
    # on when they save that connect command, and the whole basis for verifying a
    # rotation before committing to it.
    assert published == generated, \
        f"generator and host disagree: {generated} vs {published}"

    # Root-only: the failsafe is the only reader and it runs as root, so nothing
    # else should get at the file. Asserted by an actual unprivileged read, not
    # from the unit's mode settings — an earlier revision published this
    # world-readable on purpose and the mode bits said so while the behaviour
    # disagreed.
    mode = server.succeed("stat -c %a /run/iroh-ssh/ticket").strip()
    assert mode == "600", f"ticket mode is {mode}, expected 600"
    server.fail("${pkgs.util-linux}/bin/runuser -u nobody -- cat /run/iroh-ssh/ticket")

    # Where the reason for that lives: DynamicUser plus RuntimeDirectoryPreserve
    # makes systemd keep the real directory in /run/private (0700 root:root) and
    # leave /run/iroh-ssh as a symlink into it, so the directory mode above is
    # belt-and-braces and *no* setting of it could expose the ticket. Pinned here
    # because it is surprising, it is what made the earlier revision's
    # RuntimeDirectoryMode=0755 a dead letter, and exec-invoke.c carries a stale
    # comment claiming runtime directories are exempt.
    server.succeed("test -L /run/iroh-ssh")
    assert server.succeed("readlink /run/iroh-ssh").strip() == "private/iroh-ssh"
    private_mode = server.succeed("stat -c '%a %U:%G' /run/private").strip()
    assert private_mode == "700 root:root", f"/run/private is {private_mode}"

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

    # That restart re-ran ExecStartPre: a pure function of the secret reproduces
    # the ticket byte for byte rather than drifting.
    again = server.succeed("cat /run/iroh-ssh/ticket").strip()
    assert again == published, f"ticket not reproducible: {published} vs {again}"

    # Same identity from both directions: the published ticket is the same node id
    # the listener advertises, just without the relay-url tail — so it is strictly
    # shorter and shares the id prefix.
    assert len(os.path.commonprefix([published, ticket])) >= 50, \
        f"published ticket is a different node id: {published} vs {ticket}"
    assert len(published) < len(ticket), \
        f"published ticket should carry no relay url: {published} vs {ticket}"

    # The tunnel is ready (relay_ticket saw a clean start), so the failsafe
    # closes its port-22 opening within one poll; wait rather than race it.
    # This now also proves the id-only dial works: the probe resolves the endpoint
    # id through discovery, with no relay url to short-circuit it.
    server.wait_until_succeeds(
        f"test -z \"$({nft_chain} | grep -F 'iroh-ssh-failsafe' || true)\"",
        timeout=60,
    )

    # Port 22 is closed to the network again; the tunnel is the only way in.
    client.fail("${pkgs.python3}/bin/python3 -c \"import socket; socket.create_connection(('iroh-server', 22), timeout=2)\"")

    # End-to-end: ssh through the tunnel with the short ticket, stock client.
    hostname = client.wait_until_succeeds(
        "ssh -o StrictHostKeyChecking=no"
        f" -o ProxyCommand='iroh-ssh-connect {ticket}' root@tunnel hostname",
        timeout=180,
    ).strip()
    assert hostname == "iroh-server", f"unexpected hostname: {hostname}"

    # End-to-end on the operator's actual path: the canonical id-only ticket, which
    # has no relay url and so must be resolved through endpoint-id discovery.
    hostname = client.wait_until_succeeds(
        "ssh -o StrictHostKeyChecking=no"
        f" -o ProxyCommand='iroh-ssh-connect {published}' root@tunnel hostname",
        timeout=180,
    ).strip()
    assert hostname == "iroh-server", f"unexpected hostname: {hostname}"

    # Half a rotation is inert. The documented flow (docs/rpi5-rescue.md) stages a
    # new credential under a new directory and only then changes
    # credentialDirectory in the repo, so a host routinely holds a blob it is not
    # using yet. Nothing may react to that: no unit watches the secret, the
    # published ticket keeps naming the identity the listener actually answers on,
    # and the failsafe stays closed. Getting this wrong is what would hold port 22
    # open indefinitely against a perfectly healthy tunnel.
    server.succeed("install -d -m 0700 /etc/credentials/iroh-ssh-2")
    server.succeed("${irohSsh}/bin/iroh-ssh-generate-secret > /root/k2 2>/dev/null")
    server.succeed(
        "${pkgs.systemd}/bin/systemd-creds encrypt --name=iroh-secret"
        " /root/k2 /etc/credentials/iroh-ssh-2/iroh-secret"
    )
    # Long enough that a failsafe which had started counting would have opened the
    # port by now (delaySeconds=15, recheckIntervalSeconds=5).
    server.sleep(25)
    staged = server.succeed("cat /run/iroh-ssh/ticket").strip()
    assert staged == published, \
        f"staging a second credential moved the ticket: {published} vs {staged}"
    server.succeed(f"test -z \"$({nft_chain} | grep -F 'iroh-ssh-failsafe' || true)\"")

    # And the ticket does follow the credential, on the restart that a
    # credentialDirectory change performs. Overwriting the blob in place is the
    # same event from the unit's point of view (a different key behind the same
    # LoadCredentialEncrypted path) without needing a second system closure, so
    # this is where the specialisation switch would otherwise go.
    server.succeed("rm -f /etc/credentials/iroh-ssh/iroh-secret")
    server.succeed(
        "${pkgs.systemd}/bin/systemd-creds encrypt --name=iroh-secret"
        " /root/k2 /etc/credentials/iroh-ssh/iroh-secret"
    )
    server.succeed("rm -f /root/k2")

    third = relay_ticket()
    rotated = server.succeed("cat /run/iroh-ssh/ticket").strip()
    assert rotated != published, "ticket did not follow the rotated credential"
    assert len(os.path.commonprefix([rotated, third])) >= 50, \
        f"published ticket does not match the rotated listener: {rotated} vs {third}"

    # And the probe follows the rotation end to end: this only closes if the
    # failsafe dialed the *new* id through discovery and got sshd's banner back.
    server.wait_until_succeeds(
        f"test -z \"$({nft_chain} | grep -F 'iroh-ssh-failsafe' || true)\"",
        timeout=120,
    )

    # Failure while the tunnel service keeps running: with sshd stopped the
    # probe still connects over iroh but gets no banner back, so the failsafe
    # engages — unit-state inspection would never notice this; only the
    # end-to-end probe does. Recovery closes the port again.
    server.succeed("systemctl stop sshd.service")
    server.wait_until_succeeds(f"{nft_chain} | grep -F 'iroh-ssh-failsafe'", timeout=120)
    server.succeed("systemctl is-active --quiet iroh-ssh.service")

    # Each engagement refreshes the on-disk timestamp.
    second_engaged = int(server.succeed("cat /var/lib/iroh-ssh-failsafe/last-engaged").strip())
    assert second_engaged > first_engaged, "failsafe did not refresh last-engaged on re-engagement"
    server.succeed("systemctl start sshd.service")
    server.wait_until_succeeds(
        f"test -z \"$({nft_chain} | grep -F 'iroh-ssh-failsafe' || true)\"",
        timeout=60,
    )
  '';
}
