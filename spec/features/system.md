## System

* zram swap enabled
* vm.dirty_bytes = 268435456
* vm.dirty_background_bytes = 67108864

### Time synchronization

* time synchronization is using chrony
    * uses NTS with a predetermined pool of servers (only hostnames)
    * must use multiple servers to detect incorrect servers
    * must be able to persist NTS cookies between reboots

* initial correction of time
    * a separate service starts on boot
    * and gets restarted until it succeeds
    * it chooses 2 distinct sets of providers, one from the DoH list, one from the NTS
    * for each set
        * resolve the IP address of the NTS using the DoH
        * it bypasses the time checks for the received TLS certificates
        * get the NTS session tokens, also bypassing time checks for the certificates
        * get the authenticated time from the NTP
        * retroactively verifies the certificates and errors if they are not valid for the received time
    * compares the received times from all of the sets and verify that they are after a known floor (nixpkgs.lastModified)
    * if they agree within tolerance:
        * check if the system time needs synchronization
            * if the system time is already synchronized (checked via adjtimex) => no
            * if the current system time is within the validity times of all TLS certificates => no
        * if the system time needs synchronization
            * set the system time to the received timestamp
        * wait for up to an hour and if the system time does not get synchronized => reboot
    * must work on IPv4-only and IPv6-only networks
