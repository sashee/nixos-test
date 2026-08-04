# Shared DoH-interception harness for VM tests.
#
# Impersonates the deployed DoH upstreams so a stock dnscrypt-proxy client's DNS
# queries are answered by a test-controlled server. The caller supplies a single
# `respond(query, meta) -> bytes` Python function ("DNS request in, DNS response
# out"); this module owns the test CA + leaf cert and the TLS DoH server, and hands
# back the provider IPs/domains, the cert paths, and a systemd service builder for
# the interceptor node.
#
# `dohStamps` is lib/doh-stamps.nix evaluated -- i.e. `{ providers, endpoints, stamps }`
# -- and only `.providers` is used here.
#
# Used by tests/doh-upstream.nix, tests/iroh-ssh.nix, tests/connectivity-watchdog.nix,
# tests/time-correction.nix and tests/nts-sync.nix.
#
# `certNotBefore` / `certNotAfter` pin the leaf's validity window (see tests/test-cert.nix).
# Both default to null, i.e. the 100-year certificate every existing caller gets. A window that
# excludes the present is how a test impersonates a resolver whose certificate is genuinely
# expired while its clock stays correct -- the only way to exercise a client that defers the
# date check and re-applies it later.
#
# `certChainWith` makes the server SEND certificates beyond its leaf that no path through it uses
# (see tests/test-cert.nix). Python's `ssl.load_cert_chain` below is OpenSSL's
# SSL_CTX_use_certificate_chain_file, which takes the first certificate as the leaf and offers the
# rest as candidate issuers without validating or reordering them -- so whatever is listed here
# really does go out on the wire, which is the point.
{ pkgs, dohStamps, readyFile ? "/tmp/doh-interceptor-ready", respond
, certNotBefore ? null, certNotAfter ? null, certChainWith ? [ ], name ? "doh-interceptor" }:

let
  lib = pkgs.lib;

  # The upstream provider IPs/hostnames dnscrypt-proxy dials, so the test hijacks exactly
  # those. Read straight off the components in lib/doh-stamps.nix -- which is also where
  # the `sdns://` stamps dnscrypt actually consumes are generated from, so the two cannot
  # drift. This used to decode the stamps with a Python helper via import-from-derivation;
  # since the components became the source of truth there is nothing left to decode, and
  # dropping the IFD keeps evaluation buildless (it sat on the checks.aarch64-linux path).
  providers = dohStamps.providers;
  dohDomains = lib.unique (lib.mapAttrsToList (_: p: p.hostname) providers);
  dohIpv4 = lib.unique (lib.mapAttrsToList (_: p: p.v4) providers);
  # Unbracketed: these are used as bare addresses (interface config, socket binds),
  # unlike the bracketed dial targets inside a stamp.
  dohIpv6 = lib.unique (lib.filter (x: x != null) (lib.mapAttrsToList (_: p: p.v6 or null) providers));

  # RFC 8484 GET parameter: base64url, unpadded. Decodes to a standard query for
  # www.example.com IN A with ID 0 and RD set:
  #   0000 0100 0001 0000 0000 0000  (header: ID, flags, QDCOUNT=1, no RRs)
  #   03 "www" 07 "example" 03 "com" 00   (QNAME)
  #   0001 0001                      (QTYPE=A, QCLASS=IN)
  # ID 0 is deliberate: it keeps the request cacheable by intermediaries.
  #
  # Lives here, with the harness that answers it, rather than in lib/doh-stamps.nix: nothing
  # this repo deploys sends a DoH GET by hand any more (dnscrypt-proxy builds its own), so
  # the only readers are tests aiming a `curl` straight at an impersonated upstream. Exported
  # rather than inlined per test so two callers cannot send subtly different queries and
  # disagree about what the harness saw.
  dnsQuery = "AAABAAABAAAAAAAAA3d3dwdleGFtcGxlA2NvbQAAAQAB";

  # A test CA + leaf for the DoH provider hostnames only. The stock nodes trust
  # this CA so dnscrypt-proxy accepts the fake upstream. (Other impersonated
  # services, e.g. an iroh relay, mint their own cert with the same helper.)
  certs = import ./test-cert.nix { inherit pkgs; } {
    name = "${name}-doh";
    sans = dohDomains;
    notBefore = certNotBefore;
    notAfter = certNotAfter;
    chainWith = certChainWith;
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

    def txt(query, *strings, ttl=60):
        # TXT rdata is a sequence of length-prefixed character-strings (RFC 1035),
        # so each string carries its own one-byte length. 255 bytes max each.
        # Length is taken after encoding, not from len(str): the two agree only
        # for ascii, and a wrong prefix would corrupt the whole record. Over 255
        # the length byte wraps and the corruption is silent, so refuse instead
        # of handing back a record the caller will spend a test run debugging.
        encoded = [s.encode("ascii") for s in strings]
        for b in encoded:
            assert len(b) <= 255, f"TXT character-string too long ({len(b)}): {b!r}"
        rdata = b"".join(bytes([len(b)]) + b for b in encoded)
        return answer_rdata(query, rdata, ttl)

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
  #
  # `nodad` on the IPv6 adds, and it is load-bearing rather than tidiness. A test may run two
  # interceptor nodes on one segment holding the SAME provider addresses, choosing between them
  # by routing (tests/time-correction.nix does exactly that) -- and those addresses are then genuine
  # duplicates, so whichever node adds one second loses duplicate address detection and has it
  # marked `dadfailed`, permanently unusable for the rest of the run:
  #
  #   dohgood # IPv6: eth1: IPv6 duplicate address 2620:fe::10 used by 52:54:00:12:01:02 detected!
  #
  # The race is per address, so without `nodad` each run leaves a different random subset of each
  # node's addresses dead -- which reads as intermittent slowness rather than as a failure, since a
  # caller retrying can still land on one of the survivors. IPv4 has no DAD, which is why only the
  # v6 path ever shows it.
  #
  # Duplicates on one segment are fine here because nothing resolves these addresses on-link:
  # callers route to them `via` each node's own unique address. Same idiom as
  # tests/nm-captive-portal-ipv6.nix, which holds provider /128s the same way.
  mkService = { args ? [ ] }: {
    description = "Fake DoH upstream (${name})";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    preStart = lib.concatMapStringsSep "\n"
      (ip: "${pkgs.iproute2}/bin/ip addr add ${ip}/32 dev eth1 || true")
      dohIpv4
      + "\n" + lib.concatMapStringsSep "\n"
      (ip: "${pkgs.iproute2}/bin/ip -6 addr add ${ip}/128 dev eth1 nodad || true")
      dohIpv6;
    serviceConfig.ExecStart = lib.concatStringsSep " " ([
      "${pkgs.python3}/bin/python3"
      "${serverScript}"
    ] ++ args);
  };
in
{
  inherit dohDomains dohIpv4 dohIpv6 dnsQuery caFile certFile keyFile serverScript mkService;
}
