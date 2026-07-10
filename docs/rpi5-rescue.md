# rpi5: ssh rescue runbook (port 22 is closed)

SSH on the Pi is reachable only through the iroh tunnel (`modules/iroh-ssh.nix`):
sshd runs, but the default-deny firewall accepts no inbound port 22; the tunnel
delivers connections to 127.0.0.1:22 from the Pi's outbound iroh endpoint. If
the tunnel breaks, use one of the paths below.

There is no generation to roll back to on this host: GC runs with
`--delete-old`, so only the current system generation exists in the store.

## 1. Pi still online: push a fix to github main

The nightly auto-upgrade (00:00-02:00 start, reboot on change) rebuilds
`/etc/nixos#rpi5` from github main. Push a commit that fixes iroh -- or
temporarily sets `services.openssh.openFirewall = true;` in
`hosts/rpi5/configuration.nix` -- and wait for the upgrade. No ssh needed:
github main is the out-of-band management channel.

## 2. SD card: break-glass firewall unit

Power off, mount the card's second (ext4) partition on another machine. NixOS
leaves foreign files in `/etc/systemd/system` alone and systemd merges them
with the store-provided units, so a drop-in unit can open the port at boot:

    mkdir -p <root>/etc/systemd/system/multi-user.target.wants
    cat > <root>/etc/systemd/system/rescue-open-ssh.service <<'UNIT'
    [Unit]
    Description=Break-glass: open port 22
    After=firewall.service

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/run/current-system/sw/bin/nft add rule inet nixos-fw input-allow tcp dport 22 accept

    [Install]
    WantedBy=multi-user.target
    UNIT
    ln -s ../rescue-open-ssh.service \
      <root>/etc/systemd/system/multi-user.target.wants/rescue-open-ssh.service

Boot the Pi, `ssh nixos@<lan-ip>`, fix the real problem, then remove both
files and reboot (any firewall restart also drops the rule).

The firewall is nftables (table `inet nixos-fw`, chain `input-allow`); the
iptables compatibility shim is not installed on this host.

The iroh secret cannot be re-provisioned from another machine:
`systemd-creds encrypt` binds to the Pi's host key
(`/var/lib/systemd/credential.secret`). Open the firewall first, then
regenerate on the booted Pi if needed.

## 3. Console

HDMI + keyboard: log in as `nixos` (passwordless sudo) and run the
`nft add rule ...` line above directly. For an unbootable system, edit
`cmdline.txt` on the FAT boot partition (`systemd.unit=rescue.target`, or
`init=` pointing at a store path's init).
