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
      import time
      request_dir = pathlib.Path("/tmp/fake-doh-requests"); request_dir.mkdir(exist_ok=True)
      probe_path = pathlib.Path("/tmp/fake-doh-last-probe.json")
      # Ordered, append-only record of every request, timestamped. The files below are keyed
      # by name+qtype and so overwrite each other, which loses *when* and *how many* -- the
      # two things a failed wait_for_answer needs in order to tell "the query never reached
      # the upstream" from "it did, and the answer never made it back to the client".
      log_path = pathlib.Path("/tmp/fake-doh-request-log.jsonl")
      def _safe(n): return n.replace(".", "_") or "root"
      def respond(query, meta):
          name, qtype, qclass, _ = read_question(query)
          record = {
              "family": meta["family"], "method": meta["method"], "path": meta["path"],
              "host": meta["host"], "content_type": meta["content_type"],
              "question": name, "qtype": qtype, "qclass": qclass}
          rec = json.dumps(record)
          # One short O_APPEND write per request, so the threaded server's handlers cannot
          # interleave a partial line.
          with log_path.open("a") as fh:
              fh.write(json.dumps(dict(record, t=round(time.time(), 3))) + "\n")
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

  # A DoH GET aimed straight at one impersonated upstream, bypassing dnscrypt-proxy
  # entirely: --resolve pins the address, so the probe needs no DNS at all. The query comes
  # from the interceptor harness (tests/doh-interceptor.nix), i.e. the one place that
  # literal lives, so the probe cannot ask something the fake upstream does not expect.
  #
  # This is what the 2026-07-29 rpi failure had no way to answer: dnscrypt-proxy was active
  # and listening while every dig timed out, and nothing in the dump distinguished "this
  # client cannot reach the fake upstream" from "dnscrypt-proxy is not answering". HTTP 200
  # here means TCP 443 + TLS + a live fake server, i.e. the break is inside dnscrypt-proxy.
  #
  # No backslash in the -w format on purpose: this string is double-encoded on the way into
  # the testScript (toJSON, then a Python literal, then json.loads), and a `\n` would come
  # out the far end as a real newline. print_command already adds one.
  probeCommand = host: dial:
    "${pkgs.curl}/bin/curl -s -m 20 -o /dev/null -w '%{http_code} %{time_total}'"
    + " --resolve ${host}:443:${dial}"
    + " -H 'accept: application/dns-message'"
    + " 'https://${host}/dns-query?dns=${interceptor.dnsQuery}'";
  # Bracketed for v6: curl needs the brackets to tell the address apart from --resolve's
  # own host:port:addr colons.
  #
  # `v6` is optional in lib/doh-stamps.nix (entriesFor only emits the -ipv6 entry under
  # `p ? v6`), so it has to be optional here too -- reading it unconditionally made a
  # v4-only provider an eval error in a test that has nothing to do with it.
  upstreamProbes = pkgs.lib.concatMap
    (p: [
      { label = "${p.hostname} via ${p.v4}"; command = probeCommand p.hostname p.v4; }
    ] ++ pkgs.lib.optional (p ? v6)
      { label = "${p.hostname} via ${p.v6}"; command = probeCommand p.hostname "[${p.v6}]"; })
    (pkgs.lib.attrValues dohStamps.providers);
  upstreamProbesJson = builtins.toJSON upstreamProbes;
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
    upstream_probes = json.loads("""${upstreamProbesJson}""")

    # Node-name symbols exposed by the driver; binding them starts nothing.
    dns_peer = dnsPeer
    ipv4_client = ipv4Client
    ipv6_client = ipv6Client

    dns_peer.start()
    dns_peer.wait_for_unit("multi-user.target")
    dns_peer.succeed("rm -rf /tmp/fake-doh-ready /tmp/fake-doh-requests /tmp/fake-doh-last-probe.json /tmp/fake-doh-request-log.jsonl")
    dns_peer.succeed("${pkgs.procps}/bin/sysctl -w net.ipv4.ip_forward=1")
    dns_peer.succeed("${pkgs.procps}/bin/sysctl -w net.ipv6.conf.all.forwarding=1")
    # On slow (TCG) runners eth1's static addresses can land after
    # multi-user.target; wait for them so the /32s below never end up first in
    # eth1's address list (peer_ipv4/peer_ipv6 must pick the on-link address).
    dns_peer.wait_until_succeeds("${pkgs.iproute2}/bin/ip -4 addr show dev eth1 | grep -q 'inet 192.168.1.'")
    dns_peer.wait_until_succeeds("${pkgs.iproute2}/bin/ip -6 addr show dev eth1 | grep -q 'inet6 2001:db8:1:'")
    for address in doh_ipv4:
        dns_peer.succeed(f"${pkgs.iproute2}/bin/ip addr add {address}/32 dev eth1 || true")
    for address in doh_ipv6:
        dns_peer.succeed(f"${pkgs.iproute2}/bin/ip -6 addr add {address}/128 dev eth1 || true")
    dns_peer.succeed("systemd-run --unit fake-doh-server ${pkgs.python3}/bin/python3 ${interceptor.serverScript}")
    dns_peer.wait_for_unit("fake-doh-server.service")
    dns_peer.succeed("${pkgs.coreutils}/bin/timeout 60 ${pkgs.bash}/bin/bash -c 'until test -e /tmp/fake-doh-ready; do sleep 0.2; done'")

    peer_ipv4 = dns_peer.succeed("${pkgs.python3}/bin/python3 -c 'import json, subprocess; data = json.loads(subprocess.check_output([\"${pkgs.iproute2}/bin/ip\", \"-j\", \"-4\", \"addr\", \"show\", \"dev\", \"eth1\"])); print(next(addr[\"local\"] for addr in data[0][\"addr_info\"] if addr[\"local\"].startswith(\"192.168.1.\")))'").strip()
    peer_ipv6 = dns_peer.succeed("${pkgs.python3}/bin/python3 -c 'import json, subprocess; data = json.loads(subprocess.check_output([\"${pkgs.iproute2}/bin/ip\", \"-j\", \"-6\", \"addr\", \"show\", \"dev\", \"eth1\"])); print(next(addr[\"local\"] for addr in data[0][\"addr_info\"] if addr[\"scope\"] == \"global\" and addr[\"local\"].startswith(\"2001:db8:1:\")))'").strip()

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
        # -a, not bare -tupn: without it ss lists only *connected* sockets, so the
        # 2026-07-29 rpi dump was an empty table and could not confirm dnscrypt-proxy
        # still held [::1]:53 while every dig against it timed out.
        print_command(node, label, "${pkgs.iproute2}/bin/ss -antup")
        # nixos-fw and common-doh-egress rejects both log with a "refused " prefix.
        print_command(node, label, "${pkgs.systemd}/bin/journalctl -k -b --grep refused --no-pager")
        for probe in upstream_probes:
            print_command(node, f"{label} upstream probe {probe['label']}", probe["command"])

    def print_peer_diagnostics():
        print_route_diagnostics(dns_peer, "doh-upstream-peer")
        print_command(dns_peer, "doh-upstream-peer", "${pkgs.iproute2}/bin/ss -ltnp")
        # Quote the ';' rather than escaping it. A lone backslash is literal in a Nix
        # indented string and Python keeps \; verbatim, so the previous \\\; reached the
        # shell as a literal \ argument plus a command terminator, and this died with
        # "find: missing argument to `-exec'" -- losing the request dump on exactly the
        # run that needed it.
        print_command(dns_peer, "doh-upstream-peer", "find /tmp/fake-doh-requests -maxdepth 1 -type f -print -exec cat {} ';'")
        print_command(dns_peer, "doh-upstream-peer", "cat /tmp/fake-doh-request-log.jsonl")
        print_command(dns_peer, "doh-upstream-peer", "cat /tmp/fake-doh-last-probe.json")
        print_command(dns_peer, "doh-upstream-peer", "${pkgs.systemd}/bin/systemctl status fake-doh-server.service --no-pager")
        print_command(dns_peer, "doh-upstream-peer", "${pkgs.systemd}/bin/journalctl -u fake-doh-server.service -b --no-pager")

    # Run-length encode the attempts. Whether the failure mode changed over the loop --
    # connection refused while dnscrypt-proxy was still binding, then timeouts, say -- is
    # invisible from the last attempt alone, which is all this used to print.
    def print_attempt_summary(attempts):
        print("attempt outcomes, oldest first (count x exit status: first line of output):")
        runs = []
        for status, output in attempts:
            lines = output.strip().splitlines()
            key = (status, lines[0] if lines else "")
            if runs and runs[-1][0] == key:
                runs[-1][1] += 1
            else:
                runs.append([key, 1])
        for (status, first_line), count in runs:
            print(f"  {count}x status {status}: {first_line}")

    def wait_for_answer(node, label, server, question, qtype, expected):
        command = "${pkgs.dig}/bin/dig @{} {} {} +short +time=5 +tries=1 2>&1".format(server, question, qtype)
        attempts = []
        started = time.monotonic()
        for attempt in range(60):
            attempts.append(node.execute(command))
            if expected in attempts[-1][1]:
                return
            time.sleep(1)
        last_status, last_output = attempts[-1]
        print(f"\n### {label}: dig did not return {expected}"
              f" in {len(attempts)} attempts over {time.monotonic() - started:.0f}s")
        print_attempt_summary(attempts)
        print(f"last status: {last_status}")
        print(f"last output:\n{last_output}")
        # One retry over TCP with a timeout above dnscrypt-proxy's own 5s upstream timeout:
        # separates UDP-specific loss from a flat no-answer, and shows whether an answer
        # arrives at all when given more than the loop allows. Failure path only -- the
        # loop's own behaviour above is deliberately unchanged.
        print_command(node, label, "${pkgs.dig}/bin/dig @{} {} {} +tcp +time=20 +tries=1 2>&1".format(server, question, qtype))
        print_client_diagnostics(node, label)
        print_peer_diagnostics()
        raise Exception(f"{label} did not resolve {question} to {expected}")

    # Bring up the heavy (Plasma) clients ONE AT A TIME, shutting each down before
    # the next boots: booting both full desktops at once starved a client's initrd
    # store mount past its timeout on the small CI runner (kernel panic). dns_peer
    # (light, no desktop) stays up throughout for the fake DoH + request checks.

    # IPv4 client: force the v4 DoH path (v6 upstreams unreachable).
    ipv4_client.start()
    ipv4_client.wait_for_unit("multi-user.target")
    ipv4_client.succeed("systemctl is-active dnscrypt-proxy.service")
    ipv4_client.succeed("systemctl is-active nftables.service")
    ipv4_client.succeed("${pkgs.nftables}/bin/nft list table inet common-doh-egress")
    ipv4_client.succeed(f"${pkgs.iproute2}/bin/ip -4 route replace default via {peer_ipv4}")
    for address in doh_ipv6:
        ipv4_client.succeed(f"${pkgs.iproute2}/bin/ip -6 route replace unreachable {address}/128")
    ipv4_client.succeed("systemctl restart dnscrypt-proxy.service")
    wait_for_answer(ipv4_client, "doh-upstream-ipv4", "127.0.0.1", "ipv4.upstream-test.example", "A", "203.0.113.5")
    dns_peer.succeed("${pkgs.coreutils}/bin/timeout 60 ${pkgs.bash}/bin/bash -c 'until test -e /tmp/fake-doh-requests/ipv4_upstream-test_example-1.json; do sleep 0.2; done'")
    check_request("/tmp/fake-doh-requests/ipv4_upstream-test_example-1.json", "ipv4", "ipv4.upstream-test.example", 1)
    ipv4_client.shutdown()

    # IPv6 client: force the v6 DoH path (v4 upstreams unreachable).
    ipv6_client.start()
    ipv6_client.wait_for_unit("multi-user.target")
    ipv6_client.succeed("systemctl is-active dnscrypt-proxy.service")
    ipv6_client.succeed("systemctl is-active nftables.service")
    ipv6_client.succeed("${pkgs.nftables}/bin/nft list table inet common-doh-egress")
    ipv6_client.succeed("${pkgs.iproute2}/bin/ip -6 route del default || true")
    ipv6_client.succeed(f"${pkgs.iproute2}/bin/ip -6 route add default via {peer_ipv6} dev eth1 metric 42")
    for address in doh_ipv4:
        ipv6_client.succeed(f"${pkgs.iproute2}/bin/ip route replace unreachable {address}/32")
    ipv6_client.succeed("systemctl restart dnscrypt-proxy.service")
    wait_for_answer(ipv6_client, "doh-upstream-ipv6", "::1", "ipv6.upstream-test.example", "AAAA", "2001:db8::5")
    dns_peer.succeed("${pkgs.coreutils}/bin/timeout 60 ${pkgs.bash}/bin/bash -c 'until test -e /tmp/fake-doh-requests/ipv6_upstream-test_example-28.json; do sleep 0.2; done'")
    check_request("/tmp/fake-doh-requests/ipv6_upstream-test_example-28.json", "ipv6", "ipv6.upstream-test.example", 28)
    ipv6_client.shutdown()
  '';
}
