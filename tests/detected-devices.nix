{ nixpkgs, pkgs, machineModule, stateVersion, globalTimeout ? 900 }:

# End-to-end check of the detected-devices producer over the REAL deployed path: the node is the
# deployed host config, so the producer posts through the actual unix socket to the on-host
# mp-collector, which forwards to the actual receiver, and the assertions read the results back out
# of the receiver's own query API.
#
# What is faked and why. A QEMU guest's USB tree is a root hub and nothing else, has no wireless
# phy at all, and has no Bluetooth controller -- so all three collectors would find nothing and
# every assertion would be vacuous. USB gets a fixture tree; `iw` and the BlueZ pair get fakes that
# replay output captured from the real hosts. The fakes are not a shortcut: the shapes that matter
# are precisely the ones no guest has -- a port holding a device that never enumerated, an AP
# advertising SAE, a beacon that is visible and non-connectable -- and the parsers are what this
# test exists to exercise against the receiver.

let
  # A scan captured from the Pi, trimmed to the elements the parser reads. Two BSSes on one AP's
  # two bands would be indistinguishable by SSID, which is why the record is per-BSS.
  fakeIw = pkgs.writeShellScriptBin "iw" ''
    if [[ "$1" == "dev" && -z "''${2:-}" ]]; then
      # `iw dev` with no interface: the type line is what decides whether a scan is possible.
      printf 'phy#0\n\tInterface wlan0\n\t\tifindex 3\n\t\ttype managed\n'
      exit 0
    fi
    if [[ "$2" == "wlan0" && "$3" == "scan" ]]; then
      cat <<'SCAN'
    BSS 08:3f:bc:ea:39:41(on wlan0) -- associated
    	last seen: 23960.665s [boottime]
    	freq: 2437.0
    	beacon interval: 100 TUs
    	signal: -58.00 dBm
    	last seen: 0 ms ago
    	SSID: DIGI-01067405
    	DS Parameter set: channel 6
    	RSN:	 * Version: 1
    		 * Pairwise ciphers: CCMP
    		 * Authentication suites: PSK
    	HT capabilities:
    	HT operation:
    		 * STA channel width: 20 MHz
    	WPS:	 * Version: 1.0
    BSS 94:04:e3:80:42:30(on wlan0)
    	freq: 5180.0
    	signal: -72.00 dBm
    	last seen: 120 ms ago
    	SSID: Telekom-103992
    	RSN:	 * Version: 1
    		 * Pairwise ciphers: CCMP TKIP
    		 * Authentication suites: PSK SAE
    	HT capabilities:
    	VHT capabilities:
    		 * STA channel width: 80 MHz
    BSS aa:bb:cc:dd:ee:ff(on wlan0)
    	freq: 2412.0
    	signal: -91.00 dBm
    	last seen: 400 ms ago
    	SSID:
SCAN
      exit 0
    fi
    exit 1
  '';

  # btmon replays two real advertisers: the JK BMS (connectable, public, two service UUIDs) and a
  # Samsung beacon (non-connectable), plus one random-address device so both device types are
  # exercised. Includes the duplicate MGMT block that must not be double-counted.
  fakeBtmon = pkgs.writeShellScriptBin "btmon" ''
    cat <<'MON'
    > HCI Event: LE Meta Event (0x3e) plen 43                    #7 [hci0] 3.139560
          LE Advertising Report (0x02)
            Event type: Connectable undirected - ADV_IND (0x00)
            Address type: Public (0x00)
            Address: C8:47:80:29:5E:3B (OUI C8-47-80)
            Flags: 0x06
            16-bit Service UUIDs (partial): 2 entries
              Unknown (0xffe0)
              Tencent Holdings Limited. (0xfee7)
            Company: not assigned (2917)
            RSSI: -61 dBm (0xc3)
    @ MGMT Event: Device Found (0x0012) plen 35            {0x0001} [hci0] 3.210375
            LE Address: C8:47:80:29:5E:3B (OUI C8-47-80)
            RSSI: -42 dBm (0xd6)
    > HCI Event: LE Meta Event (0x3e) plen 33                    #8 [hci0] 3.309609
          LE Advertising Report (0x02)
            Event type: Non connectable undirected - ADV_NONCONN_IND (0x03)
            Address type: Public (0x00)
            Address: 00:7D:3B:FA:08:E5 (Samsung Electronics Co.,Ltd)
            Company: Samsung Electronics Co. Ltd. (117)
            RSSI: -72 dBm (0xb8)
    > HCI Event: LE Meta Event (0x3e) plen 33                    #9 [hci0] 4.009609
          LE Advertising Report (0x02)
            Event type: Connectable undirected - ADV_IND (0x00)
            Address type: Random (0x01)
            Address: 4F:1A:2B:3C:4D:5E (Resolvable)
            Name (complete): Someones Phone
            TX power: -4 dBm
            RSSI: -85 dBm (0xab)
