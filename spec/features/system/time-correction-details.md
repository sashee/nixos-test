## Implementation details for the time correction

* validity check footgun
    * TLS certificate validity times are checked in two places
    * first, when the set gets a timestamp and then verifies that the received timestamp is within the validity of the certificates used to get it
    * second, when the current system clock is checked against all previously seen certificates
    * if the second group contains certificates that are missing from the first group then the service might incorrectly modify the system time
    * for example, if a certificate is served but is not needed for the connection
    * so care must be taken in the implementation to only include certs in the second set that were checked in the first step

