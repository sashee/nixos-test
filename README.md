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
```

You must add per host:

```text
hardware-configuration.nix (generated)
bootloader, networking.hostName, time.timeZone
users + passwords
disk encryption (LUKS), on-disk swap (+ resume for hibernation)
common.autoUpgrade.flake
```

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
direct outbound TCP and UDP port 53 except to localhost. It is enabled by
default in `common-desktop` and can be disabled with:

```nix
common.doh.enable = false;
```

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
auto-upgrade age — and reports the result to a Healthchecks-compatible URL. See
the `common.monitoring.*` options to enable reporting and tune each check.

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
result/firewall-check
result/locale-firefox-check
result/plasma-firefox-check
result/restic-check
result/test-results/common-desktop
result/test-results/doh
result/test-results/doh-upstream
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
