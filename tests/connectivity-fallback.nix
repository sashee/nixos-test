{ nixpkgs, pkgs, stateVersion, moduleUnderTest }:

# QEMU cannot emulate the brcmfmac radio, so the AP/station RADIO path is mocked here
# (fake iwctl/iw; the real-radio path is covered by connectivity-fallback-wifi.nix on
# mac80211_hwsim, and the brcmfmac firmware quirks only on real hardware). Everything
# else is real and exercised the way the field would:
#   * the AP interface is eth1 (the test VLAN) and a `prober` node plays the phone:
#     with the default-deny firewall module active, the AP service ports must be
#     unreachable in station mode (even with listeners bound) and reachable only while
#     setup mode runs (the setup script inserts session-scoped nftables accepts);
#   * the prober joins the AP subnet via real DHCP and reaches the portal through the
#     captive wildcard DNS + redirect, like a phone's connectivity probe;
#   * reboots are real (portal submit and the setupTimeout safety net both power-cycle
#     the VM); /var/lib/iwd sits on a persistent disk so written credentials survive;
#   * the OnBootSec check timer fires naturally for the online no-op (boot #2) and the
#     offline self-heal re-entry (boot #3); only boot #1 disarms it for the controlled
#     firewall/negative subtests.
let
  fakeIwctl = pkgs.writeShellScriptBin "iwctl" ''
    echo "iwctl $*" >> /tmp/iwctl.log
    exit 0
  '';
  fakeIw = pkgs.writeShellScriptBin "iw" ''
    echo "iw $*" >> /tmp/iw.log
    exit 0
  '';

  # udhcpc action script: configure the interface from the lease, record the offered
  # options for assertions, and point DNS at the lease's server like a real client.
  udhcpcScript = pkgs.writeShellScript "prober-udhcpc-script" ''
    case "$1" in
      bound|renew)
        ip addr add "$ip/''${mask:-24}" dev "$interface" 2>/dev/null || true
        printf 'ip=%s\nrouter=%s\ndns=%s\n' "$ip" "$router" "$dns" > /tmp/lease.env
        rm -f /etc/resolv.conf
        printf 'nameserver %s\n' "$dns" > /etc/resolv.conf
        ;;
    esac
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
      # Long enough for the setup-mode subtests, short enough to test the real
      # safety-net reboot on boot #2.
      setupTimeout = "3min";
      # OnBootSec must land AFTER the driver's first commands on every boot (it stops
      # the timer on boot #1 and starts fakehealth on boot #2), including slow hosts.
      bootGrace = "90s";
      tools.iwd = fakeIwctl;
      tools.iw = fakeIw;
    };

    # Test VMs have tmpfs roots; keep iwd's state (the portal-written credentials) on
    # a real disk so it survives the reboots like on the Pi.
    virtualisation.emptyDiskImages = [ { size = 32; driveConfig.deviceExtraOpts.serial = "iwdstate"; } ];
    virtualisation.fileSystems."/var/lib/iwd" = {
      device = "/dev/disk/by-id/virtio-iwdstate";
      fsType = "ext4";
      autoFormat = true;
    };

    environment.systemPackages = [ pkgs.curl pkgs.dnsutils ];
    system.stateVersion = stateVersion;
  };

  # The phone: joins the setup AP's network and provisions the machine from outside.
  nodes.prober = { pkgs, ... }: {
    networking.firewall.enable = false;
    environment.systemPackages = [ pkgs.curl pkgs.dnsutils ];
    system.stateVersion = stateVersion;
  };

  testScript = ''
    import time

    start_all()
    machine.wait_for_unit("multi-user.target")
    # Boot #1 is the controlled phase: disarm the natural OnBootSec trigger so the
    # station-mode subtests below cannot be raced by the check entering setup mode.
    machine.succeed("systemctl stop connectivity-fallback-check.timer")
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

    with subtest("offline: check enters setup mode and brings up AP services"):
        machine.succeed("systemctl start connectivity-fallback-check.service")
        machine.wait_for_unit("connectivity-fallback-setup.service")
        machine.wait_for_unit("connectivity-fallback-dnsmasq.service")
        machine.wait_for_unit("connectivity-fallback-portal.service")
        setup_started = time.monotonic()

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

    with subtest("prober joins the AP subnet via real DHCP"):
        prober.succeed("ip addr flush dev eth1")
        prober.wait_until_succeeds(
            "${pkgs.busybox}/bin/udhcpc -i eth1 -f -n -q -t 5 -T 3 "
            "-s ${udhcpcScript}"
        )
        lease = prober.succeed("cat /tmp/lease.env")
        assert "router=10.42.0.1" in lease, lease
        assert "dns=10.42.0.1" in lease, lease
        ip_line = [l for l in lease.splitlines() if l.startswith("ip=10.42.0.")]
        assert ip_line, lease
        offered = int(ip_line[0].removeprefix("ip=10.42.0."))
        assert 10 <= offered <= 100, lease
        machine.succeed(
            "grep -q . /run/connectivity-fallback-dnsmasq/dnsmasq.leases"
        )

    with subtest("captive probe: wildcard DNS + redirect lead to the portal form"):
        page = prober.wait_until_succeeds("curl -sL http://captive.example/probe")
        assert "Wi-Fi setup" in page, page
        assert 'action="/submit"' in page, page

    with subtest("invalid submission is rejected and writes nothing"):
        prober.succeed(
            "curl -s -o /dev/null -w '%{http_code}' -X POST --data 'ssid=Valid&psk=short' "
            "http://10.42.0.1/submit | grep -qx 400"
        )
        machine.succeed("! test -e /var/lib/iwd/Valid.psk")

    with subtest("submitting credentials reboots the machine for real"):
        prober.succeed(
            "curl -s -X POST --data 'ssid=MyNet&psk=secret12345' "
            "http://10.42.0.1/submit | grep -q Saved"
        )
        machine.wait_for_shutdown()
        # Well before the 3min safety net: the reboot cause was the submit.
        assert time.monotonic() - setup_started < 150

    with subtest("boot #2: written credentials persisted where iwd looks for them"):
        machine.start()
        machine.wait_for_unit("multi-user.target")
        machine.succeed("grep -qx 'Passphrase=secret12345' /var/lib/iwd/MyNet.psk")
        machine.succeed('[ "$(stat -c %a /var/lib/iwd/MyNet.psk)" = 600 ]')

    with subtest("boot #2: natural timer fires online -> no setup mode"):
        machine.succeed(
            "systemd-run --unit=fakehealth ${pkgs.python3}/bin/python3 "
            "-m http.server 8080 --bind 127.0.0.1"
        )
        machine.wait_until_succeeds(
            "journalctl -u connectivity-fallback-check.service "
            "| grep -q 'online, nothing to do'",
            timeout=180,
        )
        machine.succeed(
            '[ "$(systemctl is-active connectivity-fallback-setup.service)" = inactive ]'
        )

    with subtest("boot #2: setup re-opens the firewall and the safety-net reboot fires"):
        machine.succeed("systemctl stop fakehealth")
        machine.succeed("systemctl start connectivity-fallback-check.service")
        machine.wait_for_unit("connectivity-fallback-setup.service")
        rules = machine.succeed("nft list chain inet nixos-fw input-allow")
        assert 'iifname "eth1" udp dport { 53, 67 } accept' in rules, rules
        # The setupTimeout (3min) systemd-run unit reboots the machine on its own.
        machine.wait_for_shutdown()

    with subtest("boot #3: self-heal loop re-enters setup mode with no help"):
        machine.start()
        machine.wait_for_unit("multi-user.target")
        machine.wait_until_succeeds(
            '[ "$(systemctl is-active connectivity-fallback-setup.service)" = active ]',
            timeout=240,
        )
  '';
}
