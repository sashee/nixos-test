## Device detection monitoring

* depends on the [local collector](./local-collector.md) and sends the measurements to it
* collects every 15 minutes
* the metrics are in the `detected-devices` namespace, so each measurement is `detected-devices.<name>` and when there are sub measurement then `detected-devices.<name>.<sub>` (can be more
  levels)
* all fields can be missing if the value can not be collected

* resource attributes:
    * service.name: "detected-devices"
    * host.name: /proc/sys/kernel/hostname
    * boot_id: /proc/sys/kernel/random/boot_id
* scope attributes:
    * name: "detected-devices"
    * version: crate version

### metrics

#### usb

one per USB device currently attached, root hubs included

* attributes:
    * path: topology path from the sysfs dir name, e.g. "3-1" (nested: "3-1.2")
    * bus: busnum
    * vendor_id: idVendor
    * product_id: idProduct
    * serial: serial
    * manufacturer: manufacturer
    * product: product
* body:
    * devnum: devnum -- changes on every re-enumeration, so never an attribute;
      wraps at 128, so a delta between samples means "flapped", not an exact count
    * speed_mbps: speed
    * usb_version: version
    * bcd_device: bcdDevice
    * ports: maxchild (0 for non-hubs)
    * authorized: authorized
    * configuration: bConfigurationValue      (0 = enumerated but not configured)
    * configurations: bNumConfigurations
    * max_power_ma: bMaxPower
    * urbnum: urbnum                          (monotonic; delta = I/O activity)
    * runtime_status: power/runtime_status     (active | suspended)

* sub measurements:
    * interface: one per interface of the device
        * attributes:
            * path: repeated so the row is self-contained
            * interface: bInterfaceNumber
        * body:
            * class: bInterfaceClass (03 = HID, ff = vendor, 09 = hub, 08 = storage)
            * subclass: bInterfaceSubClass
            * protocol: bInterfaceProtocol (with class 03: 01 = keyboard, 02 = mouse)
            * driver: basename of the bound driver symlink (usbhid | ftdi_sio | ch341 | hub)
            * endpoints: bNumEndpoints
            * nodes: device nodes the interface owns, comma-separated, e.g. "ttyUSB0" -- a value,
              never an identifier: two converters swap nodes across re-enumeration. Empty when the
              interface exposes none. Found by looking for a `dev` file on the interface's children
              and one level below (a converter's is at `tty/ttyUSB0`), so network interfaces (no
              `dev` file) and HID nodes (deeper) are not listed

#### usb_port

one per port on every hub, whether or not a device is attached

* attributes:
    * port: sysfs port name, e.g. "usb3-port1" -- matches kernel log "usb usb3-port1: ..."
    * path: topology path a device on this port takes, e.g. "3-1" -- joins to `usb.path`,
      matches kernel log "usb 3-1: ..."; the kernel's port dir name does not match the
      device path, so it is emitted explicitly
    * bus: busnum of the parent hub
    * connect_type: connect_type (hardwired | hotplug | not used | unknown)
    * peer: peer port name, e.g. "usb4-port1" (the other speed-half of the same
      physical socket; absent for ports with no companion)
* body:
    * state: state (not attached | powered | default | configured | etc.)
    * over_current_count: over_current_count
    * disabled: disable
    * early_stop: early_stop                  (kernel gave up retrying this port)

#### wifi_scan

scans the nearby wifi networks

* attributes:
    * interface: e.g. "wlan0"
* body:
    * ran: false when skipped or refused
    * skipped_reason: null | "ap-mode" | "interface-down" | "busy". The radio cannot scan while
      running the fallback AP -- the phy allows `#{managed} <= 1, #{AP} <= 1 ... #channels <= 1` --
      and a request while the manager is mid-scan returns -EBUSY
    * passive: true when read from the kernel BSS cache without triggering a sweep. iwd does not
      populate that cache (a dump returns only the associated BSS), so on this host it is always
      false; a wpa_supplicant host can read it for free
    * duration_ms
    * bss_count: rows emitted below

#### wifi_bss

