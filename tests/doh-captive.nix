{ nixpkgs, pkgs, commonDesktopModule, stateVersion }:

nixpkgs.lib.nixos.runTest {
  name = "doh-captive";
  hostPkgs = pkgs;
  skipTypeCheck = true;

  nodes.machine = { pkgs, ... }: {
    imports = [ commonDesktopModule ];

    networking.hostName = "doh-captive-test";
    common.autoUpgrade.enable = false;
    common.monitoring.enable = false;
    common.irohSsh.enable = false;
    system.stateVersion = stateVersion;
  };

  # The test VM is hermetic: dnscrypt-proxy has no reachable DoH upstream, which
  # is exactly the "behind a captive portal" condition. So the only names that
  # resolve are the ones served from the static captive-portals map.
  testScript = ''
    import time

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("dnscrypt-proxy.service")

    # The map file is wired into the generated dnscrypt-proxy config...
    machine.succeed("${pkgs.gnugrep}/bin/grep -E '^\\s*map_file' /nix/store/*-dnscrypt-proxy.toml")
    # ...and NetworkManager probes a mapped host for connectivity/portal state.
    machine.succeed("${pkgs.gnugrep}/bin/grep -i 'detectportal.firefox.com' /etc/NetworkManager/NetworkManager.conf")

    def dig_short(name, qtype, server="127.0.0.1"):
        # 2>/dev/null keeps dig diagnostics out of the captured output; for a
        # successful answer +short prints just the address(es). `server` lets us
        # also exercise the IPv6 loopback listener (::1).
        return machine.succeed(
            "${pkgs.dig}/bin/dig @{} {} {} +short +time=3 +tries=1 2>/dev/null || true".format(server, name, qtype)
        ).strip()

    def wait_mapped(name, qtype, expected, server="127.0.0.1"):
        for _ in range(30):
            if expected in dig_short(name, qtype, server):
                return
            time.sleep(1)
        raise Exception(f"{name} {qtype} did not resolve to {expected} via {server}")

    # Mapped names resolve to their static IPs despite there being no upstream.
    wait_mapped("captive.apple.com", "A", "17.253.109.201")
    wait_mapped("detectportal.firefox.com", "A", "34.107.221.82")
    wait_mapped("dns.msftncsi.com", "AAAA", "fd3e:4f5a:5b81::1")
    wait_mapped("ipv4only.arpa", "A", "192.0.0.170")

    # The dnscrypt listener answers over the IPv6 loopback too, and AAAA records
    # from the map resolve there: query ::1 directly.
    wait_mapped("detectportal.firefox.com", "AAAA", "2600:1901:0:38d7::", server="::1")
    wait_mapped("ipv6.msftconnecttest.com", "AAAA", "2a01:111:2003::52", server="::1")

    # A name that is not in the map gets no successful answer, because no upstream
    # is reachable. This proves the map is the only thing answering: dnscrypt
    # either times out ("no servers could be reached") or returns a non-NOERROR
    # status with zero answer records.
    _, unmapped = machine.execute("${pkgs.dig}/bin/dig @127.0.0.1 nonexistent.captive.invalid A +time=3 +tries=1 2>&1")
    assert (
        "no servers could be reached" in unmapped
        or "status: SERVFAIL" in unmapped
        or "ANSWER: 0" in unmapped
    ), f"unmapped name unexpectedly resolved: {unmapped}"
  '';
}
