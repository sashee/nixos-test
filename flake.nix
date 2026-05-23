{
  description = "Small graphical NixOS VM for QEMU";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs = { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      plasmaFirefoxModule = ./modules/plasma-firefox.nix;
      qemuDemoUserModule = ./modules/qemu-demo-user.nix;
      qemuGraphical = nixpkgs.lib.nixosSystem {
        inherit system;

        modules = [
          "${nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
          plasmaFirefoxModule
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
      plasmaFirefoxTest = nixpkgs.lib.nixos.runTest {
        name = "plasma-firefox";
        hostPkgs = pkgs;
        globalTimeout = 300;

        nodes.machine = {
          imports = [
            plasmaFirefoxModule
            qemuDemoUserModule
          ];

          networking.hostName = "plasma-firefox-test";

          services.displayManager.defaultSession = "plasma";

          virtualisation = {
            cores = 2;
            memorySize = 4096;
          };
        };

        testScript = ''
          machine.start()
          machine.wait_for_unit("graphical.target")
          machine.wait_until_succeeds("pgrep -u demo plasmashell")
          machine.wait_until_succeeds("pgrep -u demo kwin_wayland")
          machine.screenshot("plasma-desktop")

          machine.succeed("mkdir -p /tmp/site")
          machine.succeed("printf '%s\n' '<!doctype html><title>NixOS VM test</title><h1>Firefox started</h1>' > /tmp/site/index.html")
          machine.succeed("systemd-run --unit test-http-server --property WorkingDirectory=/tmp/site ${pkgs.python3}/bin/python3 -m http.server 8000")
          machine.wait_for_unit("test-http-server.service")
          machine.wait_until_succeeds("curl --fail --head http://127.0.0.1:8000/")

          machine.succeed("su - demo -c 'firefox --headless --screenshot /tmp/firefox-page.png http://127.0.0.1:8000/ >/tmp/firefox.log 2>&1'")
          machine.succeed("test -s /tmp/firefox-page.png")
          machine.copy_from_vm("/tmp/firefox-page.png")
        '';
      };
      qemuPlasmaResult = pkgs.runCommand "qemu-plasma-result" { } ''
        mkdir -p $out/bin
        ln -s ${qemuVm}/bin/run-nixos-qemu-vm $out/bin/run-nixos-qemu-vm
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
        plasma-firefox = plasmaFirefoxModule;
        qemu-demo-user = qemuDemoUserModule;
        graphical-desktop = ./modules/graphical-desktop.nix;
      };

      legacyPackages.${system} = pkgs;

      nixosConfigurations.qemu-graphical = qemuGraphical;

      checks.${system}.plasma-firefox = plasmaFirefoxTest;

      packages.${system} = {
        default = qemuPlasmaResult;
        qemu-vm = qemuVm;
        qemu-plasma-result = qemuPlasmaResult;
        plasma-firefox-driver = plasmaFirefoxTest.driver;
        plasma-firefox-driver-interactive = plasmaFirefoxTest.driverInteractive;
      };
    };
}
