## Monitoring platform

* runs the monitoring platform from https://github.com/sashee/monitoring-platform, listening on a UDS

### Iroh tunnel

* a separate service provides connectivity via Iroh
* iroh-based forwarding exposes the UDS
* it requires the secret key that is loaded using an encrypted credential
* if the credential is not provided, the service is not started
* the service auto-restarts
