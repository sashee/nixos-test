{ nixpkgs, pkgs, commonDesktopModule, stateVersion, dohStamps }:

let
  lib = pkgs.lib;

  stampsJson = pkgs.writeText "doh-stamps.json" (builtins.toJSON dohStamps);

  decodeStampsScript = pkgs.writeText "decode-stamps.py" ''
import base64
import json
import socket
import sys

stamps = json.loads(open(sys.argv[1]).read())

def decode(s):
    raw = s.removeprefix("sdns://")
    raw += "=" * (-len(raw) % 4)
    raw = base64.urlsafe_b64decode(raw)
    # Stamp format (from hex dump analysis):
    #   [0] type (1 byte)
    #   [1] props (1 byte)
    #   [2-8] reserved (7 zero bytes)
    #   [9] addr_len (1 byte)
    #   [10..9+alen] addr (text representation)
    #   [10+alen] 0x00 separator
    #   [11+alen] host_len (1 byte)
    #   [12+alen..11+alen+hlen] hostname
    #   [12+alen+hlen] path_len (1 byte)
    #   [13+alen+hlen..] path
    alen = raw[9]
    addr = raw[10:10+alen] if alen else None
    pos = 11 + alen
    hlen = raw[pos]
    hostname = raw[pos+1:pos+1+hlen].decode()
    pos = pos + 1 + hlen
    plen = raw[pos]
    path = raw[pos+1:pos+1+plen].decode()
    ip = None
    if addr:
        decoded = addr.decode("ascii")
        if decoded.startswith("["):
            ip = decoded.strip("[]")
        elif "." in decoded:
            ip = decoded
    family = "ipv4" if ip and "." in ip else "ipv6" if ip else "unknown"
    return {"hostname": hostname, "path": path, "ip": ip, "family": family}

