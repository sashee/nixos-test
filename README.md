# Plasma Firefox NixOS Module

This flake exports one composed NixOS desktop module and a QEMU VM/check that
exercise that same common configuration.

## Laptop Import

Use this flake as the source of `nixpkgs` so the laptop and common config do not
evaluate against competing nixpkgs revisions:

```nix
{
  inputs = {
    common.url = "path:/home/sashee/workspace/nixos-test";
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

## Module Contents

`modules/plasma-firefox.nix` contains Plasma 6 Wayland, SDDM, hardware graphics,
Firefox, and Konsole.

`modules/laptop-base.nix` contains NetworkManager, Bluetooth, firmware updates,
power profiles, printing, and UPower.

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
