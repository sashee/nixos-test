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
    * it makes a query to 2 random providers on the DoH list
        * use all IPs configured
        * must disable the cache
    * for each server
        * it bypasses the time checks for the received TLS certificates
        * inspects the Date header of the HTTP response
        * retroactively verifies the certificates and errors if they are not valid for the received time
    * compares all the received times
    * if they agree (checked via adjtimex):
        * checks if the system time is already set correctly
        * if not, set the system time to the received timestamp
