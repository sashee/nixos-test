{ nixpkgs, pkgs, stateVersion, moduleUnderTest }:

# QEMU cannot emulate the brcmfmac radio, so the AP/station path is not exercised here
# (that is validated on real hardware). This test covers the module's LOGIC with the
# radio-side effects mocked: offline-detection -> setup trigger, the captive portal
# (form + probe redirect), wildcard DNS, credential writing, and the .ap profile
# rendering (SSID-named file + Channel + DisableHT -- the bits the firmware needs).
#
# The AP interface is eth1 (the test VLAN) instead of a wifi radio, and a second
# `prober` node stands in for a phone joining the setup AP. That makes the firewall
# behavior observable end-to-end: with the default-deny firewall module active, the
# AP service ports must be unreachable from the prober in station mode (even with
# listeners bound to them) and reachable only while setup mode runs (the setup script
# inserts session-scoped nftables accepts).
let
  fakeIwctl = pkgs.writeShellScriptBin "iwctl" ''
    echo "iwctl $*" >> /tmp/iwctl.log
    exit 0
  '';
  fakeIw = pkgs.writeShellScriptBin "iw" ''
    echo "iw $*" >> /tmp/iw.log
    exit 0
  '';
  # Intercept the portal's `systemctl reboot` so the test VM does not actually reboot;
  # everything else still goes to the real systemctl.
  fakeSystemctl = pkgs.writeShellScriptBin "systemctl" ''
    if [ "$1" = "reboot" ]; then
      echo reboot >> /tmp/reboot.log
      exit 0
    fi
    exec /run/current-system/sw/bin/systemctl "$@"
  '';
