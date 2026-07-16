## Iroh SSH

* SSH is listening on port 22
* firewall denies incoming connections on port 22
* iroh-based port forwarding exposes port 22, allowing ssh access via iroh
* it requires the secret key that is loaded using an encrypted credential
* if the credential is not provided, the service is not started
* the service auto-restarts
* only keys are allowed, no passwords

### Failsafe

* if the iroh service does not come up for 5 minutes, port 22 is opened on the firewall

