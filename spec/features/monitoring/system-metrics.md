## Monitoring system metrics

* depends on the [local collector](./local-collector.md) and sends the measurements to it
* collects every 15 minutes and 5 minutes after boot
* the metrics are in the `system` namespace, so each measurement is `system.<name>` and when there are sub measurement then `system.<name>.<sub>` (can be more
  levels)
* all fields can be missing if the value can not be collected

* resource attributes:
    * service.name: "system-metrics"
    * host.name: /proc/sys/kernel/hostname
    * boot_id: /proc/sys/kernel/random/boot_id
* scope attributes:
    * name: "system-metrics"
    * version: crate version

### metrics

#### cpu

* body:
    * load1: /proc/loadavg
    * load5: /proc/loadavg
    * load15: /proc/loadavg
    * utilization_percent: /proc/stat over 1 sec
    * cores: /proc/stat cpuN

#### memory

* body:
    * total_bytes: MemTotal
    * free_bytes: MemFree
    * available_bytes: MemAvailable
    * swap_total_bytes: SwapTotal
    * swap_free_bytes: SwapFree
    * zramswap_memory_bytes: sum over /sys/block/zram*/mm_stat mem_used_total
    * zramswap_total_bytes: sum over /sys/block/zram*/disksize
    * oom_kill: /proc/vmstat

#### filesystem

filtered for only the useful drives

* attributes:
    * mountpoint
    * device
    * fstype
* body:
    * total_bytes: f_blocks * f_frsize
    * free_bytes: f_bfree * f_frsize
    * available_bytes: f_bavail * f_frsize

#### drive

for every SMART-capable drives

* attributes:
    * sn: drive serial number
    * model
    * kind: nvme | sata
* body:
    * passed
    * power_on_hours
* sub measurements:
    * nvme: if the drive is nvme
        * attributes:
            * sn: drive serial number
            * model
        * body:
            * percentage_used
            * available_spare
            * media_errors
            * unsafe_shutdowns
            * critical_warning
    * sata: if the drive is sata
        * attributes:
            * sn: drive serial number
            * model
        * body:
            * reallocated_sector_ct
            * reported_uncorrect
            * command_timeout
            * current_pending_sector
            * offline_uncorrectable
            * power_cycle_count
            * udma_crc_error_count
            * wear_leveling_count
            * total_lbas_written
            * failing_now
            * failed_past

#### generation

* body:
    * current: /nix/var/nix/profiles/system -> system-N-link
    * current_system: /run/current-system
    * booted_system: /run/booted-system
    * count: number of system-*-link

#### host

* body:
    * uptime_seconds: /proc/uptime
    * kernel_release: /proc/sys/kernel/osrelease
    * nixos_version: /run/current-system/nixos-version
    * common_commit_id: flake.lock
    * common_last_modified: flake.lock
    * common_ref : flake.lock

#### iroh_failsafe

* body:
    * port_22_open
    * last_engaged_seconds_ago: /var/lib/iroh-ssh-failsafe/last-engaged

#### sensor

for each /sys/class/hwmon/hwmon*/<prefix><num>_input and <prefix><num>_<threshold>_alarm and <prefix><num>_alarm

* attributes:
    * chip: name
    * sensor: <prefix><num>
    * kind: <prefix> (input) alarm (alarm)
    * label: <prefix><num>_label
    * threshold (only for alarm with threshold): <threshold>
    * device: device, resolve the symlink
* body (one value {[name]: value}):
    * name: prefix: temp=>milli_celsius, fan=>rpm, in=>milli_volts, curr=>milli_amps, power=>micro_watts, energy=>micro_joules, humidity=>milli_percent, alarm=>triggered(bool)
    * value: <prefix><num>_input or <prefix><num>_<threshold>_alarm or <prefix><num>_alarm

#### unit

for every failing systemd unit plus [chronyd, dnscrypt-proxy, iroh-ssh, iroh-ssh-failsafe, connectivity-fallback-*, connectivity-watchdog,
  time-correction, restic-*, nix-gc, nixos-upgrade, mp-collector, system-metrics]

* attributes:
    * unit: name
* body:
    * active_state
    * sub_state
    * result
    * n_restarts
    * active_enter_seconds_ago
    * last_success_seconds_ago: for services that write a -last-success marker

#### timer

for every systemd timer in [nixos-upgrade, nix-gc, connectivity-watchdog, time-correction, fstrim]

* attributes:
    * unit: name
* body:
    * next_elapse_seconds_until

#### journal

journal for every systemd unit that logged >= warning since (now - interval)

* attributes:
    * unit: unit name
* body:
    * warning: number of 4 priority messages in the last period
    * err: number of 3 priority messages in the last period
    * crit: number of <=2 priority messages in the last period
    * interval: the interval of the monitoring runs

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
            * node: device node the interface currently owns, e.g. "ttyUSB0" -- a value, never an identifier: two converters swap nodes across re-enumeration

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