one per BSS, not per network: a dual-band AP publishes the same SSID on both bands and is two rows

* attributes:
    * bssid: e.g. "08:3f:bc:ea:39:41"
    * interface: the scanning interface
* body:
    * ssid: null for a hidden network
    * frequency_mhz: 2437
    * channel: DS Parameter set, e.g. 6
    * signal_dbm: -58.0
    * last_seen_ms: age of the cache entry when read
    * beacon_interval_tu: 100
    * associated: true for the BSS this host is joined to (`iw` marks it "-- associated")
    * security: open | wep | wpa | wpa2 | wpa3 -- the strongest of the RSN/WPA elements present
    * pairwise_ciphers: comma-separated, e.g. "CCMP"
    * auth_suites: comma-separated, e.g. "PSK"
    * wps: true when a WPS element is present and its state is Configured
    * width_mhz: from HT/VHT/HE operation, e.g. 20
    * standards: comma-separated of the capability elements present, e.g. "ht" or "ht,vht,he"
    * country: regulatory code, null when the AP advertises none -- `iw` renders a malformed one as
      unprintable, which is what the AP on this site does

#### ble_scan

one per scan
should not overlap with the wifi scan

* attributes:
    * adapter
* body:
    * ran: false when skipped or refused
    * ran: false when skipped or refused
    * skipped_reason: null | "no-adapter" | "adapter-down" | "controller-busy". The last covers a
      userspace host stack holding the controller on an HCI user channel, which makes scanning
      impossible rather than merely degraded
    * active: true for active scanning (sends SCAN_REQ)
    * scan_interval_ms / scan_window_ms: the requested duty cycle, which the collector MUST pin
      rather than inherit. BlueZ's default is window == interval == 11.25 ms, i.e. 100% -- the
      radio listens continuously and starves any active connection. ~11.25 ms per 1.28 s is ~1%
      and is the safe default
    * duration_ms
    * devices_public / devices_random: rows emitted under each type below
    * devices_connectable: how many advertised a connectable PDU
    * reports_total: advertisements received in the window
    * strongest_dbm
    * near_count / mid_count / far_count: devices above -60, -60..-80, below -80 dBm. Fixed-width
      population signal, so cadence or per-scan row caps can change without losing "how busy is it"

#### ble_device.public

one per device advertising a permanent, OUI-assigned address

* attributes:
    * address: e.g. "C8:47:80:29:5E:3B" -- filterable via attr.address, so a device with a stable
      identity can be followed across scans
* body:
    * connectable: from the advertising PDU type. ADV_IND and ADV_DIRECT_IND yes, ADV_NONCONN_IND
      and ADV_SCAN_IND no. The field the feature name promises, and one BlueZ's D-Bus API does not
      expose at all -- it is only available from the HCI/mgmt view
    * pdu_type: verbatim, e.g. "ADV_IND" | "ADV_NONCONN_IND"
    * rssi_last / rssi_min / rssi_max: a window yields many reports per device and a single value is
      survivor-biased -- only the advertisements that arrived are measured
    * report_count
    * name: Complete or Shortened Local Name, null when not advertised
    * tx_power_dbm: from the TX Power AD element, null when absent. Without it path loss cannot be
      computed, so RSSI alone says nothing about distance
    * company_id: manufacturer-data company identifier, e.g. 117 (Samsung), 2917 (unassigned)
    * service_uuids: comma-separated 16-bit UUIDs, e.g. "ffe0,fee7"
    * flags: the Flags AD element, null when the advertiser sends none

#### ble_device.random

one per device advertising a random address.

* attributes: none -- resolvable private addresses rotate roughly every 15 minutes, so an address
  dimension would mint a series per rotation and invite tracking strangers
* body:
    * address: recorded so a row is self-describing and correlatable within one scan, but not a
      dimension. The API filters on attr.<key> only, so following it across scans is awkward by
      construction -- a speed bump, not a guarantee: a consumer with query access can still
      correlate body fields
    * connectable, pdu_type, rssi_last, rssi_min, rssi_max, report_count, name, tx_power_dbm,
      company_id, service_uuids, flags -- identical to ble_device.public

