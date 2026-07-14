{ nixpkgs, pkgs, stateVersion, moduleUnderTest }:

# Full provisioning loop on a REAL radio stack via mac80211_hwsim: nothing is mocked.
# The machine runs the real iwd; the module's generated .ap profile must actually
# start a WPA2 AP (catching profile-syntax/iwd-API regressions that the mocked
# connectivity-fallback test cannot). A "phone" lives in a network namespace holding
# the second hwsim radio: it associates with passphrase == SSID, gets a DHCP lease
# over the air (through the session-scoped nixos-fw accepts on wlan0), walks the
# captive DNS -> redirect -> portal flow, and submits home-wifi credentials. The
# machine then really reboots, and — the payoff — iwd auto-joins the submitted
# network (psk persisted on disk), the connectivity check passes, and setup mode
# never re-enters. hwsim cannot model the brcmfmac firmware quirks (pinned channel /
# DisableHT); those remain hardware-validated.
#
# x86-only: the rpi test kernel may not ship mac80211_hwsim.
let
  ssid = "nixos-rpi5-setup";
  homePsk = "homenet12345";

  wpaConf = pkgs.writeText "phone-wpa.conf" ''
    network={
      ssid="${ssid}"
      psk="${ssid}"
    }
  '';

  hostapdConf = pkgs.writeText "phone-hostapd.conf" ''
    interface=wlan1
    driver=nl80211
    ssid=HomeNet
    hw_mode=g
    channel=6
    wpa=2
    wpa_key_mgmt=WPA-PSK
    wpa_passphrase=${homePsk}
    rsn_pairwise=CCMP
  '';

  # udhcpc action script for the phone (runs inside the netns): configure the
  # interface from the lease and record the offered options for assertions.
  udhcpcScript = pkgs.writeShellScript "phone-udhcpc-script" ''
    # $ip/$mask/$router/$dns/$interface come from udhcpc's lease environment.
    IP=${pkgs.iproute2}/bin/ip
    case "$1" in
      bound|renew)
        $IP addr replace "$ip/''${mask:-24}" dev "$interface"
        $IP route replace default via "$router"
        printf 'ip=%s\nrouter=%s\ndns=%s\n' "$ip" "$router" "$dns" > /tmp/phone-lease.env
        ;;
    esac
  '';
