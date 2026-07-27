{ nixpkgs, pkgs, commonDesktopModule, stateVersion }:

let
  # Expected answers are read from lib/captive-portals.txt rather than written out here.
  # These assertions used to hardcode the addresses, so when detectportal.firefox.com
  # moved CDN in July 2026 they went on asserting the dead address -- pinning the bug
  # instead of catching it.
  portalMap = import ../lib/captive-portals.nix { lib = pkgs.lib; };

  # The whole map as { "<name>": {"A": [...], "AAAA": [...]}, ... } for the driver. Only
  # strings, lists and attrsets, so the JSON is a valid Python literal and json.loads takes
  # it verbatim.
  #
  # This is what makes the test below a differential check rather than a tautology.
  # dnscrypt-proxy parses lib/captive-portals.txt itself (modules/doh.nix passes the path as
  # captive_portals.map_file); the expectations here come through lib/captive-portals.nix,
  # which has no test of its own. Comparing the two is the only thing in the repo that would
  # notice a parser that mangled or dropped addresses -- the nm-captive-portal tests cannot,
  # because they bind whatever that parser produced and so agree with it by construction.
  expectedJson = builtins.toJSON (
    pkgs.lib.mapAttrs (_: f: {
      A = f.ipv4;
      AAAA = f.ipv6;
    }) portalMap.byFamily
  );
in
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
    import ipaddress
    import json
    import time

    # Single-quoted on purpose: the JSON contains double quotes but never a single quote, and
    # a Python triple-quoted string cannot be written inside a Nix indented string anyway --
    # Nix reads a run of two single quotes as the string terminator and three as an escape
    # for two.
    expected = json.loads('${expectedJson}')

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

    def norm(addrs):
        # Compare parsed addresses, not strings: dig prints IPv6 in canonical form and the
        # map file's spelling need not match it character for character.
        return sorted(ipaddress.ip_address(a) for a in addrs)

    def wait_mapped(name, qtype, want, server="127.0.0.1"):
        # Set equality, not "contains": asserting that each expected address appears would
        # still pass if the map served only one of the four, which is exactly the failure
        # this test exists to catch. An unexpected EXTRA answer fails here too.
        got = []
        for _ in range(30):
            got = dig_short(name, qtype, server).split()
            try:
                if got and norm(got) == norm(want):
                    return
            except ValueError:
                # Something that is not an address at all -- keep the mismatch message
                # readable instead of raising from inside ipaddress.
                pass
            time.sleep(1)
        raise Exception(f"{name} {qtype} via {server}: want {sorted(want)}, got {sorted(got)}")

    # Every name in the map, every address, both families: dnscrypt-proxy answers a mapped
    # name with the entry's whole RRset (verified against dnscrypt-proxy 2.1.15), so the
    # full set is assertable and anything less leaves the parser unchecked -- see
    # `expectedJson` above for why this comparison is the point of the test.
    for name, families in sorted(expected.items()):
        for qtype in ("A", "AAAA"):
            if families[qtype]:
                wait_mapped(name, qtype, families[qtype])

    # The dnscrypt listener answers over the IPv6 loopback too, and AAAA records from the
    # map resolve there: query ::1 directly. Every AAAA-carrying name, since the addresses
    # are already to hand.
    for name, families in sorted(expected.items()):
        if families["AAAA"]:
            wait_mapped(name, "AAAA", families["AAAA"], server="::1")

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
