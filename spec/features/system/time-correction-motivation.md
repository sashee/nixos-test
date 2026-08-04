## Motivation for the time correction

* DoH can break a device (auto-upgrade and iroh failing)
    * no RTC => device does not know the current time at boot
    * systemd epoch => not 1970, but can be months old (or older for an unupgraded device)
    * so the system time at boot can be very wrong
    * time sync needs DNS (hostname => IP)
    * DoH uses TLS
    * TLS has certificate lifetimes
    * if the system clock is bad, TLS validation will fail and the time can not be corrected

* partial mitigations
    * systemd epoch time => at least not 1970, but can be outside the current certificate times
    * record in a file a known-good time => helps when the device is mostly on, won't help after a long shutdown

* Time correction service
    * it runs periodically and corrects the system clock if needed so that a normal timesync can take over
    * can use the same machinery: DoH and NTS, but in a way that does not depend on the system clock
        * and if the system clock is already within the TLS certificate timelines then it doesn't need to do anything
    * its runs should not be skipped and they should be monitored so an error is caught while the system is still functional

* security considerations
    * TLS certification validity needs to be disabled for TLS and NTS but can be retroactively checked => servers can't lie too much
    * can use multiple DoH and NTS servers and check if they agree => a rogue pair can't set the clock to a wrong time

* why is it not a problem on a default config?
    * laptops have RTC clock => they know the time on boot
    * systemd-timesyncd uses NTP => not encrypted, does not depend on the system time
