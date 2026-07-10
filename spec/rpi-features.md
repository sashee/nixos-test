# Features for the RPI 5

## Wifi

* uses IWD
* connects automatically to known networks

### Setup helper

* if there is no internet after 5 minutes of boot then it enters setup mode
* in setup mode:
    * automatically reboots after 10 minutes
    * starts an open Wifi network; if passwordless does not work then the password should be the same as the ssid
    * the ssid is `nixos-rpi5-setup`
    * this network is a captive portal and has a webserver
    * this webserver allows selecting a wifi network and providing a password
    * when an ssid+pw is provided, they are written to a place where iwd can find it and then reboot

## DNS-over-HTTPS

* non-DoH DNS requests are blocked by the firewall
* a known set of DoH servers are configured

## Auto upgrade

* runs daily
* updates the flake inputs and then rebuilds the system
* switch only on boot, not live
* reboot if a new generation was created

## Auto GC

* runs daily
* only the last generation is kept

## SSH

* SSH is running on port 22
* only keys are allowed, no passwords

## Monitoring

* runs every 30 minutes
* reports success:
    * backups ran
    * disk is alright
    * auto-upgrade run successfully in the last 3 days
    * auto-gc ran successfully in the last 3 days
    * number of generations is not too big
* plus a couple of infos: disk usage, last boot time, kernel version, common repo rev + last updated + url
* remote url is configured outside the store, it is an encrypted credential that is loaded by the systemd unit

## Backups

* runs daily, based on Restic
* configuration in the config + credentials encrypted in a directory outside the store that are loaded via systemd

## Dotfiles

* available to the user's path

## Iroh SSH

* SSH is listening on port 22
* firewall denies incoming connections on port 22
* iroh-based port forwarding exposes port 22, allowing ssh access via iroh
* it requires the secret key that is loaded using an encrypted credential
* if the credential is not provided, the service is not started
* the service auto-restarts
