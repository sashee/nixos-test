{ nixpkgs, pkgs, stateVersion, moduleUnderTest }:

# Probe semantics for the connectivity check, isolated from the radio stack.
#
# This is the regression test for the 2026-07-27 outage: the check probed a single
# third-party HTTP canary (detectportal.firefox.com), Mozilla migrated that host to a new
# CDN, the address pinned in lib/captive-portals.txt went stale, and the endpoint began
# accepting TCP and then answering nothing. The check read that as "offline", raised the
# setup AP and rebooted -- every 15m23s for ~16 hours, on a machine whose internet worked
# the whole time. The old test suite could not catch it because it only ever mocked the
# probe as wholly reachable or wholly unreachable, never as responding-but-broken.
#
# Three endpoints are served locally, in the order the check tries them:
#
#   1. broken   -- accepts the connection and closes it without completing TLS. The
#                  faithful analogue of the endpoint that caused the outage (over HTTPS
#                  the empty reply surfaces as a TLS failure rather than curl's exit 52).
#   2. rogue    -- completes TLS with a certificate from a CA the machine does not trust,
#                  i.e. what a captive portal or any interception middlebox looks like.
#                  Must read as offline: certificate validation is the portal test, and
#                  that is the property this pins.
#   3. good     -- valid certificate from a trusted CA, answers HTTP 200.
#
# Endpoints are bound to 127.0.0.1 on purpose. What needs proving here is the decision
# logic -- that one rotted endpoint among healthy ones cannot take the machine down, and
# that TLS interception cannot be mistaken for connectivity. The real network path
# (station mode, AP mode, DHCP, the portal) is covered by connectivity-fallback.nix.
let
  mkCert = import ./test-cert.nix { inherit pkgs; };

  # Two independent CAs. The machine trusts only the first, so `rogue` is
  # indistinguishable from a middlebox that has substituted its own certificate.
  trusted = mkCert {
    name = "probe-trusted";
    sans = [ "good.probe.test" ];
  };
  rogue = mkCert {
    name = "probe-rogue";
    sans = [ "rogue.probe.test" ];
  };

  ports = {
    broken = 8443;
    rogue = 9443;
    good = 10443;
  };

  # Accept, then hang up without a TLS handshake.
  brokenServer = pkgs.writeText "probe-broken.py" ''
    import socket, sys

    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", int(sys.argv[1])))
    s.listen(5)
    while True:
        conn, _ = s.accept()
        conn.close()
  '';

  # Minimal DoH-shaped responder: 200 with an application/dns-message body. The check
  # only requires the status, so the body is a stub.
  tlsServer = pkgs.writeText "probe-tls.py" ''
    import http.server, ssl, sys

    port, cert, key = int(sys.argv[1]), sys.argv[2], sys.argv[3]

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            return

        def do_GET(self):
            body = b"\x00\x00"
            self.send_response(200)
            self.send_header("Content-Type", "application/dns-message")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    srv.serve_forever()
  '';

  mkServer = name: args: {
    "probe-${name}" = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${args}";
        Restart = "no";
      };
    };
  };
in
nixpkgs.lib.nixos.runTest {
  name = "connectivity-fallback-probe";
  hostPkgs = pkgs;

  nodes.machine =
    { lib, ... }:
    {
      imports = [ moduleUnderTest ];

      networking.wireless.iwd.enable = true;
      security.pki.certificateFiles = [ trusted.caFile ];

      common.connectivityFallback = {
        enable = true;
        # Ordered worst-first, so reaching `good` proves the loop does not stop at the
        # first failure -- the exact behaviour whose absence caused the outage.
        connectivityCheck.endpoints = [
          {
            hostname = "broken.probe.test";
            addr = "127.0.0.1";
            port = ports.broken;
          }
          {
            hostname = "rogue.probe.test";
            addr = "127.0.0.1";
            port = ports.rogue;
          }
          {
            hostname = "good.probe.test";
            addr = "127.0.0.1";
            port = ports.good;
          }
        ];
        connectivityCheck.timeoutSeconds = 3;
        # The check is driven by hand here, so keep the boot timer far away, and keep the
        # safety-net reboot far enough out that a started setup mode cannot power-cycle
        # the VM mid-test.
        bootGrace = "1h";
        setupTimeout = "1h";
      };

      systemd.services =
        mkServer "broken" "${brokenServer} ${toString ports.broken}"
        // mkServer "rogue" "${tlsServer} ${toString ports.rogue} ${rogue.certFile} ${rogue.keyFile}"
        // mkServer "good" "${tlsServer} ${toString ports.good} ${trusted.certFile} ${trusted.keyFile}";

      system.stateVersion = stateVersion;
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    for name, port in (("broken", ${toString ports.broken}), ("rogue", ${toString ports.rogue}), ("good", ${toString ports.good})):
        machine.wait_for_unit(f"probe-{name}.service")
        machine.wait_for_open_port(port, addr="127.0.0.1")

    # The timer must not have fired on its own; every assertion below is about a
    # hand-started run.
    machine.succeed("systemctl is-active connectivity-fallback-check.timer")
    machine.fail("systemctl is-active connectivity-fallback-setup.service")

    with subtest("a broken and an intercepted endpoint do not outvote a healthy one"):
        machine.succeed("systemctl start connectivity-fallback-check.service")
        # NB: not `log` -- that name is the test driver's own logger object.
        journal = machine.succeed("journalctl -u connectivity-fallback-check.service --no-pager")

        # Online, and specifically via the trusted endpoint.
        assert "online (via good.probe.test at 127.0.0.1)" in journal, journal

        # Both bad endpoints were actually attempted and rejected. Without this the test
        # could pass by probing only the good endpoint, which would not prove anything.
        assert "probe failed for broken.probe.test" in journal, journal
        assert "probe failed for rogue.probe.test" in journal, journal

        # The whole point: no setup mode, so no AP and no reboot.
        machine.fail("systemctl is-active connectivity-fallback-setup.service")
        assert "entering setup mode" not in journal, journal

    with subtest("an untrusted certificate alone reads as offline, not as connectivity"):
        # Drop the only trustworthy endpoint. `rogue` still completes a TLS handshake and
        # would answer 200 to anyone who skipped verification, so if the check ever grew a
        # -k or an "any response counts" rule, this is where it fails.
        machine.succeed("systemctl stop probe-good.service")
        machine.succeed("journalctl --rotate && journalctl --vacuum-time=1s")
        machine.succeed("systemctl reset-failed connectivity-fallback-check.service || true")
        machine.succeed("systemctl start connectivity-fallback-check.service")
        # NB: not `log` -- that name is the test driver's own logger object.
        journal = machine.succeed("journalctl -u connectivity-fallback-check.service --no-pager")

        assert "entering setup mode" in journal, journal
        assert "online (via" not in journal, journal

        # Setup mode was genuinely triggered. It cannot succeed on a node with no radio,
        # so "not inactive" (activating or failed) is the observable signal that the
        # check handed off rather than silently doing nothing.
        machine.wait_until_succeeds(
            "test \"$(systemctl is-active connectivity-fallback-setup.service)\" != inactive",
            timeout=30,
        )
  '';
}
