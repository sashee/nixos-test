# Plasma Firefox NixOS Module

This flake exports one composed NixOS desktop module and a QEMU VM/check that
exercise that same common configuration.

## Laptop Import

Use this flake as the source of `nixpkgs` so the laptop and common config do not
evaluate against competing nixpkgs revisions:

```nix
{
  inputs = {
    common.url = "github:sashee/nixos-test";
    nixpkgs.follows = "common/nixpkgs";
  };

  outputs = { nixpkgs, common, ... }: {
    nixosConfigurations.laptop = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        common.nixosModules.common-desktop
        ./configuration.nix
      ];
    };
  };
}
```

`common.nixosModules.common-desktop` is the public laptop module. It composes
these internal modules:

```text
modules/nix-settings.nix
modules/laptop-base.nix
modules/audio.nix
modules/firewall.nix
modules/doh.nix
modules/restic.nix
modules/auto-upgrade.nix
modules/monitoring.nix
modules/iroh-ssh.nix
modules/fonts.nix
modules/development-base.nix
modules/nix-utils.nix
modules/locale.nix
modules/plasma-firefox.nix
```

Host-specific users, hostnames, disks, bootloaders, passwords, and hardware
quirks should stay in the laptop config.

`modules/auto-upgrade.nix` enables automatic laptop updates by default as part
of `common-desktop`. Each host config must point it at the local flake output
that should be rebuilt:

```nix
{
  common.autoUpgrade = {
    flake = "/etc/nixos#my-laptop";
  };
}
```

The module runs daily with `system.autoUpgrade.operation = "boot"`, so the timer
builds the new generation and makes it the next boot target without switching
the running system. The new system is activated after reboot.

For laptop-local flakes, the timer runs `nix flake update common --flake
/etc/nixos --commit-lock-file` before rebuilding. This keeps the exact central
`github:sashee/nixos-test` revision recorded in the laptop's local
`/etc/nixos/flake.lock`. The root user must be able to commit in that
repository; if `/etc/nixos` is not owned by root, configure Git's
`safe.directory` for it. Disable the timer on non-laptop systems with:

Laptop flakes must name this repository input `common`:

```nix
inputs.common.url = "github:sashee/nixos-test";
```

Disable the timer on non-laptop systems with:

```nix
common.autoUpgrade.enable = false;
```

`.github/workflows/update-flake.yml` updates `flake.lock` daily, builds
`.#qemu-plasma-result`, and commits the lock file only when the build succeeds.
Hosts that point a local input at this repository can advance to those validated
commits when their local upgrade timer updates `/etc/nixos/flake.lock`.

VM-only users, autologin, and test tools are internal to this flake and are only
used by the QEMU VM/tests.

## Installing on a laptop

`common-desktop` already provides the parts that are the same on every machine, so
a host config only needs the hardware-specific pieces.

Provided by `common-desktop` (do not repeat in the host config):

```text
Plasma 6 + Firefox, SDDM, hardware graphics
NetworkManager, Bluetooth, DNS over HTTPS, nftables firewall
PipeWire audio, fonts, CLI/dev tools, direnv
redistributable firmware, CPU microcode (Intel + AMD), zram swap
flakes/nix settings + GC, auto-upgrade, monitoring, restic scaffolding
SSH over iroh tunnel for IP-less remote access
```

You must add per host:

```text
hardware-configuration.nix (generated)
bootloader, networking.hostName, time.timeZone
users + passwords
disk encryption (LUKS), on-disk swap (+ resume for hibernation)
common.autoUpgrade.flake
common.monitoring.report.credentialDirectory
common.irohSsh.credentialDirectory
```

`common.autoUpgrade`, `common.monitoring`, and `common.irohSsh` are **enabled by default**, and
each fails evaluation if its required argument is missing — `common.autoUpgrade.flake` for upgrades,
`common.monitoring.report.credentialDirectory` for monitoring (when reporting is on), and
`common.irohSsh.credentialDirectory` for the SSH tunnel. This is deliberate: a laptop cannot
silently ship with upgrades, monitoring, or remote access unconfigured. Opt a host out with
`common.autoUpgrade.enable = false` / `common.monitoring.enable = false` /
`common.irohSsh.enable = false`, or disable just the monitoring ping with
`common.monitoring.report.enable = false`.