in
nixpkgs.lib.nixos.runTest {
  name = "connectivity-fallback-wifi";
  hostPkgs = pkgs;

  nodes.machine = { config, lib, pkgs, ... }: {
    imports = [ moduleUnderTest ../modules/firewall.nix ];

    networking.hostName = "nixos-rpi5";

    # Two virtual radios: phy0/wlan0 stays with the machine's iwd; phy1/wlan1 is
    # moved into the "phone" netns by the test script.
    boot.kernelModules = [ "mac80211_hwsim" ];

    networking.wireless.iwd.enable = true;
    # Let iwd configure the interface (DHCP) after joining a network, as the check
    # needs actual connectivity, not just an association.
    networking.wireless.iwd.settings.General.EnableNetworkConfiguration = true;

    common.connectivityFallback = {
      enable = true;
      # Only served from the "home network" netns -- offline by construction until
      # the machine joins HomeNet.
      connectivityCheck.url = "http://192.168.77.1/health";
      # Room for the natural-timer waits and the over-the-air provisioning flow.
      bootGrace = "2min";
      setupTimeout = "5min";
    };

    # Test VMs have tmpfs roots; the portal-written credentials must survive the
    # reboot for iwd to auto-join HomeNet on boot #2.
    virtualisation.emptyDiskImages = [ { size = 32; driveConfig.deviceExtraOpts.serial = "iwdstate"; } ];
    virtualisation.fileSystems."/var/lib/iwd" = {
      device = "/dev/disk/by-id/virtio-iwdstate";
      fsType = "ext4";
      autoFormat = true;
    };

    environment.systemPackages = [ pkgs.curl pkgs.dnsutils ];
    system.stateVersion = stateVersion;
  };

  testScript = ''
    def phone(cmd):
        return machine.succeed(f"ip netns exec phone {cmd}")


    def make_phone_ns():
        machine.succeed("ip netns add phone")
        machine.succeed(
            'phy="$(cat /sys/class/net/wlan1/phy80211/name)"; '
            'iw phy "$phy" set netns name phone'
        )
        # Moving the phy leaves the interface down in the new namespace.
        machine.succeed("ip netns exec phone ip link set wlan1 up")


    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("iwd.service")
    machine.wait_until_succeeds("test -e /sys/class/net/wlan1")
    make_phone_ns()

    with subtest("boot #1: natural timer fires offline and starts a real WPA2 AP"):
        # Not wait_for_unit: that fails fast on "inactive, no pending jobs", which is
        # exactly the state while the OnBootSec timer has not fired yet.
        machine.wait_until_succeeds(
            '[ "$(systemctl is-active connectivity-fallback-setup.service)" = active ]',
            timeout=300,
        )
        machine.wait_for_unit("connectivity-fallback-dnsmasq.service")
        machine.wait_for_unit("connectivity-fallback-portal.service")
        rules = machine.succeed("nft list chain inet nixos-fw input-allow")
        assert 'iifname "wlan0" udp dport { 53, 67 } accept' in rules, rules
        # iwd really beacons: the phone's radio sees the setup SSID.
        machine.wait_until_succeeds(
            "ip netns exec phone iw dev wlan1 scan | grep -q 'SSID: ${ssid}'"
        )

    with subtest("phone associates with passphrase == SSID and gets a DHCP lease"):
        phone("${pkgs.wpa_supplicant}/bin/wpa_supplicant -B -i wlan1 -c ${wpaConf}")
        machine.wait_until_succeeds(
            "ip netns exec phone iw dev wlan1 link | grep -q 'SSID: ${ssid}'"
        )
        machine.wait_until_succeeds(
            "ip netns exec phone ${pkgs.busybox}/bin/udhcpc -i wlan1 -f -n -q -t 8 -T 3 "
            "-s ${udhcpcScript}"
        )
        lease = machine.succeed("cat /tmp/phone-lease.env")
        assert "router=10.42.0.1" in lease, lease
        assert "dns=10.42.0.1" in lease, lease
        dns = [l.removeprefix("dns=") for l in lease.splitlines() if l.startswith("dns=")][0]
        # The phone applies the DHCP-provided DNS (netns-scoped resolv.conf).
        machine.succeed(
            f"mkdir -p /etc/netns/phone && printf 'nameserver %s\\n' {dns} "
            "> /etc/netns/phone/resolv.conf"
        )

    with subtest("captive probe over the air reaches the portal form"):
        # `host` speaks DNS directly against the netns resolv.conf (the DHCP-provided
        # server), proving the wildcard answer. curl cannot do the same on NixOS:
        # glibc resolves via nscd, which runs in the ROOT network namespace and
        # cannot reach the AP subnet -- so the HTTP redirect flow pins the mapping.
        machine.wait_until_succeeds(
            "ip netns exec phone host -t A captive.example | grep -q '10.42.0.1'"
        )
        page = machine.succeed(
            "ip netns exec phone curl -sL --resolve captive.example:80:10.42.0.1 "
            "http://captive.example/probe"
        )
        assert "Wi-Fi setup" in page, page
        assert 'action="/submit"' in page, page

    with subtest("phone submits the home network; machine reboots for real"):
        phone(
            "curl -s -X POST --data 'ssid=HomeNet&psk=${homePsk}' "
            "http://10.42.0.1/submit | grep -q Saved"
        )
        machine.wait_for_shutdown()

    with subtest("boot #2: portal-written psk persisted for iwd"):
        machine.start()
        machine.wait_for_unit("multi-user.target")
        machine.succeed("grep -qx 'Passphrase=${homePsk}' /var/lib/iwd/HomeNet.psk")

    with subtest("boot #2: home router comes up in the netns"):
        machine.wait_until_succeeds("test -e /sys/class/net/wlan1")
        make_phone_ns()
        phone("ip addr replace 192.168.77.1/24 dev wlan1")
        phone("ip link set wlan1 up")
        machine.succeed(
            "systemd-run --unit=home-ap ip netns exec phone "
            "${pkgs.hostapd}/bin/hostapd ${hostapdConf}"
        )
        machine.succeed(
            "systemd-run --unit=home-dhcp ip netns exec phone "
            "${pkgs.dnsmasq}/bin/dnsmasq -k --conf-file=/dev/null --port=0 "
            "--interface=wlan1 --bind-interfaces "
            "--dhcp-leasefile=/tmp/phone-dnsmasq.leases "
            "--dhcp-range=192.168.77.10,192.168.77.50,255.255.255.0,1h"
        )
        machine.succeed(
            "systemd-run --unit=home-health ip netns exec phone "
            "${pkgs.python3}/bin/python3 -m http.server 80 --bind 192.168.77.1"
        )

    with subtest("boot #2: iwd auto-joins HomeNet with the provisioned psk"):
        machine.wait_until_succeeds(
            "iw dev wlan0 link | grep -q 'SSID: HomeNet'", timeout=120
        )
        machine.wait_until_succeeds(
            "ip -4 -o addr show wlan0 | grep -q 192.168.77.", timeout=60
        )

    with subtest("boot #2: connectivity check passes; setup mode never re-enters"):
        machine.wait_until_succeeds(
            "journalctl -u connectivity-fallback-check.service "
            "| grep -q 'online, nothing to do'",
            timeout=240,
        )
        machine.succeed(
            '[ "$(systemctl is-active connectivity-fallback-setup.service)" = inactive ]'
        )
  '';
}
