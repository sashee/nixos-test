## Backups

* runs daily, based on Restic
* configuration in the config + credentials encrypted in a directory outside the store that are loaded via systemd
* no identifiable part of the configuration (repository URL and username) should be in the Nix config
* needs to support append-only repositories