result = {k: decode(v["stamp"]) for k, v in stamps.items()}
print(json.dumps(result))
  '';

  decodedStamps = builtins.fromJSON (builtins.readFile (pkgs.runCommand "decode-doh-stamps-fixed" {
    nativeBuildInputs = [ pkgs.python3 ];
    inherit stampsJson decodeStampsScript;
    preferLocalBuild = true;
  } ''
    ${pkgs.python3}/bin/python3 ${decodeStampsScript} ${stampsJson} > $out
  ''));

  dohDomains = lib.unique (builtins.attrValues (builtins.mapAttrs (n: v: v.hostname) decodedStamps));
  dohIpv4 = builtins.filter (ip: ip != null) (builtins.attrValues (builtins.mapAttrs (n: v: if v.family == "ipv4" then v.ip else null) decodedStamps));
  dohIpv6 = builtins.filter (ip: ip != null) (builtins.attrValues (builtins.mapAttrs (n: v: if v.family == "ipv6" then v.ip else null) decodedStamps));

  altNamesSection = lib.concatStringsSep "\n" (lib.imap1 (i: d: "DNS.${toString i} = ${d}") dohDomains);

  dohTestCerts = pkgs.runCommand "doh-upstream-test-certs" {
    nativeBuildInputs = [ pkgs.openssl ];
  } ''
    mkdir -p $out
    cat > openssl.cnf <<'EOF'
    [ req ]
    distinguished_name = req_distinguished_name
    x509_extensions = v3_ca
    prompt = no

    [ req_distinguished_name ]
    CN = DoH upstream test CA

    [ v3_ca ]
    basicConstraints = critical, CA:true
    keyUsage = critical, keyCertSign, cRLSign
    subjectKeyIdentifier = hash
    EOF

    openssl req -x509 -newkey rsa:2048 -nodes -days 36500 \
      -keyout $out/ca-key.pem \
      -out $out/ca.pem \
      -config openssl.cnf \
      -sha256

    cat > server.cnf <<EOF
    [ req ]
    distinguished_name = req_distinguished_name
    req_extensions = v3_req
    prompt = no

    [ req_distinguished_name ]
    CN = ${lib.elemAt dohDomains 0}

    [ v3_req ]
    basicConstraints = CA:false
    keyUsage = critical, digitalSignature, keyEncipherment
    extendedKeyUsage = serverAuth
    subjectAltName = @alt_names

    [ alt_names ]
    ${altNamesSection}
    EOF

    openssl req -newkey rsa:2048 -nodes \
      -keyout $out/server-key.pem \
      -out server.csr \
      -config server.cnf \
      -sha256

    openssl x509 -req -in server.csr \
      -CA $out/ca.pem \
      -CAkey $out/ca-key.pem \
      -CAcreateserial \
      -out $out/server.pem \
      -days 36500 \
      -extensions v3_req \
      -extfile server.cnf \
      -sha256
  '';

  dohIpv4Json = builtins.toJSON dohIpv4;
  dohIpv6Json = builtins.toJSON dohIpv6;
  dohDomainsJson = builtins.toJSON dohDomains;

  fakeDohServer = pkgs.writeText "fake-doh-server.py" ''
    import base64
    import http.server
    import json
    import pathlib
    import socket
    import ssl
    import urllib.parse

    ready_path = pathlib.Path("/tmp/fake-doh-ready")
    request_dir = pathlib.Path("/tmp/fake-doh-requests")
    probe_path = pathlib.Path("/tmp/fake-doh-last-probe.json")
    request_dir.mkdir(exist_ok=True)

    answers = {
        ("ipv4.upstream-test.example", 1): bytes([203, 0, 113, 5]),
        ("ipv6.upstream-test.example", 28): bytes.fromhex("20010db8000000000000000000000005"),
    }

    def safe_name(name):
        return name.replace(".", "_") or "root"

    def read_question_name(query):
        labels = []
        offset = 12
        while True:
            length = query[offset]
            offset += 1
            if length == 0:
                break
            labels.append(query[offset:offset + length].decode("ascii"))
            offset += length
        qtype = int.from_bytes(query[offset:offset + 2], "big")
        qclass = int.from_bytes(query[offset + 2:offset + 4], "big")
        return ".".join(labels), qtype, qclass, offset + 4

    def dns_response(query):
        name, qtype, qclass, question_end = read_question_name(query)
        question = query[12:question_end]
        answer_prefix = b"\xc0\x0c" + qtype.to_bytes(2, "big") + qclass.to_bytes(2, "big")
        answer_prefix += b"\x00\x00\x00\x3c"

        if (name, qtype) in answers:
            rdata = answers[(name, qtype)]
        elif qtype == 2:
            if name != "":
                return query[:2] + b"\x81\x83\x00\x01\x00\x00\x00\x00\x00\x00" + question
            rdata = b"\x02ns\xc0\x0c"
        else:
            return query[:2] + b"\x81\x83\x00\x01\x00\x00\x00\x00\x00\x00" + question
        answer = answer_prefix + len(rdata).to_bytes(2, "big") + rdata
        return query[:2] + b"\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00" + question + answer

    def decode_query(handler, body):
        if handler.command == "GET":
            query_string = urllib.parse.urlsplit(handler.path).query
            value = urllib.parse.parse_qs(query_string).get("dns", [""])[0]
            padding = "=" * (-len(value) % 4)
            return base64.urlsafe_b64decode(value + padding)
        return body

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        family = "unknown"

        def log_message(self, format, *args):
            return

        def do_GET(self):
            self.handle_doh()

        def do_POST(self):
            self.handle_doh()

        def handle_doh(self):
            body = self.rfile.read(int(self.headers.get("content-length", "0")))
            query = decode_query(self, body)
            name, qtype, qclass, _ = read_question_name(query)
            response = dns_response(query)

            request = json.dumps({
                "family": self.family,
                "method": self.command,
                "path": urllib.parse.urlsplit(self.path).path,
                "host": self.headers.get("host"),
                "content_type": self.headers.get("content-type"),
                "question": name,
                "qtype": qtype,
                "qclass": qclass,
            })
            if name.endswith(".upstream-test.example"):
                (request_dir / f"{safe_name(name)}-{qtype}.json").write_text(request)
            else:
                probe_path.write_text(request)

            self.send_response(200)
            self.send_header("content-type", "application/dns-message")
            self.send_header("content-length", str(len(response)))
            self.end_headers()
            self.wfile.write(response)

    class IPv6HTTPServer(http.server.ThreadingHTTPServer):
        address_family = socket.AF_INET6

        def server_bind(self):
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            super().server_bind()

    def make_server(address, family, server_class=http.server.ThreadingHTTPServer):
        handler = type(f"{family}Handler", (Handler,), {"family": family})
        httpd = server_class(address, handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain("${dohTestCerts}/server.pem", "${dohTestCerts}/server-key.pem")
        httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
        return httpd

    ipv4_server = make_server(("0.0.0.0", 443), "ipv4")
    ipv6_server = make_server(("::", 443), "ipv6", IPv6HTTPServer)
    ready_path.touch()

    import threading
    threading.Thread(target=ipv4_server.serve_forever, daemon=True).start()
    ipv6_server.serve_forever()
  '';
in
nixpkgs.lib.nixos.runTest {
  name = "doh-upstream";
  hostPkgs = pkgs;
  skipTypeCheck = true;

  nodes.ipv4Client = { pkgs, ... }: {
    imports = [ commonDesktopModule ];

    networking.hostName = "doh-upstream-ipv4";
    security.pki.certificateFiles = [ "${dohTestCerts}/ca.pem" ];
    system.stateVersion = stateVersion;
  };

  nodes.ipv6Client = { pkgs, ... }: {
    imports = [ commonDesktopModule ];

    networking.hostName = "doh-upstream-ipv6";
    security.pki.certificateFiles = [ "${dohTestCerts}/ca.pem" ];
    system.stateVersion = stateVersion;
  };

  nodes.dnsPeer = { pkgs, ... }: {
    imports = [ commonDesktopModule ];

    common = {
      doh.enable = false;
      firewall.enable = false;
    };
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
    dns_peer.succeed("systemd-run --unit fake-doh-server ${pkgs.python3}/bin/python3 ${fakeDohServer}")
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
