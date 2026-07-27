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
#   3. sick     -- trusted certificate, clean TLS, but answers HTTP 503. This is the rot
#                  shape the HTTPS+200 rule newly has to survive: nothing is wrong with
#                  the transport, only the answer. `broken` and `rogue` above both fail
#                  at TLS, i.e. the same code path, so without this the "responding but
#                  broken" claim would rest on the easy case.
#   4. sluggish  -- trusted certificate, clean TLS, then never answers. The only endpoint
#                  here that reaches connectivityCheck.timeoutSeconds, so it is what
#                  proves the per-endpoint timeout exists and that one hung upstream
#                  cannot stall the loop indefinitely. Costs the test that timeout.
#   5. good     -- valid certificate from a trusted CA, answers HTTP 200.
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
    # sick/sluggish share the trusted CA on purpose: their whole point is that the
    # transport is beyond reproach and only the answer is wrong.
    sans = [
      "good.probe.test"
      "sick.probe.test"
      "sluggish.probe.test"
    ];
  };
  rogue = mkCert {
    name = "probe-rogue";
    sans = [ "rogue.probe.test" ];
  };

  ports = {
    broken = 8443;
    rogue = 9443;
    sick = 11443;
    sluggish = 12443;
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

  # Minimal DoH-shaped responder over TLS. `mode` picks what happens once the handshake
  # has succeeded, which is where the interesting cases live:
  #   ok    -- 200 with an application/dns-message body (the check only reads the status,
  #            so the body is a stub).
  #   sick  -- 503. Transport fine, answer useless.
  #   hang  -- never respond, forcing the client onto its own timeout.
  tlsServer = pkgs.writeText "probe-tls.py" ''
    import http.server, ssl, sys, time

    port, cert, key, mode = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            return

        def do_GET(self):
            if mode == "hang":
                # Hold the request open and never write a status line. The client has to
                # give up on connectivityCheck.timeoutSeconds; the thread is a daemon, so
                # leaking it for the rest of the VM's life is fine.
                while True:
                    time.sleep(3600)
            body = b"\x00\x00" if mode == "ok" else b""
            self.send_response(200 if mode == "ok" else 503)
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
            hostname = "sick.probe.test";
            addr = "127.0.0.1";
            port = ports.sick;
          }
          {
            hostname = "sluggish.probe.test";
            addr = "127.0.0.1";
            port = ports.sluggish;
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
        // mkServer "rogue" "${tlsServer} ${toString ports.rogue} ${rogue.certFile} ${rogue.keyFile} ok"
        // mkServer "sick" "${tlsServer} ${toString ports.sick} ${trusted.certFile} ${trusted.keyFile} sick"
        // mkServer "sluggish" "${tlsServer} ${toString ports.sluggish} ${trusted.certFile} ${trusted.keyFile} hang"
        // mkServer "good" "${tlsServer} ${toString ports.good} ${trusted.certFile} ${trusted.keyFile} ok";

      system.stateVersion = stateVersion;
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    for name, port in (
        ("broken", ${toString ports.broken}),
        ("rogue", ${toString ports.rogue}),
        ("sick", ${toString ports.sick}),
        ("sluggish", ${toString ports.sluggish}),
        ("good", ${toString ports.good}),
    ):
        machine.wait_for_unit(f"probe-{name}.service")
        machine.wait_for_open_port(port, addr="127.0.0.1")

    # The timer must not have fired on its own; every assertion below is about a
    # hand-started run.
    machine.succeed("systemctl is-active connectivity-fallback-check.timer")
    machine.fail("systemctl is-active connectivity-fallback-setup.service")

    with subtest("four broken endpoints do not outvote a healthy one"):
        machine.succeed("systemctl start connectivity-fallback-check.service")
        # NB: not `log` -- that name is the test driver's own logger object.
        journal = machine.succeed("journalctl -u connectivity-fallback-check.service --no-pager")

        # Online, and specifically via the trusted endpoint.
        assert "online (via good.probe.test at 127.0.0.1)" in journal, journal

        # Every bad endpoint was actually attempted and rejected. Without this the test
        # could pass by probing only the good endpoint, which would not prove anything.
        for host in ("broken", "rogue", "sick", "sluggish"):
            assert f"probe failed for {host}.probe.test" in journal, journal

        # The whole point: no setup mode, so no AP and no reboot.
        machine.fail("systemctl is-active connectivity-fallback-setup.service")
        assert "entering setup mode" not in journal, journal

        # The hung endpoint really cost a timeout rather than failing fast for some other
        # reason -- otherwise connectivityCheck.timeoutSeconds would be untested.
        def mono(prop):
            # One property per call: `systemctl show` with several -p flags gives no
            # documented output order, and guessing it would make this silently wrong.
            return int(
                machine.succeed(
                    "systemctl show connectivity-fallback-check.service "
                    f"-p {prop} --value"
                ).strip()
            ) / 1e6

        elapsed = mono("ExecMainExitTimestampMonotonic") - mono("ExecMainStartTimestampMonotonic")
        machine.log(f"check took {elapsed:.1f}s with one hung endpoint")
        assert elapsed >= 3, f"check took only {elapsed}s; the hang was not waited on"

    with subtest("no amount of well-formed TLS substitutes for a 200"):
        # Drop the only endpoint that answers correctly. What is left is a middlebox cert
        # (`rogue` -- would answer 200 to anyone who skipped verification, so a stray -k
        # fails here), a 503 from an impeccable TLS server, a hang, and a TLS-level
        # failure. None of them is connectivity.
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
