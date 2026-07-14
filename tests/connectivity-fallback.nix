{ nixpkgs, pkgs, stateVersion, moduleUnderTest, extraMachineModules ? [ ] }:

# The whole setup-helper story on a REAL radio stack (mac80211_hwsim), nothing
# mocked but the internet itself. The machine runs the real iwd; the module's
# generated .ap profile must actually start a WPA2 AP. A "phone" lives in a
# network namespace holding the second hwsim radio AND one end of a veth pair:
#   * over the veth ("the LAN") it plays a wired neighbor for the station-mode
#     firewall checks: with the default-deny firewall module active, the AP
#     service ports must be unreachable in station mode even with listeners
#     bound, and reachable only while setup mode runs (the setup script inserts
#     session-scoped nixos-fw accepts, iifname-scoped to wlan0);
#   * over the air it provisions the machine like a phone would: associates with
#     passphrase == SSID, gets a DHCP lease through the firewall accepts, walks
#     captive DNS -> redirect -> portal, and submits home-wifi credentials.
# Reboots are real (portal submit and the setupTimeout safety net both
# power-cycle the VM); /var/lib/iwd sits on a persistent disk so credentials
# survive like on an SD card. Across three boots this covers: provisioning,
# psk persistence + iwd auto-joining the submitted network (check passes, setup
# never re-enters), the natural OnBootSec timer in both the online no-op and
# the offline self-heal directions, and the real safety-net reboot.
#
# Slow-boot proofing (a KVM-less CI runner boots this under TCG, where
# multi-user can take longer than bootGrace): the check timer is never disarmed
# and the driver never races it. Everything the check's outcome depends on is
# guest-side and ordered ahead of the timer (the boot-time home-router unit +
# the module's After=nftables.service), so the timer may fire before the driver
# gets a single command in and every phase still holds.
#
# bootGrace/setupTimeout are shortened here (KVM, interactive choreography);
# the PRODUCTION timer constants are covered by connectivity-fallback-timing.nix
# (icount time-warp). hwsim cannot model brcmfmac firmware quirks (pinned
# channel / DisableHT); those remain hardware-validated. The rpi kernel ships
# mac80211_hwsim (verified on the Pi, 6.18.34, 2026-07-14), so the aarch64
# variant runs this on the exact Pi kernel via rpiTestKernel (extraMachineModules).
let
  ssid = "nixos-rpi5-setup";
  homePsk = "homenet12345";

  wpaConf = pkgs.writeText "phone-wpa.conf" ''
    network={
      ssid="${ssid}"
      psk="${ssid}"
    }
  '';

  hostapdConf = pkgs.writeText "home-hostapd.conf" ''
    interface=wlan2
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
  name = "connectivity-fallback";
  hostPkgs = pkgs;

  nodes.machine = { config, lib, pkgs, ... }: {
    imports = [ moduleUnderTest ../modules/firewall.nix ] ++ extraMachineModules;

    networking.hostName = "nixos-rpi5";

    # Three virtual radios: phy0/wlan0 stays with the machine's iwd; phy1/wlan1
    # goes to the "phone" netns (test script); phy2/wlan2 goes to the "home"
    # netns (home-router unit below) so the home wifi exists on every boot.
    boot.kernelModules = [ "mac80211_hwsim" ];
    boot.extraModprobeConfig = "options mac80211_hwsim radios=3";

    # The home wifi network, brought up at BOOT from inside the guest (not by the
    # test driver): on a slow (TCG) boot the check timer can fire before the
    # driver gets a single command in, so anything the check's outcome depends on
    # must be ready guest-side, ordered ahead of the timer. Boot #1: beacons but
    # the machine has no credentials yet -> offline. Boot #2: the machine joins
    # with the portal-written psk -> online. Boot #3: the driver plants the
    # marker on the persistent disk during boot #2 -> no home wifi -> offline.
    systemd.services.home-router = {
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = "!/var/lib/iwd/test-no-home-router";
      path = [ pkgs.iproute2 pkgs.iw pkgs.coreutils ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        while [ ! -e /sys/class/net/wlan2 ]; do sleep 0.2; done
        ip netns add home
        phy="$(cat /sys/class/net/wlan2/phy80211/name)"
        iw phy "$phy" set netns name home
        ip netns exec home ip link set wlan2 up
        ip netns exec home ip addr replace 192.168.77.1/24 dev wlan2
        ${pkgs.systemd}/bin/systemd-run --unit=home-ap ip netns exec home \
          ${pkgs.hostapd}/bin/hostapd ${hostapdConf}
        ${pkgs.systemd}/bin/systemd-run --unit=home-dhcp ip netns exec home \
          ${pkgs.dnsmasq}/bin/dnsmasq -k --conf-file=/dev/null --port=0 \
          --interface=wlan2 --bind-interfaces \
          --dhcp-leasefile=/tmp/home-dnsmasq.leases \
          --dhcp-range=192.168.77.10,192.168.77.50,255.255.255.0,1h
        ${pkgs.systemd}/bin/systemd-run --unit=home-health ip netns exec home \
          ${pkgs.python3}/bin/python3 -m http.server 80 --bind 192.168.77.1
      '';
    };
    # The check must never race the home network's availability: hold the timer
    # until the home-router unit has finished (or been condition-skipped). An
    # already-elapsed OnBootSec then fires immediately when the timer starts.
    systemd.timers.connectivity-fallback-check.after = [ "home-router.service" ];

    networking.wireless.iwd.enable = true;
    # Let iwd configure the interface (DHCP) after joining a network, as the
    # check needs actual connectivity, not just an association.
    networking.wireless.iwd.settings.General.EnableNetworkConfiguration = true;

    common.connectivityFallback = {
      enable = true;
      # Only served from the "home network" netns -- offline by construction
      # until the machine joins HomeNet.
      connectivityCheck.url = "http://192.168.77.1/health";
      # Shortened (see header); safe on slow boots because nothing driver-side
      # races the timer (see the slow-boot proofing note above).
      bootGrace = "90s";
      setupTimeout = "3min";
    };

    # Test VMs have tmpfs roots; keep iwd's state (the portal-written
    # credentials) on a real disk so it survives the reboots like on the Pi.
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
        # The LAN: a veth pair into the netns, so the phone can also probe the
        # machine like a wired neighbor (192.168.99.1 = machine, .2 = phone).
        machine.succeed("ip link add lan0 type veth peer name lan1")
        machine.succeed("ip link set lan1 netns phone")
        machine.succeed("ip addr replace 192.168.99.1/24 dev lan0 && ip link set lan0 up")
        phone("ip addr replace 192.168.99.2/24 dev lan1")
        phone("ip link set lan1 up")


    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("iwd.service")
    machine.wait_until_succeeds("test -e /sys/class/net/wlan1")
    make_phone_ns()

    with subtest("sanity: the LAN veth carries traffic (phone reachable from machine)"):
        machine.succeed(
            "systemd-run --unit=sanityhttp ip netns exec phone "
            "${pkgs.python3}/bin/python3 -m http.server 8080"
        )
        machine.wait_until_succeeds("curl -s -o /dev/null http://192.168.99.2:8080/")
        machine.succeed("systemctl stop sanityhttp")

    with subtest("offline: the natural timer enters setup mode; a real WPA2 AP starts"):
        # The OnBootSec timer is deliberately NOT disarmed: on a slow (TCG) boot it
        # can fire before the driver gets a single command in, so the test must
        # tolerate setup mode being active at any point from here on. Not
        # wait_for_unit: that fails fast on "inactive, no pending jobs", the normal
        # state while the timer has not fired yet.
        machine.wait_until_succeeds(
            '[ "$(systemctl is-active connectivity-fallback-setup.service)" = active ]',
            timeout=300,
        )
        machine.wait_for_unit("connectivity-fallback-dnsmasq.service")
        machine.wait_for_unit("connectivity-fallback-portal.service")
        rules = machine.succeed("nft list chain inet nixos-fw input-allow")
        assert 'iifname "wlan0" udp dport { 53, 67 } accept' in rules, rules
        assert 'iifname "wlan0" tcp dport { 53, 80 } accept' in rules, rules
        # iwd really beacons: the phone's radio sees the setup SSID.
        machine.wait_until_succeeds(
            "ip netns exec phone iw dev wlan1 scan | grep -q 'SSID: ${ssid}'"
        )

    with subtest("AP profile pins the SSID/channel/width the firmware needs"):
        prof = "/var/lib/iwd/ap/${ssid}.ap"
        machine.succeed(f"grep -qx 'Passphrase=${ssid}' {prof}")
        machine.succeed(f"grep -qx 'Channel=6' {prof}")
        machine.succeed(f"grep -qx 'DisableHT=true' {prof}")

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
        ip_line = [l for l in lease.splitlines() if l.startswith("ip=10.42.0.")]
        assert ip_line, lease
        offered = int(ip_line[0].removeprefix("ip=10.42.0."))
        assert 10 <= offered <= 100, lease
        machine.succeed("grep -q . /run/connectivity-fallback-dnsmasq/dnsmasq.leases")
        dns = [l.removeprefix("dns=") for l in lease.splitlines() if l.startswith("dns=")][0]
        # The phone applies the DHCP-provided DNS (netns-scoped resolv.conf).
        machine.succeed(
            f"mkdir -p /etc/netns/phone && printf 'nameserver %s\\n' {dns} "
            "> /etc/netns/phone/resolv.conf"
        )

    with subtest("captive probe over the air reaches the portal form"):
        # `host` speaks DNS directly against the netns resolv.conf (the
        # DHCP-provided server), proving the wildcard answer. curl cannot do the
        # same on NixOS: glibc resolves via nscd, which runs in the ROOT network
        # namespace and cannot reach the AP subnet -- so the HTTP redirect flow
        # pins the mapping.
        machine.wait_until_succeeds(
            "ip netns exec phone host -t A captive.example | grep -q '10.42.0.1'"
        )
        page = machine.succeed(
            "ip netns exec phone curl -sL --resolve captive.example:80:10.42.0.1 "
            "http://captive.example/probe"
        )
        assert "Wi-Fi setup" in page, page
        assert 'action="/submit"' in page, page

    with subtest("invalid submission is rejected and writes nothing"):
        phone(
            "curl -s -o /dev/null -w '%{http_code}' -X POST --data 'ssid=Valid&psk=short' "
            "http://10.42.0.1/submit | grep -qx 400"
        )
        machine.succeed("! test -e /var/lib/iwd/Valid.psk")

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
        machine.succeed('[ "$(stat -c %a /var/lib/iwd/HomeNet.psk)" = 600 ]')

    with subtest("boot #2: the boot-time home router is up"):
        machine.wait_for_unit("home-router.service")
        machine.wait_for_unit("home-ap.service")
        machine.wait_for_unit("home-health.service")
        machine.wait_until_succeeds("test -e /sys/class/net/wlan1")
        make_phone_ns()

    with subtest("boot #2: iwd auto-joins HomeNet with the provisioned psk"):
        machine.wait_until_succeeds(
            "iw dev wlan0 link | grep -q 'SSID: HomeNet'", timeout=120
        )
        machine.wait_until_succeeds(
            "ip -4 -o addr show wlan0 | grep -q 192.168.77.", timeout=60
        )

    with subtest("boot #2, station mode: AP ports are firewalled even with listeners bound"):
        # Runs on boot #2 because station mode no longer exists on boot #1 (the
        # natural timer takes it to setup mode), and the port-80 listener would
        # collide with the portal there. The online check firing mid-subtest is
        # harmless -- it starts nothing.
        machine.succeed(
            "systemd-run --unit=fakeportal ${pkgs.python3}/bin/python3 "
            "-m http.server 80"
        )
        machine.succeed(
            "systemd-run --unit=fakedns ${pkgs.dnsmasq}/bin/dnsmasq -k "
            "--conf-file=/dev/null --no-resolv --no-hosts --port=53 "
            "--address=/#/192.0.2.1 --listen-address=192.168.99.1 --bind-interfaces"
        )
        # Connects to the machine's own veth IP arrive via lo (trusted), so
        # these prove the listeners answer -- the firewall is the only thing the
        # phone's failures below can be blamed on.
        machine.wait_until_succeeds("curl -s -o /dev/null http://192.168.99.1/")
        machine.wait_until_succeeds("host -t A -W 2 foo.example 192.168.99.1")
        machine.succeed("host -T -t A -W 2 foo.example 192.168.99.1")
        machine.fail(
            "ip netns exec phone curl -s --connect-timeout 3 -o /dev/null "
            "http://192.168.99.1/"
        )
        machine.fail("ip netns exec phone host -t A -W 2 foo.example 192.168.99.1")
        machine.fail("ip netns exec phone host -T -t A -W 2 foo.example 192.168.99.1")
        machine.succeed("systemctl stop fakeportal fakedns")

    with subtest("boot #2: natural timer fires online -> no setup mode"):
        machine.wait_until_succeeds(
            "journalctl -u connectivity-fallback-check.service "
            "| grep -q 'online, nothing to do'",
            timeout=180,
        )
        machine.succeed(
            '[ "$(systemctl is-active connectivity-fallback-setup.service)" = inactive ]'
        )

    with subtest("boot #2: home wifi dies -> setup re-opens the firewall; safety net reboots"):
        # Plant the marker (persistent disk) so boot #3 has no home wifi either.
        machine.succeed("touch /var/lib/iwd/test-no-home-router")
        machine.succeed("systemctl stop home-ap home-dhcp home-health")
        machine.succeed("systemctl start connectivity-fallback-check.service")
        machine.wait_for_unit("connectivity-fallback-setup.service")
        rules = machine.succeed("nft list chain inet nixos-fw input-allow")
        assert 'iifname "wlan0" udp dport { 53, 67 } accept' in rules, rules
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
