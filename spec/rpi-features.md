# Features for the RPI 5

## System

* [./features/system.md]
* DWARF/BTF disabled in the kernel due to disk space running out when compiling otherwise

## Wifi

* [./features/wifi.md]
* uses IWD

### Setup helper

* if there is no internet after 5 minutes of boot then it enters setup mode
* in setup mode:
    * automatically reboots after 10 minutes
    * starts a Wifi network where the password is the same as the ssid
    * the ssid is `nixos-rpi5-setup`
    * this network is a captive portal and has a webserver
    * opens the ports on the firewall that is needed for its operations
    * this webserver allows selecting a wifi network and providing a password
    * when an ssid+pw is provided, they are written to a place where iwd can find it and then reboot

## DNS-over-HTTPS

* [./features/doh.md]
* captive portal handling is not needed

## Auto upgrade

* [./features/auto-upgrade.md]
* reboot if a new generation was created

## Auto GC

* [./features/gc.md]
* runs twice daily
* only the last generation is kept

## Monitoring

* [./features/monitoring.md]
* runs every 30 minutes

## Backups

* [./features/backups.md]

## Dotfiles

* [./features/dotfiles.md]

## Iroh SSH

* [./features/iroh-ssh.md]

## Firewall

* [./features/firewall.md]