### 1. Host flake

Name this repository input `common` and follow its `nixpkgs` so the host and
common config evaluate against one nixpkgs revision:

```nix
{
  inputs = {
    common.url = "github:sashee/nixos-test";
    nixpkgs.follows = "common/nixpkgs";
  };

  outputs = { nixpkgs, common, ... }: {
    nixosConfigurations.laptop = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        common.nixosModules.common-desktop
        ./configuration.nix
      ];
    };
  };
}
```

### 2. Host `configuration.nix`

```nix
{ ... }: {
  imports = [ ./hardware-configuration.nix ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "my-laptop";
  time.timeZone = "Europe/Budapest";
  common.locale.default = "en_US.UTF-8";       # override per host if needed

  users.users.sashee = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    hashedPassword = "...";                     # generate with: mkpasswd -m sha-512
  };

  # Point auto-upgrade at this host's flake output (see the auto-upgrade section).
  common.autoUpgrade.flake = "/etc/nixos#laptop";

  # Per-machine on-disk swap. Merges with the base zram; zram keeps the higher
  # priority, so disk swap is only used as overflow.
  swapDevices = [ { device = "/var/lib/swapfile"; size = 8192; } ];

  system.stateVersion = "26.05";               # match the release you install
}
```

Hardware-specific extras live in `hardware-configuration.nix`:

- **Disk encryption** — LUKS goes here, e.g. `boot.initrd.luks.devices.<name>.device`.
- **Swap partition** instead of a swapfile — use
  `swapDevices = [ { device = "/dev/disk/by-uuid/<uuid>"; } ];`.
- **Hibernation** — additionally set `boot.resumeDevice` (and a `resume_offset`
  kernel param when resuming from a swapfile).

### 3. Install