in
nixpkgs.lib.nixos.runTest {
  name = "connectivity-fallback";
  hostPkgs = pkgs;

  nodes.machine = { config, lib, pkgs, ... }: {
    imports = [ moduleUnderTest ../modules/firewall.nix ];

    networking.hostName = "nixos-rpi5";
    # The module layers on iwd (assertion). No wifi device exists in the VM, so keep
    # iwd.service from starting -- its failure would be irrelevant noise.
    networking.wireless.iwd.enable = true;
    systemd.services.iwd.wantedBy = lib.mkForce [ ];

    common.connectivityFallback = {
      enable = true;
      # The test-VLAN interface stands in for the wifi radio, so the prober's packets
      # arrive on the AP interface and the interface-scoped firewall rules apply.
      interface = "eth1";
      # A local server the test toggles stands in for "the internet".
      connectivityCheck.url = "http://127.0.0.1:8080/health";
      # Push the safety-net reboot far away so it cannot fire mid-test.
      setupTimeout = "1h";
      tools.iwd = fakeIwctl;
      tools.iw = fakeIw;
    };
    # Neutralize the portal's reboot (fires ~2s after a successful submit).
    systemd.services.connectivity-fallback-portal.path = lib.mkForce [ fakeSystemctl ];

    environment.systemPackages = [ pkgs.curl pkgs.dnsutils ];
    system.stateVersion = stateVersion;
  };

  # A device on the AP's network: probes the AP service ports from outside.
  nodes.prober = { pkgs, ... }: {
    networking.firewall.enable = false;
    environment.systemPackages = [ pkgs.curl pkgs.dnsutils ];
    system.stateVersion = stateVersion;
  };

  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    prober.wait_for_unit("multi-user.target")

    machine_ip = machine.succeed(
        "ip -4 -o addr show eth1 | head -n1 | awk '{print $4}' | cut -d/ -f1"
    ).strip()
    prober_ip = prober.succeed(
        "ip -4 -o addr show eth1 | head -n1 | awk '{print $4}' | cut -d/ -f1"
    ).strip()

    with subtest("sanity: the VLAN carries traffic (prober is reachable from machine)"):
        prober.succeed(
            "systemd-run --unit=sanityhttp ${pkgs.python3}/bin/python3 "
            "-m http.server 8080"
        )
        machine.wait_until_succeeds(f"curl -s -o /dev/null http://{prober_ip}:8080/")
        prober.succeed("systemctl stop sanityhttp")

    with subtest("station mode: AP ports are firewalled even with listeners bound"):
        machine.succeed(
            "systemd-run --unit=fakeportal ${pkgs.python3}/bin/python3 "
            "-m http.server 80"
        )
        machine.succeed(
            "systemd-run --unit=fakedns ${pkgs.dnsmasq}/bin/dnsmasq -k "
            "--conf-file=/dev/null --no-resolv --no-hosts --port=53 "
            f"--address=/#/192.0.2.1 --listen-address={machine_ip} --bind-interfaces"
        )
        # Connects to the machine's own eth1 IP arrive via lo (trusted), so these
        # prove the listeners answer -- the firewall is the only thing the prober's
        # failures below can be blamed on.
        machine.wait_until_succeeds(f"curl -s -o /dev/null http://{machine_ip}/")
        machine.wait_until_succeeds(f"host -t A -W 2 foo.example {machine_ip}")
        machine.succeed(f"host -T -t A -W 2 foo.example {machine_ip}")
        prober.fail(f"curl -s --connect-timeout 3 -o /dev/null http://{machine_ip}/")
        prober.fail(f"host -t A -W 2 foo.example {machine_ip}")
        prober.fail(f"host -T -t A -W 2 foo.example {machine_ip}")
        machine.succeed("systemctl stop fakeportal fakedns")

    with subtest("online: check does not enter setup mode"):
        machine.succeed(
            "systemd-run --unit=fakehealth ${pkgs.python3}/bin/python3 "
            "-m http.server 8080 --bind 127.0.0.1"
        )
        machine.wait_until_succeeds("curl -s -o /dev/null http://127.0.0.1:8080/")
        machine.succeed("systemctl start connectivity-fallback-check.service")
        machine.succeed(
            '[ "$(systemctl is-active connectivity-fallback-setup.service)" = inactive ]'
        )
        machine.succeed("systemctl stop fakehealth")

    with subtest("offline: check enters setup mode and brings up AP services"):
        machine.succeed("systemctl start connectivity-fallback-check.service")
        machine.wait_for_unit("connectivity-fallback-setup.service")
        machine.wait_for_unit("connectivity-fallback-dnsmasq.service")
        machine.wait_for_unit("connectivity-fallback-portal.service")

    with subtest("setup mode inserts the session-scoped firewall accepts"):
        rules = machine.succeed("nft list chain inet nixos-fw input-allow")
        assert 'iifname "eth1" udp dport { 53, 67 } accept' in rules, rules
        assert 'iifname "eth1" tcp dport { 53, 80 } accept' in rules, rules

    with subtest("AP profile pins the SSID/channel/width the firmware needs"):
        prof = "/var/lib/iwd/ap/nixos-rpi5-setup.ap"
        machine.succeed(f"grep -qx 'Passphrase=nixos-rpi5-setup' {prof}")
        machine.succeed(f"grep -qx 'Channel=6' {prof}")
        machine.succeed(f"grep -qx 'DisableHT=true' {prof}")
        machine.succeed("grep -q 'set-property Mode ap' /tmp/iwctl.log")
        machine.succeed("grep -q 'start-profile nixos-rpi5-setup' /tmp/iwctl.log")

    with subtest("setup mode: portal and DNS are reachable from the prober"):
        # The prober joins the AP subnet (a real client would get this via DHCP).
        prober.succeed("ip addr add 10.42.0.50/24 dev eth1")
        prober.wait_until_succeeds(
            "curl -s -o /dev/null -w '%{http_code}' http://10.42.0.1/ | grep -qx 200"
        )
        prober.succeed(
            "curl -s -o /dev/null -w '%{http_code}' http://10.42.0.1/generate_204 | grep -qx 302"
        )
        prober.wait_until_succeeds(
            "host -t A whatever.example 10.42.0.1 | grep -q '10.42.0.1'"
        )
        prober.succeed("host -T -t A whatever.example 10.42.0.1 | grep -q '10.42.0.1'")

    with subtest("submitting credentials writes the psk and triggers reboot"):
        prober.succeed(
            "curl -s -o /dev/null -X POST --data 'ssid=MyNet&psk=secret12345' "
            "http://10.42.0.1/submit"
        )
        machine.wait_until_succeeds("test -f /var/lib/iwd/MyNet.psk")
        machine.succeed("grep -qx 'Passphrase=secret12345' /var/lib/iwd/MyNet.psk")
        machine.succeed('[ "$(stat -c %a /var/lib/iwd/MyNet.psk)" = 600 ]')
        machine.wait_until_succeeds("test -f /tmp/reboot.log")

    with subtest("invalid submission is rejected and writes nothing"):
        machine.succeed(
            "curl -s -o /dev/null -w '%{http_code}' -X POST --data 'ssid=Valid&psk=short' "
            "http://127.0.0.1/submit | grep -qx 400"
        )
        machine.succeed("! test -e /var/lib/iwd/Valid.psk")
  '';
}
