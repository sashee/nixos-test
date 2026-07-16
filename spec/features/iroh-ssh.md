## Iroh SSH

* SSH is listening on port 22
* firewall denies incoming connections on port 22
* iroh-based port forwarding exposes port 22, allowing ssh access via iroh
* it requires the secret key that is loaded using an encrypted credential
* if the credential is not provided, the service is not started
* the service auto-restarts
* only keys are allowed, no passwords

### Failsafe

* there is a failsafe monitoring that connects to the iroh endpoint periodically and verifies that it is working
* if it can't connect for 5 minutes, it opens port 22 on the firewall
* if it recovers, it closes port 22

