# Features for the RPI 5

## System

* [](./features/system/system.md)
* DWARF/BTF disabled in the kernel due to disk space running out when compiling otherwise
* vm.dirty_bytes = 67108864
* vm.dirty_background_bytes = 16777216
* bluetooth enabled
* journal max size = 256M

## Wifi

* [](./features/wifi.md)
* uses IWD

### Setup helper

* if there is no wifi connection after 5 minutes of boot then it enters setup mode
* in setup mode:
    * automatically reboots after 10 minutes
    * starts a Wifi network where the password is the same as the ssid
    * the ssid is `nixos-rpi5-setup`
    * this network is a captive portal and has a webserver
    * opens the ports on the firewall that is needed for its operations
    * this webserver allows selecting a wifi network and providing a password
    * when an ssid+pw is provided, they are written to a place where iwd can find it and then reboot

## DNS-over-HTTPS

* [](./features/doh.md)
* captive portal handling is not needed

## Auto upgrade

* [](./features/auto-upgrade.md)
* reboot if a new generation was created

## Auto GC

* [](./features/gc.md)
* runs twice daily
* only the last generation is kept

## Monitoring

* [](./features/monitoring.md)
* runs every 30 minutes

### Monitoring-platform monitoring

* [system metrics](./features/monitoring/system-metrics.md)
* [detected devices](./features/monitoring/detected-devices.md)

### Inverter monitoring

* [](./features/inverter-monitoring/inverter-monitoring.md)

### BMS monitoring

* [](./features/bms-monitoring/bms-monitoring.md)

## Monitoring platform

* [monitoring platform](./features/monitoring-platform/monitoring-platform.md)

## Thingspeak solar reporting

* a timer that fires every minute
* reads these via systemd:
    * an API key for the monitoring platform
    * a write API key for thingspeak
    * the iroh endpoint ticket
* if the clock is not synchronized, exit early
* the data interval: the end is the current time truncated to the interval, the start is end minus the interval
* it reads the last value in the data interval for these measurements from the monitoring platform (using the API key via its API, via iroh):
    * bms.status.soc_percent
    * bms.status.pack_power_watts
    * bms.status.temperature_1_celsius
    * bms.status.pack_voltage_volts
    * inverter.status.pv1_charging_power_watts
    * inverter.status.pv2_charging_power_watts
    * inverter.status.output_active_power_watts
    * inverter.status.battery_voltage_volts
* if there is at least one value:
    * make a POST request to https://api.thingspeak.com/update?api_key=<thingspeak key>&created_at=<timestamp>&field<N>=<val>
        * where:
            * <N> is the index of the measurement (1-based, the line it is specified in this document)
            * <val> is the value
            * <timestamp> is the end of the data interval in ISO8601 format in seconds with Z
            * and <thingspeak_key> is the thingspeak write API key
        * each measurement that has a value are added as fields to the query parameters
        * a 2XX status code where the body is not "0" is a success

## Auto-reboot

* every 10 minutes it tries to resolve a DNS address
* if it hasn't succeeded in 3 hours then reboot

## Backups

* [](./features/backups.md)

## Dotfiles

* [](./features/dotfiles.md)

## Iroh SSH

* [](./features/iroh-ssh.md)

## Firewall

* [](./features/firewall.md)
