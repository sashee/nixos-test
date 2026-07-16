## Monitoring

* reports success:
    * backups ran
    * disk is alright
    * auto-upgrade run successfully in the last 14 days
    * auto-gc ran successfully in the last 14 days
    * number of generations is not too big
    * iroh-ssh is working and port 22 is closed
* plus a couple of infos: disk usage, last boot time, kernel version, common repo rev + last updated + url
* remote url is configured outside the store, it is an encrypted credential that is loaded by the systemd unit
* uses the healthchecks API

