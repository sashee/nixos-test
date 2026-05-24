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
modules/fonts.nix
modules/development-base.nix
modules/plasma-firefox.nix
```

Host-specific users, hostnames, disks, bootloaders, passwords, and hardware
quirks should stay in the laptop config.

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

`modules/fonts.nix` contains common desktop fonts.

`modules/development-base.nix` contains common CLI tools and direnv with
nix-direnv.

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
nix --extra-experimental-features 'nix-command flakes' build -L .#qemu-plasma-result
```

This runs all VM checks and produces the QEMU runner, launch commands, and
screenshots:

```text
result/bin/run-nixos-qemu-vm
result/qemu-command
result/common-desktop-check
result/firewall-check
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
nix --extra-experimental-features 'nix-command flakes' build -L .#checks.x86_64-linux.firewall
```

Run all checks directly:

```bash
nix --extra-experimental-features 'nix-command flakes' flake check -L
```

Build the interactive test driver:

```bash
nix --extra-experimental-features 'nix-command flakes' build .#plasma-firefox-driver-interactive
```