MON
    # btmon is a stream the producer kills when the scan window closes; without this it would
    # exit immediately and the producer would race it.
    sleep 300
  '';

  # bluetoothctl only has to drive the scan and exit zero; the advertisements come from btmon.
  fakeBluetoothctl = pkgs.writeShellScriptBin "bluetoothctl" ''
    exit 0
  '';

  fakeBluez = pkgs.symlinkJoin {
    name = "fake-bluez";
    paths = [ fakeBtmon fakeBluetoothctl ];
  };
in

nixpkgs.lib.nixos.runTest {
  name = "detected-devices";
  hostPkgs = pkgs;
  inherit globalTimeout;

  nodes.ntp = { ... }: {
    networking.hostName = "ntp-server";
    networking.firewall.allowedUDPPorts = [ 123 ];
    virtualisation.memorySize = 512;

    services.chrony = {
      enable = true;
      # An island: there is no upstream to reach, and `local` is what makes chronyd offer its own
      # clock as a valid reference instead of refusing to answer until it syncs.
      servers = [ ];
      extraConfig = ''
        local stratum 10
        allow all
      '';
    };

    system.stateVersion = stateVersion;
  };

  nodes.machine = { lib, ... }: {
    imports = [ machineModule ];

    networking.hostName = "detected-devices-test";
    common.autoUpgrade.enable = lib.mkForce false;
    common.monitoring.enable = lib.mkForce false;
    common.irohSsh.enable = lib.mkForce false;
    # The producer under test is the only one this test reads, and system-metrics would add 40
    # records per batch that every assertion below would have to filter around.
    common.systemMetrics.enable = lib.mkForce false;

    # mp-collector buffers every batch until the clock is disciplined and only then forwards it
    # ("releasing the buffer"), so a node with no time source never delivers anything to the
    # receiver. Restored rather than overridden: qemu-vm.nix disables timesyncd on test nodes.
    services.timesyncd = {
      enable = lib.mkForce true;
      servers = [ "ntp-server" ];
      fallbackServers = [ ];
    };

    common.detectedDevices = {
      usb.devicesRoot = lib.mkForce "/run/fixture-usb";
      wifi.package = lib.mkForce fakeIw;
      bluetooth.package = lib.mkForce fakeBluez;
      # A guest has no Bluetooth controller, so without a fixture adapter the collector correctly
      # reports skipped_reason = "no-adapter" and emits no device rows at all.
      bluetooth.sysfsRoot = lib.mkForce "/run/fixture-bluetooth";
      # Short enough to keep the test quick; the duty-cycle values are asserted on, since they are
      # what a consumer divides the counts by.
      bluetooth.scanSeconds = lib.mkForce 2;
    };
  };

  testScript = ''
    import json

    start_all()
    machine.wait_for_unit("multi-user.target")
    ntp.wait_for_unit("multi-user.target")
    machine.wait_for_unit("mp-collector.service")
    machine.wait_for_unit("monitoring-platform.service")
    # The collector forwards nothing until it trusts the clock, so wait for that once here rather
    # than letting every retry loop below absorb the delay.
    machine.wait_until_succeeds(
        "curl -sS --fail-with-body --unix-socket /run/mp-collector/mp-collector.sock"
        " http://localhost/healthz | grep -q clock", timeout=180
    )


    def build_usb_fixture():
        # Reproduces the shapes measured on the real hosts, plus the one neither has on demand: a
        # port holding a device that never enumerated, which has a port directory and no device
        # directory at all. That is the case a device-list-only metric reports as "nothing here".
        root = "/run/fixture-usb"
        machine.succeed(
            f"mkdir -p {root}/usb3/3-0:1.0/usb3-port1 {root}/usb3/3-0:1.0/usb3-port2 "
            f"{root}/3-1/3-1:1.0/tty/ttyUSB0 {root}/3-2/3-2:1.0/3-2-port1 "
            f"{root}/drivers/ftdi_sio {root}/drivers/hub"
        )
        for name, target in [
            ("3-0:1.0", "usb3/3-0:1.0"),
            ("3-1", "3-1"),
            ("3-1:1.0", "3-1/3-1:1.0"),
            ("3-2", "3-2"),
            ("3-2:1.0", "3-2/3-2:1.0"),
        ]:
            machine.succeed(f"ln -sfn {target} {root}/{name}")

        # Root hub: reachable as `usb3` while its interface implies `3-0`. A record carrying the
        # implied name would join to no device.
        machine.succeed(
            f"echo 3 > {root}/usb3/busnum",
            f"echo 1d6b > {root}/usb3/idVendor",
            f"echo 1 > {root}/usb3/devnum",
            f"echo 480 > {root}/usb3/speed",
            f"printf ' 2.00\\n' > {root}/usb3/version",
            f"echo 2 > {root}/usb3/maxchild",
            f"echo 0mA > {root}/usb3/bMaxPower",
            f"echo 09 > {root}/usb3/3-0:1.0/bInterfaceClass",
            f"echo 00 > {root}/usb3/3-0:1.0/bInterfaceNumber",
            f"ln -sfn ../../drivers/hub {root}/usb3/3-0:1.0/driver",
        )
        # 3-1: a low-speed converter, enumerated but never configured -- exactly `can't set config`.
        machine.succeed(
            f"echo 3 > {root}/3-1/busnum",
            f"echo 0403 > {root}/3-1/idVendor",
            f"echo BG00Q7OM > {root}/3-1/serial",
            f"echo 1.5 > {root}/3-1/speed",
            f"echo 100mA > {root}/3-1/bMaxPower",
            f"echo 0 > {root}/3-1/bConfigurationValue",
            f"echo ff > {root}/3-1/3-1:1.0/bInterfaceClass",
            f"echo 00 > {root}/3-1/3-1:1.0/bInterfaceNumber",
            f"ln -sfn ../../drivers/ftdi_sio {root}/3-1/3-1:1.0/driver",
            f"echo 188:0 > {root}/3-1/3-1:1.0/tty/ttyUSB0/dev",
        )
        # 3-2: a nested hub, whose port name takes the `.`-joined form.
        machine.succeed(
            f"echo 3 > {root}/3-2/busnum",
            f"echo 09 > {root}/3-2/3-2:1.0/bInterfaceClass",
            f"echo not attached > {root}/3-2/3-2:1.0/3-2-port1/state",
        )
        machine.succeed(
            f"echo configured > {root}/usb3/3-0:1.0/usb3-port1/state",
            f"echo 0 > {root}/usb3/3-0:1.0/usb3-port1/over_current_count",
            f"echo hotplug > {root}/usb3/3-0:1.0/usb3-port1/connect_type",
            f"echo 0 > {root}/usb3/3-0:1.0/usb3-port1/disable",
            f"echo no > {root}/usb3/3-0:1.0/usb3-port1/early_stop",
            f"echo powered > {root}/usb3/3-0:1.0/usb3-port2/state",
            f"echo 3 > {root}/usb3/3-0:1.0/usb3-port2/over_current_count",
            f"echo yes > {root}/usb3/3-0:1.0/usb3-port2/early_stop",
        )


    SOCKET = "/run/monitoring-platform/monitoring-platform.sock"
    ALL = "limit=5000"


    def query(params=ALL):
        raw = machine.succeed(
            f"curl -sS --unix-socket {SOCKET} 'http://localhost/v1/measurements?{params}'"
        )
        return json.loads(raw)["measurements"]


    def collect():
        # The producer finishing is not the batch arriving: mp-collector resolves the frame,
        # applies the clock correction and forwards asynchronously, so a read straight after the
        # run races it. Wait by row count rather than sleeping.
        #
        # reset-failed first because a oneshot started back to back trips systemd's start rate
        # limit, which fails the start instead of running the unit.
        before = len(query())
        machine.succeed("systemctl reset-failed detected-devices.service")
        machine.succeed("systemctl start detected-devices.service")
        state = machine.succeed(
            "systemctl show -p Result --value detected-devices.service"
        ).strip()
        assert state == "success", f"producer run failed: {state}"
        retry(lambda _: len(query()) > before)
        return query()


    def of_type(measurements, kind):
        return [m for m in measurements if m["type"] == kind]


    def by_attr(measurements, kind, attribute, wanted):
        return [
            m for m in of_type(measurements, kind)
            if m["attributes"].get(f"record.attributes.{attribute}") == wanted
        ]


    build_usb_fixture()
    machine.succeed("mkdir -p /run/fixture-bluetooth/hci0")
    measurements = collect()

    with subtest("every measurement type reaches the receiver under its own namespace"):
        types = {m["type"] for m in measurements if m["type"].startswith("detected-devices")}
        assert types == {
            "detected-devices.usb",
            "detected-devices.usb.interface",
            "detected-devices.usb_port",
            "detected-devices.wifi_scan",
            "detected-devices.wifi_bss",
            "detected-devices.ble_scan",
            "detected-devices.ble_device.public",
            "detected-devices.ble_device.random",
        }, f"unexpected types: {sorted(types)}"

    with subtest("the producer identifies itself, not system-metrics"):
        for m in measurements:
            if m["type"].startswith("detected-devices"):
                attrs = m["attributes"]
                assert attrs["resource.attributes.service.name"] == "detected-devices", attrs
                assert attrs["scope.name"] == "detected-devices", attrs

    with subtest("a root hub is reported under the directory name that can be joined to"):
        hub = by_attr(measurements, "detected-devices.usb", "path", "usb3")
        assert len(hub) == 1, f"the root hub was not reported: {hub}"
        assert hub[0]["body"]["usb_version"] == "2.00", "the kernel's leading space reached the value"
        assert hub[0]["body"]["max_power_ma"] == 0, "the mA suffix was not stripped"
        assert not by_attr(measurements, "detected-devices.usb", "path", "3-0"), (
            "the root hub's implied path must not be reported as a device of its own"
        )
        hub_if = by_attr(measurements, "detected-devices.usb.interface", "path", "usb3")
        assert len(hub_if) == 1 and hub_if[0]["body"]["driver"] == "hub", hub_if

    with subtest("a device that enumerated but was never configured says so"):
        conv = by_attr(measurements, "detected-devices.usb", "path", "3-1")
        assert conv[0]["body"]["configuration"] == 0, conv
        assert conv[0]["body"]["speed_mbps"] == 1.5, "a whole-number field would reject low speed"
        conv_if = by_attr(measurements, "detected-devices.usb.interface", "path", "3-1")
        assert conv_if[0]["body"]["nodes"] == "ttyUSB0", conv_if
        assert conv_if[0]["body"]["driver"] == "ftdi_sio", conv_if

    with subtest("a port is reported whether or not a device enumerated on it"):
        port2 = by_attr(measurements, "detected-devices.usb_port", "port", "usb3-port2")
        assert port2[0]["body"]["state"] == "powered", port2
        assert port2[0]["body"]["early_stop"] is True, port2
        assert port2[0]["body"]["over_current_count"] == 3, port2
        nested = by_attr(measurements, "detected-devices.usb_port", "port", "3-2-port1")
        assert nested[0]["attributes"]["record.attributes.path"] == "3-2.1", nested

    with subtest("the wifi scan records that it ran, and how long it took"):
        scan = of_type(measurements, "detected-devices.wifi_scan")
        assert len(scan) == 1, scan
        body = scan[0]["body"]
        assert body["ran"] is True, body
        assert body["skipped_reason"] is None, body
        # Always a real sweep: under iwd the kernel BSS cache holds only the associated BSS.
        assert body["passive"] is False, body
        assert body["bss_count"] == 3, body
        assert body["duration_ms"] is not None, body

    with subtest("one row per BSS, and the associated one is flagged"):
        ours = by_attr(measurements, "detected-devices.wifi_bss", "bssid", "08:3f:bc:ea:39:41")
        assert ours[0]["body"]["associated"] is True, ours
        assert ours[0]["body"]["ssid"] == "DIGI-01067405", ours
        assert ours[0]["body"]["channel"] == 6, ours
        assert ours[0]["body"]["security"] == "wpa2", ours
        assert ours[0]["body"]["wps"] is True, ours

        # SAE in the auth suites is WPA3, not WPA2 -- the strongest element wins.
        other = by_attr(measurements, "detected-devices.wifi_bss", "bssid", "94:04:e3:80:42:30")
        assert other[0]["body"]["security"] == "wpa3", other
        assert other[0]["body"]["standards"] == "ht,vht", other
        assert other[0]["body"]["associated"] is False, other

        # A hidden network keeps a null ssid rather than an empty-string network name.
        hidden = by_attr(measurements, "detected-devices.wifi_bss", "bssid", "aa:bb:cc:dd:ee:ff")
        assert hidden[0]["body"]["ssid"] is None, hidden
        assert hidden[0]["body"]["security"] == "open", hidden

    with subtest("the ble scan pins its duty cycle rather than inheriting BlueZ's"):
        scan = of_type(measurements, "detected-devices.ble_scan")
        assert len(scan) == 1, scan
        body = scan[0]["body"]
        assert body["ran"] is True, body
        # BlueZ's own default is window == interval, i.e. 100%, which starves an active connection.
        assert body["scan_window_ms"] == 11 and body["scan_interval_ms"] == 1280, body
        assert body["devices_public"] == 2 and body["devices_random"] == 1, body
        assert body["devices_connectable"] == 2, body
        # Three HCI reports; the duplicate mgmt copy of the first must not be counted.
        assert body["reports_total"] == 3, body
        assert body["strongest_dbm"] == -61, body
        assert (body["near_count"], body["mid_count"], body["far_count"]) == (0, 2, 1), body

    with subtest("connectability comes from the PDU type, not from signal strength"):
        bms = by_attr(
            measurements, "detected-devices.ble_device.public", "address", "C8:47:80:29:5E:3B"
        )
        assert bms[0]["body"]["connectable"] is True, bms
        assert bms[0]["body"]["pdu_type"] == "ADV_IND", bms
        assert bms[0]["body"]["service_uuids"] == "ffe0,fee7", bms
        assert bms[0]["body"]["company_id"] == 2917, bms

        # Visible at -72 dBm and impossible to connect to: the case an RSSI-based reading of
        # "reachable" gets wrong.
        beacon = by_attr(
            measurements, "detected-devices.ble_device.public", "address", "00:7D:3B:FA:08:E5"
        )
        assert beacon[0]["body"]["connectable"] is False, beacon
        assert beacon[0]["body"]["pdu_type"] == "ADV_NONCONN_IND", beacon
        assert beacon[0]["body"]["company_id"] == 117, beacon

    with subtest("a rotating address is in the body, never a filterable dimension"):
        random_rows = of_type(measurements, "detected-devices.ble_device.random")
        assert len(random_rows) == 1, random_rows
        row = random_rows[0]
        # The whole point of the split: no address attribute exists to filter on, so following a
        # rotating address across scans is awkward by construction.
        assert not any(
            k.startswith("record.attributes.address") for k in row["attributes"]
        ), f"a random address must not be an attribute: {row['attributes']}"
        assert row["body"]["address"] == "4F:1A:2B:3C:4D:5E", row
        assert row["body"]["name"] == "Someones Phone", row
        assert row["body"]["tx_power_dbm"] == -4, row

    with subtest("a device this host cannot connect to is still recorded, and marked so"):
        # Detection is not reachability: both are recorded, and the difference is a field.
        public = of_type(measurements, "detected-devices.ble_device.public")
        assert {m["body"]["connectable"] for m in public} == {True, False}, public
  '';
}
