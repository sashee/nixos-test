# Features for the host anya-feher-laptop

## System

* [./features/system.md]
* 2 users
    * anya: no sudo, has password, auto-logged in, can manage wifi
    * sashee: sudo, can only ssh in (key only, public key provisioned in config), no password or console login
* graphical
* never suspend
* lid close or inactivity locks
* system and keyboard language is Hungarian
* LUKS with boot password to unlock the encrypted main drive
* bluetooth disabled

## Wifi

* [./features/wifi.md]
* uses NetworkManager

## DNS-over-HTTPS

* [./features/doh.md]

## Auto upgrade

* [./features/auto-upgrade.md]
* do not reboot automatically, takes effect on next manual reboot

## Auto GC

* [./features/gc.md]
* runs daily
* generations are kept for 14 days

## Monitoring

* [./features/monitoring.md]
* runs daily
* tolerates being off for up to 14 days

## Backups

* [./features/backups.md]

## Dotfiles

* [./features/dotfiles.md]

## Iroh SSH

* [./features/iroh-ssh.md]

## Firewall

* [./features/firewall.md]
