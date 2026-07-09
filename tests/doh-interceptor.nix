# Shared DoH-interception harness for VM tests.
#
# Impersonates the deployed DoH upstreams so a stock dnscrypt-proxy client's DNS
# queries are answered by a test-controlled server. The caller supplies a single
# `respond(query, meta) -> bytes` Python function ("DNS request in, DNS response
# out"); this module owns the stamp decoding, the test CA + leaf cert, and the
# TLS DoH server, and hands back the decoded provider IPs/domains, the cert
# paths, and a systemd service builder for the interceptor node.
#
# Used by tests/doh-upstream.nix and tests/iroh-ssh.nix.
{ pkgs, dohStamps, readyFile ? "/tmp/doh-interceptor-ready", respond, name ? "doh-interceptor" }:

let
  lib = pkgs.lib;

  # Decode the deployed DoH stamps to the upstream provider IPs/hostnames, so
  # the test hijacks exactly the addresses dnscrypt-proxy dials.
  stampsJson = pkgs.writeText "doh-stamps.json" (builtins.toJSON dohStamps);
  decodeStampsScript = pkgs.writeText "decode-stamps.py" ''
import base64, json, sys
stamps = json.loads(open(sys.argv[1]).read())
def decode(s):
    raw = s.removeprefix("sdns://"); raw += "=" * (-len(raw) % 4)
    raw = base64.urlsafe_b64decode(raw)
    alen = raw[9]; addr = raw[10:10+alen] if alen else None
    pos = 11 + alen; hlen = raw[pos]
    hostname = raw[pos+1:pos+1+hlen].decode()
    ip = None
    if addr:
        d = addr.decode("ascii")
        ip = d.strip("[]") if d.startswith("[") else (d if "." in d else None)
    family = "ipv4" if ip and "." in ip else "ipv6" if ip else "unknown"
    return {"hostname": hostname, "ip": ip, "family": family}
print(json.dumps({k: decode(v["stamp"]) for k, v in stamps.items()}))
  '';
  decodedStamps = builtins.fromJSON (builtins.readFile (pkgs.runCommand "${name}-decode-doh-stamps" {
    nativeBuildInputs = [ pkgs.python3 ];
    inherit stampsJson decodeStampsScript;
    preferLocalBuild = true;
  } ''
    ${pkgs.python3}/bin/python3 ${decodeStampsScript} ${stampsJson} > $out
  ''));
  dohDomains = lib.unique (lib.mapAttrsToList (_: v: v.hostname) decodedStamps);
  dohIpv4 = lib.unique (lib.filter (x: x != null) (lib.mapAttrsToList (_: v: if v.family == "ipv4" then v.ip else null) decodedStamps));
  dohIpv6 = lib.unique (lib.filter (x: x != null) (lib.mapAttrsToList (_: v: if v.family == "ipv6" then v.ip else null) decodedStamps));

  # A test CA + leaf for the DoH provider hostnames only. The stock nodes trust
  # this CA so dnscrypt-proxy accepts the fake upstream. (Other impersonated
  # services, e.g. an iroh relay, mint their own cert with the same helper.)
  certs = import ./test-cert.nix { inherit pkgs; } {
    name = "${name}-doh";
    sans = dohDomains;
  };
  inherit (certs) caFile certFile keyFile;

  # The DoH-over-TLS server. The prelude gives the caller's `respond` the DNS
  # framing helpers; the main loop owns TLS, GET/POST decode, the per-family
  # tag, and the readiness signal. Extra argv is exposed as meta["args"].
  serverScript = pkgs.writeText "${name}-server.py" ''
    import base64, http.server, json, pathlib, socket, ssl, sys, threading, urllib.parse

    ARGS = sys.argv[1:]

    def read_question(query):
        labels = []; off = 12
        while True:
            n = query[off]; off += 1
            if n == 0: break
            labels.append(query[off:off+n].decode("ascii")); off += n
        qtype = int.from_bytes(query[off:off+2], "big")
        qclass = int.from_bytes(query[off+2:off+4], "big")
        return ".".join(labels), qtype, qclass, off + 4

    def _q(query):
        _, _, _, end = read_question(query); return query[12:end]

    def nxdomain(query):
        return query[:2] + b"\x81\x83\x00\x01\x00\x00\x00\x00\x00\x00" + _q(query)

    def nodata(query):
        return query[:2] + b"\x81\x80\x00\x01\x00\x00\x00\x00\x00\x00" + _q(query)

    def answer_rdata(query, rdata, ttl=60):
        _, qtype, qclass, end = read_question(query)
        rr = (b"\xc0\x0c" + qtype.to_bytes(2, "big") + qclass.to_bytes(2, "big")
              + ttl.to_bytes(4, "big") + len(rdata).to_bytes(2, "big") + rdata)
        return query[:2] + b"\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00" + query[12:end] + rr

    def a(query, ip, ttl=60):
        return answer_rdata(query, socket.inet_aton(ip), ttl)

    def aaaa(query, ip, ttl=60):
        return answer_rdata(query, socket.inet_pton(socket.AF_INET6, ip), ttl)

    ${respond}

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        family = "unknown"
        def log_message(self, *a): return
        def do_GET(self):
            v = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query).get("dns", [""])[0]
            self._handle(base64.urlsafe_b64decode(v + "=" * (-len(v) % 4)))
        def do_POST(self):
            self._handle(self.rfile.read(int(self.headers.get("content-length", "0"))))
        def _handle(self, query):
            meta = {"family": self.family, "method": self.command,
                    "path": urllib.parse.urlsplit(self.path).path,
                    "host": self.headers.get("host"),
                    "content_type": self.headers.get("content-type"), "args": ARGS}
            r = respond(query, meta)
            self.send_response(200)
            self.send_header("content-type", "application/dns-message")
            self.send_header("content-length", str(len(r)))
            self.end_headers(); self.wfile.write(r)

    class _V6(http.server.ThreadingHTTPServer):
        address_family = socket.AF_INET6
        def server_bind(self):
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            super().server_bind()

    def _serve(addr, family, cls=http.server.ThreadingHTTPServer):
        httpd = cls(addr, type(f"{family}Handler", (Handler,), {"family": family}))
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain("${certFile}", "${keyFile}")
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
        return httpd

    _v4 = _serve(("0.0.0.0", 443), "ipv4")
    _v6 = _serve(("::", 443), "ipv6", _V6)
    pathlib.Path("${readyFile}").touch()
    threading.Thread(target=_v4.serve_forever, daemon=True).start()
    _v6.serve_forever()
  '';

  # A systemd service that assigns the DoH provider IPs to eth1 and runs the
  # server. `args` are appended to ExecStart (exposed to respond as meta["args"]).
  mkService = { args ? [ ] }: {
    description = "Fake DoH upstream (${name})";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    preStart = lib.concatMapStringsSep "\n"
      (ip: "${pkgs.iproute2}/bin/ip addr add ${ip}/32 dev eth1 || true")
      dohIpv4
      + "\n" + lib.concatMapStringsSep "\n"
      (ip: "${pkgs.iproute2}/bin/ip -6 addr add ${ip}/128 dev eth1 || true")
      dohIpv6;
    serviceConfig.ExecStart = lib.concatStringsSep " " ([
      "${pkgs.python3}/bin/python3"
      "${serverScript}"
    ] ++ args);
  };
in
{
  inherit dohDomains dohIpv4 dohIpv6 caFile certFile keyFile serverScript mkService;
}
