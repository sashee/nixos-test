## Backups

* runs daily, based on Restic
* configuration in the config + credentials encrypted in a directory outside the store that are loaded via systemd
* no identifiable part of the configuration (repository URL and username) should be in the Nix config
* needs to support append-only repositories (not being able to delete old snapshots is not an error)
* repository is verified after each backup (check)

### Backends and services

* there can be several backends configured for a system
* there can be several services or directories backed up

### Hardening

* minimal permissions
* can only read what it needs to, can not write anything except its own directories
* trusts the certificates from the system ca store

### Pruning

* keep-daily 7
* keep-weekly 4
* keep-monthly 12

