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

The `nixos` password is locked and root has none, so getty login with HDMI +
keyboard is not possible. Console access goes through `cmdline.txt` on the FAT
boot partition instead (pull the card, or edit it from section 2's mount):

- `systemd.debug_shell=1` -- root shell on tty9 (Ctrl+Alt+F9) from early boot;
  run the `nft add rule ...` line above there. Remove the parameter afterwards:
  the shell is unauthenticated.
- `systemd.unit=rescue.target systemd.setenv=SYSTEMD_SULOGIN_FORCE=1` -- the
  sulogin force flag is required because root's password is locked.
- Unbootable system: `init=` pointing at a store path's init, as before.

For planned console work, set a temporary password over ssh first
(`sudo passwd nixos`), and lock it again afterwards
(`sudo usermod -p '!' nixos`).

## 4. Fresh device bootstrap (no secrets yet)

A freshly flashed card has neither the iroh secret nor the monitoring
credential, so the tunnel is inert and nothing is remotely reachable. Flash a
**bootstrap image** that opens port 22, provision over LAN, then converge to
the hardened config. The override lives only in the image build below -- the
committed host config stays closed.

1. Build the image (aarch64: build on the live Pi, or with binfmt emulation):

       nix build --impure --expr '
         ((builtins.getFlake "github:sashee/nixos-test").lib.hosts.rpi5 {
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
           nixosConfigurations.rpi5 = common.lib.hosts.rpi5 { };
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

   closes port 22 and starts the tunnel. Starting the tunnel is also what
   publishes the connect ticket, so `sudo cat /run/iroh-ssh/ticket` should now
   print exactly the ticket saved in step 4 -- that match is the cheapest proof
   the credential decrypts and the identity is the expected one. Check that
   `sudo nft list chain inet nixos-fw input-allow` has no `dport 22` rule and
   that ssh through the saved connect command works. (Doing nothing also
   converges: the nightly auto-upgrade rebuilds from github main and reboots --
   but port 22 stays open until then.)

## Rotating the iroh secret

If a pre-staged or retired card is lost, the iroh identity on it is compromised
and must be replaced. Do it as a config change, not an edit in place -- so a bad
new credential is a revert away instead of a lockout:

1. Stage the new credential under a **new** directory on the Pi, leaving the old
   one untouched. SAVE the connect command this prints:

       sudo install -d -m 0700 /etc/credentials/iroh-ssh-2
       iroh-ssh-generate-secret | sudo systemd-creds encrypt --name=iroh-secret - /etc/credentials/iroh-ssh-2/iroh-secret

2. Point the host at it in the common repo (`common.irohSsh.credentialDirectory
   = "/etc/credentials/iroh-ssh-2"`) and merge to main. The nightly auto-upgrade
   picks it up; `sudo nixos-rebuild switch --flake /etc/nixos#rpi5` does it now.
   Either way the unit definition changed, so the listener restarts and
   republishes the ticket from the new credential.

3. Verify: `sudo cat /run/iroh-ssh/ticket` matches the ticket saved in step 1,
   and ssh through the new connect command works.

4. If it does not, revert the commit. The old blob is still on disk and its
   ticket still works, so the Pi comes back to a reachable identity on the next
   auto-upgrade -- and until it does, the failsafe opens port 22 on the LAN 15
   minutes after the tunnel stops answering. Delete the retired directory only
   after step 3 passes.

Writing a new blob without changing `credentialDirectory` does nothing on its
own: no unit watches the secret, and the published ticket keeps naming the
identity the running listener actually answers on. So a half-finished rotation
cannot strand the failsafe against a healthy tunnel.

## Recovering a lost ticket

`sudo cat /run/iroh-ssh/ticket` is the normal way to read it, but that file only
exists once the listener has started this boot -- so it is missing in exactly the
situation where the ticket matters most: the tunnel is broken, you are in over
the failsafe's port-22 opening, and you want to know which identity the Pi is
supposed to be. Re-derive it straight from the credential instead:

    sudo systemd-creds decrypt --name=iroh-secret \
      /etc/credentials/iroh-ssh/iroh-secret - | iroh-ssh-ticket /dev/stdin

The result is the same ticket -- it is a pure function of the key -- and the
plaintext stays in the pipe. Note `iroh-ssh-ticket` reads *plaintext* hex, so
pointing it straight at the encrypted blob fails; the `systemd-creds decrypt` is
not optional.
