{ nixpkgs, pkgs, stateVersion, machineModule }:

# spec/features/wifi.md -- power save is off -- on a real radio stack (mac80211_hwsim), against
# whichever wifi daemon the host config runs: iwd on rpi5, NetworkManager on the laptops. The
# test picks the daemon from the node's own config, so a host that switches stack is tested as
# deployed rather than as this file assumed.
#
# The second hwsim radio is the access point, moved into its own network namespace and beaconing
# a WPA2 network before the daemon starts, with the daemon's profile for it already in place --
# so the node comes up exactly like a host with a known network in range. wlan0 is also put in
# power save before the daemon starts: hwsim comes up with it off, where real chips (the Pi's
# brcmfmac, the laptops' radios) come up with it on, and an "off" the radio started with would
# pass this test without the daemon doing anything. Then:
#
#   1. at boot: associated by itself, power save reads off;
#   2. with the daemon out of the picture, power save is switched back on;
#   3. the daemon reconnects and power save is off again -- so it is applied on every
#      connection, not once at boot.
#
# Both go through the daemon's real path, not a re-read of its config: iwd disables power save
# per interface as it brings the netdev up (stopped, its socket-owned connection drops with it,
# so the restart is a fresh bring-up), and NetworkManager on each activation. With the setting
# removed the test fails, for both daemons.
#
# What hwsim cannot show is brcmfmac honouring the request; on the Pi that is
# `iw dev wlan0 get power_save`.
let
  ssid = "TestNet";
  passphrase = "testnet12345";

  hostapdConf = pkgs.writeText "test-hostapd.conf" ''
    interface=wlan1
    driver=nl80211
    ssid=${ssid}
    hw_mode=g
    channel=6
    wpa=2
    wpa_key_mgmt=WPA-PSK
    wpa_passphrase=${passphrase}
    rsn_pairwise=CCMP
  '';

  iwdProfile = pkgs.writeText "${ssid}.psk" ''
    [Security]
    Passphrase=${passphrase}
  '';

  # No IP configuration: the AP side runs no DHCP server, and association is all this test
  # reads. With both methods disabled NetworkManager completes activation at layer 2.
  nmProfile = pkgs.writeText "${ssid}.nmconnection" ''
    [connection]
    id=${ssid}
    type=wifi
    interface-name=wlan0

    [wifi]
    mode=infrastructure
    ssid=${ssid}

    [wifi-security]
    key-mgmt=wpa-psk
    psk=${passphrase}

    [ipv4]
    method=disabled

    [ipv6]
    method=disabled
  '';
in
nixpkgs.lib.nixos.runTest {
  name = "wifi";
  hostPkgs = pkgs;
  # Generous ceiling (not a fixed wait): fine under KVM, but the rpi variant runs under slow
  # TCG emulation on the KVM-less aarch64 CI runner.
  globalTimeout = 1800;

  nodes.machine = { config, lib, pkgs, ... }: {
    imports = [ machineModule ];

    networking.hostName = "wifi-test";
    system.stateVersion = stateVersion;

    # phy0/wlan0 stays with the daemon under test; phy1/wlan1 becomes the access point.
    boot.kernelModules = [ "mac80211_hwsim" ];
    boot.extraModprobeConfig = "options mac80211_hwsim radios=2";

    environment.systemPackages = [ pkgs.iw ];

    # qemu-vm.nix forces `networking.wireless.enable = mkVMOverride false` on every test VM,
    # which on a NetworkManager host removes the wpa_supplicant it drives -- NM then fails to
    # D-Bus activate it and never touches the radio. Undo exactly that override, under the
    # same condition NM's own module turns wpa_supplicant on, so the node runs the deployed
    # stack. iwd hosts keep it off, as deployed (iwd refuses to run alongside it).
    networking.wireless.enable = lib.mkIf
      (config.networking.networkmanager.enable
        && config.networking.networkmanager.wifi.backend == "wpa_supplicant")
      (lib.mkOverride 9 true);

    # The Pi's lifecycle for hwsim's radio: iwd keeps brcmfmac's default interface (its built-in
    # DriverQuirks list) but deletes and recreates any other, and a recreated netdev starts with
    # power save off -- dropping the boot state set below, and taking wlan0 away whenever iwd
    # stops. Inert on a host without iwd.
    networking.wireless.iwd.settings.DriverQuirks.DefaultInterface = "mac80211_hwsim";

    # Ahead of the daemon, so wlan1 is gone from its namespace before it can claim the radio,
    # wlan0 is in the power-save state real hardware boots with (see the header), and the
    # profile is there when the daemon loads its known networks. wpa_supplicant too: the move
    # is a wlan "remove" uevent, and nixpkgs' udev rule answers that with a try-restart that
    # kills a wpa_supplicant still in its start-up.
    systemd.services.test-wifi-setup = {
      wantedBy = [ "multi-user.target" ];
      before = [ "iwd.service" "NetworkManager.service" "wpa_supplicant.service" ];
      path = [ pkgs.iproute2 pkgs.iw pkgs.coreutils pkgs.systemd ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        while [ ! -e /sys/class/net/wlan1 ]; do sleep 0.2; done
        iw dev wlan0 set power_save on
        ip netns add ap
        iw phy "$(cat /sys/class/net/wlan1/phy80211/name)" set netns name ap
        ip netns exec ap ip link set wlan1 up
        systemd-run --unit=test-hostapd ip netns exec ap ${pkgs.hostapd}/bin/hostapd ${hostapdConf}
      '' + lib.optionalString config.networking.wireless.iwd.enable ''
        install -d -m 0700 /var/lib/iwd
        install -m 0600 ${iwdProfile} /var/lib/iwd/${ssid}.psk
      '' + lib.optionalString config.networking.networkmanager.enable ''
        install -d -m 0700 /run/NetworkManager/system-connections
        install -m 0600 ${nmProfile} /run/NetworkManager/system-connections/${ssid}.nmconnection
      '';
    };
  };

  testScript = { nodes, ... }:
    let
      iwd = nodes.machine.networking.wireless.iwd.enable;
      networkmanager = nodes.machine.networking.networkmanager.enable;
      # Take the daemon out of the picture / hand the radio back to it. `nmcli connection
      # down` also blocks the profile's autoconnect, so NetworkManager stays out until `up`.
      release = if iwd then "systemctl stop iwd.service" else "nmcli connection down ${ssid}";
      resume = if iwd then "systemctl start iwd.service" else "nmcli connection up ${ssid}";
    in
    if iwd == networkmanager then
      throw "tests/wifi.nix: expected exactly one of iwd and NetworkManager on the node"
    else ''
      def power_save():
          return machine.succeed("iw dev wlan0 get power_save").strip()


      def wait_associated():
          machine.wait_until_succeeds("iw dev wlan0 link | grep -q 'SSID: ${ssid}'", timeout=300)


      machine.wait_for_unit("multi-user.target")

      with subtest("joins the known network by itself, with power save off"):
          wait_associated()
          assert power_save() == "Power save: off", power_save()

      with subtest("without the daemon, power save can be switched back on"):
          machine.succeed("${release}")
          machine.wait_until_succeeds("iw dev wlan0 link | grep -q 'Not connected'", timeout=60)
          machine.succeed("iw dev wlan0 set power_save on")
          assert power_save() == "Power save: on", power_save()

      with subtest("the daemon turns it off again when it reconnects"):
          machine.succeed("${resume}")
          wait_associated()
          assert power_save() == "Power save: off", power_save()
    '';
}
