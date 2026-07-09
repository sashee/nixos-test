{ nixpkgs, pkgs, commonDesktopModule, stateVersion, dohStamps }:

let
  # DoH interception (shared harness). This test additionally verifies the
  # request shape (method/path/host/family) and single-family selection, so its
  # respond() also logs every request to files the testScript asserts on.
  interceptor = import ./doh-interceptor.nix {
    inherit pkgs dohStamps;
    name = "doh-upstream";
    readyFile = "/tmp/fake-doh-ready";
    respond = ''
      request_dir = pathlib.Path("/tmp/fake-doh-requests"); request_dir.mkdir(exist_ok=True)
      probe_path = pathlib.Path("/tmp/fake-doh-last-probe.json")
      def _safe(n): return n.replace(".", "_") or "root"
      def respond(query, meta):
          name, qtype, qclass, _ = read_question(query)
          rec = json.dumps({
              "family": meta["family"], "method": meta["method"], "path": meta["path"],
              "host": meta["host"], "content_type": meta["content_type"],
              "question": name, "qtype": qtype, "qclass": qclass})
          if name.endswith(".upstream-test.example"):
              (request_dir / f"{_safe(name)}-{qtype}.json").write_text(rec)
          else:
              probe_path.write_text(rec)
          if name == "ipv4.upstream-test.example" and qtype == 1:
              return a(query, "203.0.113.5")
          if name == "ipv6.upstream-test.example" and qtype == 28:
              return aaaa(query, "2001:db8::5")
          if qtype == 2:
              # root NS so dnscrypt-proxy considers the resolver healthy.
              return answer_rdata(query, b"\x02ns\xc0\x0c") if name == "" else nxdomain(query)
          return nxdomain(query)
    '';
  };
  dohIpv4Json = builtins.toJSON interceptor.dohIpv4;
  dohIpv6Json = builtins.toJSON interceptor.dohIpv6;
  dohDomainsJson = builtins.toJSON interceptor.dohDomains;
