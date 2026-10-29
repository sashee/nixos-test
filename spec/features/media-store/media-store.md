## Media-store

* runs the media-store from https://github.com/sashee/media-store, listening on a UDS
* the free space guard is 2GiB
* an S3 backend is configured as "s3"
* offloadable blobs are stored in s3 only

### Iroh tunnel

* a separate service provides connectivity via Iroh
* iroh-based forwarding exposes the UDS
* it requires the secret key that is loaded using an encrypted credential
* if the credential is not provided, the service is not started
* the service auto-restarts

### Backup

* uses the [Restic-based backup system](../backups.md)
* stops the service before the backup and starts it after

