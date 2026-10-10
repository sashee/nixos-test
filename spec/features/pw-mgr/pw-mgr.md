## Pw-mgr

* runs the pw-mgr from https://github.com/sashee/pw-mgr, listening on a UDS

### Iroh tunnel

* a separate service provides connectivity via Iroh
* iroh-based forwarding exposes the UDS
* it requires the secret key that is loaded using an encrypted credential
* if the credential is not provided, the service is not started
* the service auto-restarts

### Backup

* PROVISIONAL: currently there is no restic configured, so this part is skipped

* uses the [Restic-based backup system](../backups.md)
* stops the service before the backup and starts it after