in
nixpkgs.lib.nixos.runTest {
  name = "doh-upstream";
  hostPkgs = pkgs;
  skipTypeCheck = true;

  nodes.ipv4Client = { pkgs, ... }: {
    imports = [ commonDesktopModule ];

    networking.hostName = "doh-upstream-ipv4";
    common.autoUpgrade.enable = false;
    common.monitoring.enable = false;
    common.irohSsh.enable = false;
    security.pki.certificateFiles = [ interceptor.caFile ];
    system.stateVersion = stateVersion;
  };

  nodes.ipv6Client = { pkgs, ... }: {
    imports = [ commonDesktopModule ];

    networking.hostName = "doh-upstream-ipv6";
    common.autoUpgrade.enable = false;
    common.monitoring.enable = false;
    common.irohSsh.enable = false;
    security.pki.certificateFiles = [ interceptor.caFile ];
    system.stateVersion = stateVersion;
  };

  nodes.dnsPeer = { pkgs, ... }: {
    networking = {
      firewall.enable = false;
      hostName = "doh-upstream-peer";
    };
    system.stateVersion = stateVersion;
  };

  testScript = ''
    import json
    import time

    doh_ipv4 = json.loads("""${dohIpv4Json}""")
    doh_ipv6 = json.loads("""${dohIpv6Json}""")
    doh_domains = json.loads("""${dohDomainsJson}""")

    def by_hostname(hostname):
        for node in machines:
            if node.succeed("hostname").strip() == hostname:
                return node
        raise Exception(f"No machine with hostname {hostname}")

    dns_peer = by_hostname("doh-upstream-peer")
    ipv4_client = by_hostname("doh-upstream-ipv4")
    ipv6_client = by_hostname("doh-upstream-ipv6")

    dns_peer.start()
    dns_peer.wait_for_unit("multi-user.target")
    dns_peer.succeed("rm -rf /tmp/fake-doh-ready /tmp/fake-doh-requests /tmp/fake-doh-last-probe.json")
    dns_peer.succeed("${pkgs.procps}/bin/sysctl -w net.ipv4.ip_forward=1")
    dns_peer.succeed("${pkgs.procps}/bin/sysctl -w net.ipv6.conf.all.forwarding=1")
    for address in doh_ipv4:
        dns_peer.succeed(f"${pkgs.iproute2}/bin/ip addr add {address}/32 dev eth1 || true")
    for address in doh_ipv6:
        dns_peer.succeed(f"${pkgs.iproute2}/bin/ip -6 addr add {address}/128 dev eth1 || true")
    dns_peer.succeed("systemd-run --unit fake-doh-server ${pkgs.python3}/bin/python3 ${interceptor.serverScript}")
    dns_peer.wait_for_unit("fake-doh-server.service")
    dns_peer.succeed("${pkgs.coreutils}/bin/timeout 10 ${pkgs.bash}/bin/bash -c 'until test -e /tmp/fake-doh-ready; do sleep 0.2; done'")

    peer_ipv4 = dns_peer.succeed("${pkgs.python3}/bin/python3 -c 'import json, subprocess; data = json.loads(subprocess.check_output([\"${pkgs.iproute2}/bin/ip\", \"-j\", \"-4\", \"addr\", \"show\", \"dev\", \"eth1\"])); print(data[0][\"addr_info\"][0][\"local\"])'").strip()
    peer_ipv6 = dns_peer.succeed("${pkgs.python3}/bin/python3 -c 'import json, subprocess; data = json.loads(subprocess.check_output([\"${pkgs.iproute2}/bin/ip\", \"-j\", \"-6\", \"addr\", \"show\", \"dev\", \"eth1\"])); print(next(addr[\"local\"] for addr in data[0][\"addr_info\"] if addr[\"scope\"] == \"global\" and addr[\"local\"].startswith(\"2001:db8:1:\")))'").strip()

    for client in [ipv4_client, ipv6_client]:
        client.start()
        client.wait_for_unit("multi-user.target")
        client.succeed("systemctl is-active dnscrypt-proxy.service")
        client.succeed("systemctl is-active nftables.service")
        client.succeed("${pkgs.nftables}/bin/nft list table inet common-doh-egress")

    ipv4_client.succeed(f"${pkgs.iproute2}/bin/ip -4 route replace default via {peer_ipv4}")
    ipv6_client.succeed("${pkgs.iproute2}/bin/ip -6 route del default || true")
    ipv6_client.succeed(f"${pkgs.iproute2}/bin/ip -6 route add default via {peer_ipv6} dev eth1 metric 42")
    for address in doh_ipv6:
        ipv4_client.succeed(f"${pkgs.iproute2}/bin/ip -6 route replace unreachable {address}/128")
    for address in doh_ipv4:
        ipv6_client.succeed(f"${pkgs.iproute2}/bin/ip route replace unreachable {address}/32")

    def check_request(path, family, question, qtype):
        request = json.loads(dns_peer.succeed(f"cat {path}"))
        assert request["family"] == family, request
        assert request["path"] == "/dns-query", request
        assert request["question"] == question, request
        assert request["qtype"] == qtype, request
        assert request["qclass"] == 1, request
        assert request["host"] in doh_domains, request

    def print_command(node, label, command):
        print(f"\n### {label}: {command}")
        status, output = node.execute(command)
        print(f"exit status: {status}")
        print(output)

    def print_route_diagnostics(node, label):
        print_command(node, label, "hostname")
        print_command(node, label, "${pkgs.iproute2}/bin/ip -br addr")
        print_command(node, label, "${pkgs.iproute2}/bin/ip route")
        print_command(node, label, "${pkgs.iproute2}/bin/ip -6 route")
        for address in doh_ipv4:
            print_command(node, label, f"${pkgs.iproute2}/bin/ip route get {address}")
        for address in doh_ipv6:
            print_command(node, label, f"${pkgs.iproute2}/bin/ip -6 route get {address}")

    def print_client_diagnostics(node, label):
        print_route_diagnostics(node, label)
        print_command(node, label, "${pkgs.nftables}/bin/nft list ruleset")
        print_command(node, label, "${pkgs.systemd}/bin/systemctl status dnscrypt-proxy.service --no-pager")
        print_command(node, label, "${pkgs.systemd}/bin/journalctl -u dnscrypt-proxy.service -b --no-pager")
        print_command(node, label, "${pkgs.iproute2}/bin/ss -tupn")

    def print_peer_diagnostics():
        print_route_diagnostics(dns_peer, "doh-upstream-peer")
        print_command(dns_peer, "doh-upstream-peer", "${pkgs.iproute2}/bin/ss -ltnp")
        print_command(dns_peer, "doh-upstream-peer", "find /tmp/fake-doh-requests -maxdepth 1 -type f -print -exec cat {} \\\;")
        print_command(dns_peer, "doh-upstream-peer", "cat /tmp/fake-doh-last-probe.json")
        print_command(dns_peer, "doh-upstream-peer", "${pkgs.systemd}/bin/systemctl status fake-doh-server.service --no-pager")
        print_command(dns_peer, "doh-upstream-peer", "${pkgs.systemd}/bin/journalctl -u fake-doh-server.service -b --no-pager")

    def wait_for_answer(node, label, server, question, qtype, expected):
        command = "${pkgs.dig}/bin/dig @{} {} {} +short +time=5 +tries=1 2>&1".format(server, question, qtype)
        last_status = None
        last_output = ""
        for attempt in range(60):
            last_status, last_output = node.execute(command)
            if expected in last_output:
                return
            time.sleep(1)
        print(f"\n### {label}: dig did not return {expected}")
        print(f"last status: {last_status}")
        print(f"last output:\n{last_output}")
        print_client_diagnostics(node, label)
        print_peer_diagnostics()
        raise Exception(f"{label} did not resolve {question} to {expected}")

    ipv4_client.succeed("systemctl restart dnscrypt-proxy.service")
    wait_for_answer(ipv4_client, "doh-upstream-ipv4", "127.0.0.1", "ipv4.upstream-test.example", "A", "203.0.113.5")
    dns_peer.succeed("${pkgs.coreutils}/bin/timeout 10 ${pkgs.bash}/bin/bash -c 'until test -e /tmp/fake-doh-requests/ipv4_upstream-test_example-1.json; do sleep 0.2; done'")
    check_request("/tmp/fake-doh-requests/ipv4_upstream-test_example-1.json", "ipv4", "ipv4.upstream-test.example", 1)

    ipv6_client.succeed("systemctl restart dnscrypt-proxy.service")
    wait_for_answer(ipv6_client, "doh-upstream-ipv6", "::1", "ipv6.upstream-test.example", "AAAA", "2001:db8::5")
    dns_peer.succeed("${pkgs.coreutils}/bin/timeout 10 ${pkgs.bash}/bin/bash -c 'until test -e /tmp/fake-doh-requests/ipv6_upstream-test_example-28.json; do sleep 0.2; done'")
    check_request("/tmp/fake-doh-requests/ipv6_upstream-test_example-28.json", "ipv6", "ipv6.upstream-test.example", 28)
  '';
}
