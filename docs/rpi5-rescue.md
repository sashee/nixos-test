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

## 4. Fresh device bootstrap (no secrets yet)

A freshly flashed card has neither the iroh secret nor the monitoring
credential, so the tunnel is inert and nothing is remotely reachable. Flash a
**bootstrap image** that opens port 22, provision over LAN, then converge to
the hardened config. The override lives only in the image build below -- the
committed host config stays closed.

1. Build the image (aarch64: build on the live Pi, or with binfmt emulation):

       nix build --impure --expr '
         ((builtins.getFlake "github:sashee/nixos-test").lib.mkRpi5 {
           modules = [ { services.openssh.openFirewall = true; } ];
         }).config.system.build.sdImage'

2. Flash it: the compressed image is `result/sd-image/nixos-image-rpi5-kernel.img.zst`;
   `zstd -d --stdout <image> | sudo dd of=/dev/sdX bs=4M status=progress`.

3. First boot: plug in ethernet, or join the `nixos-rpi5-setup` AP
   (connectivity-fallback) and enter wifi credentials in the captive portal.
   Then `ssh nixos@<lan-ip>` -- this image accepts port 22.

4. Provision:

       # deployment flake (required by auto-upgrade)
       sudo mkdir -p /etc/nixos && sudo tee /etc/nixos/flake.nix <<'FLAKE'
       {
         inputs.common.url = "github:sashee/nixos-test";
         outputs = { common, ... }: {
           nixosConfigurations.rpi5 = common.lib.mkRpi5 { };
         };
       }
       FLAKE

       # iroh tunnel identity -- SAVE the connect command this prints
       sudo install -d -m 0700 /etc/credentials/iroh-ssh
       iroh-ssh-generate-secret | sudo systemd-creds encrypt --name=iroh-secret - /etc/credentials/iroh-ssh/iroh-secret

       # monitoring report URL
       sudo install -d -m 0700 /etc/credentials/monitoring
       printf '%s' '<healthchecks-url>' | sudo systemd-creds encrypt --name=healthchecks-url - /etc/credentials/monitoring/healthchecks-url

5. Converge and verify BEFORE walking away:

       sudo nixos-rebuild switch --flake /etc/nixos#rpi5

   closes port 22 and starts the tunnel. Check that
   `sudo nft list chain inet nixos-fw input-allow` has no `dport 22` rule and
   that ssh through the saved connect command works. (Doing nothing also
   converges: the nightly auto-upgrade rebuilds from github main and reboots --
   but port 22 stays open until then.)

If a pre-staged or retired card is lost, rotate the iroh secret (regenerate
and re-encrypt on the Pi, update saved tickets).
