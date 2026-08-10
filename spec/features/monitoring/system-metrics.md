## Monitoring system metrics

* depends on the [local collector](./local-collector.md) and sends the measurements to it
* collects every 15 minutes and 5 minutes after boot
* the metrics are in the `system` namespace, so each measurement is `system.<name>`
* collects these metrics:
    * cpu
        * load1: /proc/loadavg
        * load5: /proc/loadavg
        * load15: /proc/loadavg
        * utilization_percent: /proc/stat over 1 sec
        * cores: /proc/stat cpuN
    * memory
        * total_bytes: MemTotal
        * free_bytes: MemFree
        * available_bytes: MemAvailable
        * swap_total_bytes: SwapTotal
        * swap_free_bytes: SwapFree
        * zramswap_memory_bytes: sum over /sys/block/zram*/mm_stat mem_used_total
        * zramswap_total_bytes: sum over /sys/block/zram*/disksize
        * oom_kill: /proc/vmstat
    * filesystem: filtered for only the useful drives
        * mountpoint
        * device
        * fstype
        * total_bytes: f_blocks * f_frsize
        * free_bytes: f_bfree
        * available_bytes: f_bavail
    * drive: for every SMART-capable drives
        * attributes:
            * sn: drive serial number
            * model
        * body:
            * passed
            * percentage_used
            * available_spare
            * media_errors
            * unsafe_shutdowns
            * power_on_hours
            * critical_warning
    * generation
        * current (optional): /nix/var/nix/profiles/system -> system-N-link
        * current_system: /run/current-system
        * booted_system: /run/booted-system
        * count: number of system-*-link
    * host
        * uptime_seconds: /proc/uptime
        * kernel_release: /proc/sys/kernel/osrelease
        * nixos_version: /run/current-system/nixos-version
        * common_commit_id: flake.lock
        * common_last_modified: flake.lock
        * common_ref (optional): flake.lock
    * iroh_failsafe:
        * port_22_open
        * last_engaged_seconds_ago (optional): /var/lib/iroh-ssh-failsafe/last-engaged
    * sensor: for each /sys/class/hwmon/hwmon*/<prefix><num>_input and <prefix><num>_<threshold>_alarm and <prefix><num>_alarm
        * attributes:
            * chip: name
            * sensor: <prefix><num>
            * kind: <prefix> (input) alarm (alarm)
            * label (optional): <prefix><num>_label
            * threshold (only for alarm with threshold): <threshold>
            * device: device, resolve the symlink
        * body (one value {[name]: value}):
            * name: prefix: temp=>milli_celsius, fan=>rpm, in=>milli_volts, curr=>milli_amps, power=>micro_watts, energy=>micro_joules, humidity=>milli_percent, alarm=>triggered(bool)
            * value: <prefix><num>_input or <prefix><num>_<threshold>_alarm or <prefix><num>_alarm
    * unit: for every failing systemd unit plus [chronyd, dnscrypt-proxy, iroh-ssh, iroh-ssh-failsafe, connectivity-fallback-*, connectivity-watchdog,
      time-correction, restic-*, nix-gc, nixos-upgrade, mp-collector, system-metrics]
        * attributes:
            * unit: name
        * body:
            * active_state
            * sub_state
            * result
            * n_restarts
            * active_enter_seconds_ago (optional)
            * last_success_seconds_ago (optional): for services that write a -last-success marker
    * timer: for every systemd timer in [nixos-upgrade, nix-gc, connectivity-watchdog, time-correction, fstrim]
        * attributes:
            * unit: name
        * body:
            * next_elapse_seconds_until (optional)
    * journal for every systemd unit that logged >= warning since last run
        * attributes:
            * unit: unit name
        * body:
            * err: number of errors since last run
            * warning: number of warnings since last run
            * crit: number of <=2 priority messages since last run
* resource attributes:
    * service.name: "system-metrics"
    * host.name: /proc/sys/kernel/hostname
    * boot_id: /proc/sys/kernel/random/boot_id
* scope attributes:
    * name: "system-metrics"
    * version: crate version
