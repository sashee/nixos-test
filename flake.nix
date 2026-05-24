{
  description = "Small graphical NixOS VM for QEMU";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs = { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      commonDesktopModule = ./modules/common-desktop.nix;
      qemuDemoUserModule = ./modules/qemu-demo-user.nix;
      qemuGraphical = nixpkgs.lib.nixosSystem {
        inherit system;

        modules = [
          "${nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
          commonDesktopModule
          qemuDemoUserModule

          {
            networking.hostName = "nixos-qemu";

            virtualisation = {
              cores = 6;
              graphics = true;
              memorySize = 8192;
            };
          }
        ];
      };
      qemuVm = qemuGraphical.config.system.build.vm;
      plasmaFirefoxTest = import ./tests/plasma-firefox.nix {
        inherit nixpkgs pkgs commonDesktopModule qemuDemoUserModule;
      };
      commonDesktopTest = import ./tests/common-desktop.nix {
        inherit nixpkgs pkgs commonDesktopModule qemuDemoUserModule;
      };
      firewallTest = import ./tests/firewall.nix {
        inherit nixpkgs pkgs commonDesktopModule;
      };
      qemuPlasmaResult = pkgs.runCommand "qemu-plasma-result" { } ''
        mkdir -p $out/bin
        ln -s ${qemuVm}/bin/run-nixos-qemu-vm $out/bin/run-nixos-qemu-vm
        ln -s ${commonDesktopTest} $out/common-desktop-check
        ln -s ${firewallTest} $out/firewall-check
        cp ${plasmaFirefoxTest}/plasma-desktop.png $out/plasma-desktop.png
        cp ${plasmaFirefoxTest}/firefox-page.png $out/firefox-page.png

        cat > $out/qemu-command <<'EOF'
        ./result/bin/run-nixos-qemu-vm

        # With virtio GL on hosts where QEMU can access the host OpenGL stack:
        QEMU_OPTS="-display gtk,gl=on -device virtio-vga-gl" ./result/bin/run-nixos-qemu-vm

        # On non-NixOS hosts, use nixGL if the GL command fails:
        QEMU_OPTS="-display gtk,gl=on -device virtio-vga-gl" nix run --extra-experimental-features 'nix-command flakes' --impure github:nix-community/nixGL -- ./result/bin/run-nixos-qemu-vm
        EOF

        sed -i 's/^        //' $out/qemu-command
      '';
    in
    {
      nixosModules = {
        common-desktop = commonDesktopModule;
      };

      legacyPackages.${system} = pkgs;

      nixosConfigurations.qemu-graphical = qemuGraphical;

      checks.${system} = {
        common-desktop = commonDesktopTest;
        firewall = firewallTest;
        plasma-firefox = plasmaFirefoxTest;
      };

      packages.${system} = {
        default = qemuPlasmaResult;
        common-desktop-driver = commonDesktopTest.driver;
        common-desktop-driver-interactive = commonDesktopTest.driverInteractive;
        firewall-driver = firewallTest.driver;
        firewall-driver-interactive = firewallTest.driverInteractive;
        qemu-vm = qemuVm;
        qemu-plasma-result = qemuPlasmaResult;
        plasma-firefox-driver = plasmaFirefoxTest.driver;
        plasma-firefox-driver-interactive = plasmaFirefoxTest.driverInteractive;
      };
    };
}
