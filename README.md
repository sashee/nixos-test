# Plasma Firefox NixOS Module

This flake exports a reusable Plasma Wayland + Firefox NixOS module and a QEMU
VM/check that exercise the same module.

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
        common.nixosModules.plasma-firefox
        ./configuration.nix
      ];
    };
  };
}
```

The reusable module contains Plasma 6 Wayland, SDDM, hardware graphics, Firefox,
and Konsole. VM-only users, autologin, and test tools live in
`common.nixosModules.qemu-demo-user`.

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

This runs the VM check and produces the QEMU runner, launch commands, and
screenshots:

```text
result/bin/run-nixos-qemu-vm
result/qemu-command
result/plasma-desktop.png
result/firefox-page.png
```

The default package is the same verified result:

```bash
nix --extra-experimental-features 'nix-command flakes' build -L
```

Run only the automated VM check:

```bash
nix --extra-experimental-features 'nix-command flakes' build -L .#checks.x86_64-linux.plasma-firefox
```

Build the interactive test driver:

```bash
nix --extra-experimental-features 'nix-command flakes' build .#plasma-firefox-driver-interactive
```
