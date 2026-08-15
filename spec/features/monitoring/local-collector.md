## Local collector

* the local collector from https://github.com/sashee/monitoring-platform is running and listening on a UDS
* API key is configured outside the store, it is an encrypted credential that is loaded by the systemd unit

### Iroh tunnel to the monitoring platform

* a separate service provides connectivity via Iroh
* creates a UDS that forwards to the monitoring-platform's iroh endpoint
* it requires the endpoint ID as a systemd encrypted credential
* if the credential is not provided, the service is not started
* the service auto-restarts
* the local collector uses only this UDS, never the monitoring-platform's direct UDS (needs to support that it's on a different machine)