Partitioning and formatting are hardware-specific; follow the
[NixOS manual](https://nixos.org/manual/nixos/stable/#sec-installation) for that
step. Once the target is mounted at `/mnt`:

```bash
nixos-generate-config --root /mnt
# Put flake.nix + configuration.nix in /mnt/etc/nixos and keep the generated
# hardware-configuration.nix, then install the flake output:
nixos-install --flake /mnt/etc/nixos#laptop
reboot
```

The installer needs flakes enabled for `--flake`; if they are not on, prepend
`--option experimental-features 'nix-command flakes'` to `nixos-install`.

## Module Contents

`modules/plasma-firefox.nix` contains Plasma 6 Wayland, SDDM, hardware graphics,
Firefox, and Konsole.

`modules/laptop-base.nix` contains NetworkManager, Bluetooth, redistributable
firmware, CPU microcode updates (Intel and AMD), firmware updates (fwupd), power
profiles, printing, UPower, and zram swap. The microcode and firmware settings
are CPU- and vendor-agnostic, so the base works unchanged on any Intel or AMD
laptop.

`modules/audio.nix` contains PipeWire and realtime audio support.

`modules/firewall.nix` blocks unsolicited inbound TCP, UDP, and ping while
allowing outbound traffic and established return traffic. It is enabled by
default in `common-desktop` and can be disabled with:

```nix
common.firewall.enable = false;
```

`modules/doh.nix` enables system-wide DNS over HTTPS through `dnscrypt-proxy`
with static IPv4 and IPv6 DoH resolver stamps for Cloudflare, Mullvad, Quad9,
and Google. It points local resolver configuration at localhost and blocks
direct outbound TCP and UDP port 53 except to localhost. It is always enabled
for `common-desktop` hosts and has no opt-out, so plaintext DNS egress can never
be silently re-enabled. To keep captive portals usable behind that lock, the
connectivity-check names in `lib/captive-portals.txt` are answered locally from a
static map (so they resolve even when the DoH upstreams are unreachable), and
NetworkManager connectivity checking is enabled against `captive.apple.com` so
KDE Plasma detects the portal and offers the login page. The `nm-captive-portal`
test drives NetworkManager end-to-end against a fake `captive.apple.com`,
asserting it reports `full` on an open network and `portal` once the endpoint
redirects.

`modules/restic.nix` configures named restic backups using systemd credentials.
Each backup must specify the user that runs the service. Backup paths are bound
read-only into the hardened unit while `/home` is otherwise protected with a
temporary filesystem view.
Each backup expects a credential directory with raw secret files:

```text
/etc/credentials/restic/home/repository-password
/etc/credentials/restic/home/backend-username
/etc/credentials/restic/home/backend-password
```

Use the flake helper functions from a host configuration to keep backend shape
separate from the common module:

```nix
common.restic.backups.home = common.lib.restic.rest {
  user = "sashee";
  credentialDirectory = "/etc/credentials/restic/home";
  url = "https://backup.example.com";
  repository = "home";
  paths = [ "/home/sashee" ];
  exclude = [ ".stversions" ];
  prune.ignoreErrors = false;
};

common.restic.backups.photos = common.lib.restic.s3 {
  user = "sashee";
  credentialDirectory = "/etc/credentials/restic/photos";
  endpoint = "s3.example.com";
  bucket = "restic-backups";
  paths = [ "/home/sashee/Pictures" ];
  prune.ignoreErrors = true;
};
```

For S3 backups, use AWS credential files instead of `backend-password`:

```text
/etc/credentials/restic/photos/repository-password
/etc/credentials/restic/photos/aws-access-key-id
/etc/credentials/restic/photos/aws-secret-access-key
```

Missing credential files skip the generated backup unit instead of failing it.
Backups run `restic unlock` before `backup`, use `--group-by=` for backup and
retention, and run `restic check` after backup/retention.
When `prune.ignoreErrors = true`, backup success is preserved even if `restic
forget --prune` fails on an append-only repository.

`modules/monitoring.nix` runs daily health checks — SMART disk status, restic
backup age, local disk-space usage, NixOS system-generation count, and
auto-upgrade age — and reports the result to a Healthchecks-compatible URL. It is
**enabled by default**; when reporting is enabled (also the default), the host
must set `common.monitoring.report.credentialDirectory` (the directory holding
the URL credential) or evaluation fails. Disable the whole check with
`common.monitoring.enable = false`, or just the reporting with
`common.monitoring.report.enable = false`. See `common.monitoring.*` to tune each
check.

`modules/iroh-ssh.nix` keeps the laptop SSH-reachable by node identity
instead of IP: a hardened long-running service runs `iroh-ssh-listen` (a small
tool in `packages/iroh-ssh`, built on [iroh](https://iroh.computer))
forwarding incoming iroh streams to the local sshd at `127.0.0.1:22`. iroh
dials outbound through relays and hole-punches, so it works behind NAT and the
default-deny firewall without any inbound rules; port 22 stays closed to the
network (`services.openssh` is enabled with `mkDefault` and
`openFirewall = false`, so hosts keep control of sshd settings). It is
**enabled by default**; the host must set
`common.irohSsh.credentialDirectory` or evaluation fails
(`common.irohSsh.enable = false` opts out).

`iroh-ssh` is wire-compatible with [dumbpipe](https://www.dumbpipe.dev) (same
ALPN and handshake), reduced to the ssh-tunnel use case and split into one
binary per command (`iroh-ssh-listen`, `iroh-ssh-connect`,
`iroh-ssh-generate-secret`) so it needs no CLI-parser dependency. Two changes
from dumbpipe: the listener reads the key from the decrypted systemd credential
(`$CREDENTIALS_DIRECTORY/iroh-secret`) instead of the environment, and relay TLS
is verified against the operating system trust store instead of dumbpipe's
compiled-in Mozilla roots. The trust-store change
is what lets the VM test stay hermetic while server and client run *completely
stock* configuration: the test intercepts the DoH upstream traffic (the same
technique as the `doh-upstream` test), answering the real n0 relay hostnames
with a stand-in `iroh-relay` node whose TLS is trusted via a `security.pki`
test CA. Nothing on the tested node is reconfigured — its real dnscrypt/DoH
resolver, firewall, and default relay selection are exercised as shipped. The
trust-store behavior also means hosts can front a self-hosted relay with a
normally-issued certificate.

The iroh node identity comes from a stable secret key, stored encrypted at rest
with the host's systemd credential key (never in git or the store) and decrypted
by systemd into the unit's runtime credential directory. Provision it once per
host:

```bash
sudo install -d -m 0700 /etc/credentials/iroh-ssh
iroh-ssh-generate-secret \
  | sudo systemd-creds encrypt --name=iroh-secret - /etc/credentials/iroh-ssh/iroh-secret
sudo chmod 0600 /etc/credentials/iroh-ssh/iroh-secret
```

`iroh-ssh-generate-secret` uses iroh's own key generator (so the key is the
right size for whatever iroh version is built in) and prints the node's endpoint
id to stderr while the secret goes to stdout for the pipe. Set
`common.irohSsh.credentialDirectory = "/etc/credentials/iroh-ssh";`. The
`--name=iroh-secret` and the `iroh-secret` filename must match, or systemd
refuses to decrypt it. Until the blob exists the unit skips gracefully
(`ConditionPathExists`) instead of crash-looping.

Read the connect ticket from the journal — the last printed (short) ticket is
stable across restarts and networks because the key is stable, so grab it once:

```bash
journalctl -u iroh-ssh.service | grep 'iroh-ssh-connect'
```

Connect from any machine, no IP address needed (`nix run
github:sashee/nixos-test#iroh-ssh` works in place of an installed
`iroh-ssh-connect`; stock `dumbpipe connect` also accepts the same ticket):

```bash
ssh -o ProxyCommand='iroh-ssh-connect <ticket>' user@laptop
```

`modules/fonts.nix` contains common desktop fonts.

`modules/development-base.nix` contains common CLI tools and direnv with
nix-direnv.

`modules/nix-utils.nix` installs the full sandboxed utility environment from
the `github:sashee/dotfiles/bwrap` flake input's `nix-utils` directory with
this flake's `pkgs`, `unstable = pkgs`, and `nixgl = null` for native NixOS
graphics.

`modules/nix-settings.nix` enables flakes, nix-command, store
optimisation, and automatic garbage collection.

## QEMU VM

The `nix` commands below pass `--extra-experimental-features 'nix-command
flakes'`, so they work even if flakes are not enabled in your `nix.conf`. To
avoid repeating the flag, enable them permanently by adding this line to
`~/.config/nix/nix.conf` (or `/etc/nix/nix.conf`):

```text
experimental-features = nix-command flakes
```

The `./result/bin/run-nixos-qemu-vm` runner needs no Nix flags at all.

Build the graphical VM:

```bash
nix --extra-experimental-features 'nix-command flakes' build .#qemu-vm
```

Run it:

```bash
./result/bin/run-nixos-qemu-vm
```

Try GL acceleration for Plasma:

```bash
QEMU_OPTS="-display gtk,gl=on -device virtio-vga-gl" ./result/bin/run-nixos-qemu-vm
```

The VM starts Plasma Wayland in a QEMU window and logs in as `demo`
automatically.

Check rendering inside the VM:

```bash
glxinfo -B
```

`virgl` in the renderer usually means accelerated virtual graphics are working. `llvmpipe`, `softpipe`, or `Software Rasterizer` means rendering is happening on the CPU.

Manual login details, if needed:

```text
user: demo
password: demo
```

If QEMU complains about KVM permissions, either add your host user to the `kvm` group or run without KVM:

```bash
QEMU_OPTS="-accel tcg" ./result/bin/run-nixos-qemu-vm
```

## Running the rpi tests locally

The aarch64 checks boot the exact patched rpi kernel, which is in no binary
cache — built from scratch it takes hours under emulation. CI builds it on the
native arm64 runner and uploads its closure as the `rpi-kernel-cache` artifact,
so a laptop can import it instead of compiling:

```bash
# once per flake.lock / kernel-config change:
gh run download --name rpi-kernel-cache --dir rpi-kernel-cache
make import-rpi-kernel CACHE=rpi-kernel-cache

make run-rpi-tests
```

`import-rpi-kernel` first evaluates the kernel path locally, so it fails
loudly if the artifact was produced from a different flake.lock or kernel
config instead of importing a stale kernel. The host also needs to be able to
build the remaining (cheap) aarch64 derivations, e.g. on NixOS:

```nix
boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
```

Note the checks use aarch64 `hostPkgs`, so the test driver and QEMU themselves
run under binfmt user emulation on x86 — correct but slow; expect much longer
runtimes than CI's native arm64 runner.

## Verified Result

Build the combined result with live logs:

```bash
make qemu-result
```

This runs all VM checks and produces the QEMU runner, launch commands, test
outputs, and selected screenshots:

```text
result/bin/run-nixos-qemu-vm
result/qemu-command
result/common-desktop-check
result/doh-check
result/doh-upstream-check
result/doh-captive-check
result/nm-captive-portal-check
result/firewall-check
result/locale-firefox-check
result/plasma-firefox-check
result/restic-check
result/test-results/common-desktop
result/test-results/doh
result/test-results/doh-upstream
result/test-results/doh-captive
result/test-results/nm-captive-portal
result/test-results/firewall
result/test-results/locale-firefox
result/test-results/plasma-firefox
result/test-results/restic
result/plasma-desktop.png
result/firefox-page.png
```

The default package is the same verified result:

```bash
nix --extra-experimental-features 'nix-command flakes' build -L
```

Tests live under `tests/`. Run one test during development by building its check:

```bash
nix --extra-experimental-features 'nix-command flakes' build -L .#checks.x86_64-linux.plasma-firefox
nix --extra-experimental-features 'nix-command flakes' build -L .#checks.x86_64-linux.common-desktop
nix --extra-experimental-features 'nix-command flakes' build -L .#checks.x86_64-linux.doh
nix --extra-experimental-features 'nix-command flakes' build -L .#checks.x86_64-linux.doh-upstream
nix --extra-experimental-features 'nix-command flakes' build -L .#checks.x86_64-linux.doh-captive
nix --extra-experimental-features 'nix-command flakes' build -L .#checks.x86_64-linux.nm-captive-portal
nix --extra-experimental-features 'nix-command flakes' build -L .#checks.x86_64-linux.firewall
nix --extra-experimental-features 'nix-command flakes' build -L .#checks.x86_64-linux.locale-firefox
nix --extra-experimental-features 'nix-command flakes' build -L .#checks.x86_64-linux.restic
```

Run all tests and collect every test output under one result tree:

```bash
make test-results
```

The aggregate result is organized by test name:

```text
result/common-desktop
result/doh
result/doh-upstream
result/doh-captive
result/nm-captive-portal
result/firewall
result/locale-firefox
result/plasma-firefox
result/restic
```

The Makefile uses `--max-jobs 2` so Nix runs at most two test derivations at a
time. To override that locally:

```bash
make test-results MAX_JOBS=1
```

`doh-upstream` is hermetic: it routes `doh-test` default IPv4 traffic through
`dns-peer`, redirects outbound HTTPS there, and verifies that a local DNS query
becomes an HTTPS `/dns-query` request to one of the configured DoH hostnames.

Run all checks directly:

```bash
nix --extra-experimental-features 'nix-command flakes' flake check -L
```

`flake check` does not create a convenient `./result` symlink. Use
`.#all-test-results` when you want the collected outputs and screenshots.

Build the interactive test driver:

```bash
nix --extra-experimental-features 'nix-command flakes' build .#plasma-firefox-driver-interactive
```
