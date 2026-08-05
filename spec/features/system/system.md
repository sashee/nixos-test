## System

* zram swap enabled
* everything should work in IPv6-only networks and IPv4-only networks as well
* vm.dirty_bytes = 268435456
* vm.dirty_background_bytes = 67108864

### Time synchronization

* time synchronization is using chrony
    * uses NTS with a predetermined pool of servers (only hostnames)
    * must use multiple servers to detect incorrect servers
    * must be able to persist NTS cookies between reboots
    * must write the last known good time regularly and bump the time forward to this persisted value on boot

* time correction service
    * [motivation](./time-correction-motivation.md)
    * [implementation details](./time-correction-details.md)
    * a separate service runs every hour and after boot
    * it chooses 2 distinct sets of providers, where each set contains a provider for DoH and a provider for NTS
    * for each set
        * resolve the IP address of the NTS using the DoH (follow redirects if needed)
        * it bypasses the time checks for the received TLS certificates
        * get the NTS session tokens, also bypassing time checks for the certificates
        * get the authenticated time from the NTP
        * check the received timestamp
            * if it's before a known floor (nixpkgs.lastModified) => error
            * retroactively verify all the seen TLS certificates
        * any error fails the service run
    * if the times received do not agree within tolerance => error
    * if the current system time is within the validity times of all TLS certificates used for the verification => finish with success
    * otherwise => sets the system time to the received timestamp
