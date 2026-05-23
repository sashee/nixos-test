{
  description = "Small graphical NixOS VM for QEMU";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs = { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      audioModule = ./modules/audio.nix;
      commonDesktopModule = ./modules/common-desktop.nix;
      fontsModule = ./modules/fonts.nix;
      plasmaFirefoxModule = ./modules/plasma-firefox.nix;
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
      plasmaFirefoxTest = nixpkgs.lib.nixos.runTest {
        name = "plasma-firefox";
        hostPkgs = pkgs;
        globalTimeout = 300;

        nodes.machine = {
          imports = [
            commonDesktopModule
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
      commonDesktopTest = nixpkgs.lib.nixos.runTest {
        name = "common-desktop";
        hostPkgs = pkgs;
        globalTimeout = 300;

        nodes.machine = {
          imports = [
            commonDesktopModule
            qemuDemoUserModule
          ];

          networking.hostName = "common-desktop-test";

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

          machine.succeed("systemctl is-active NetworkManager.service")
          machine.succeed("systemctl is-enabled bluetooth.service")
          machine.succeed("systemctl is-active cups.socket")
          machine.wait_until_succeeds("systemctl is-active upower.service")
          machine.succeed("(systemctl is-enabled power-profiles-daemon.service || true) | grep -E '^(enabled|linked)$'")
        '';
      };
      fontsTest = nixpkgs.lib.nixos.runTest {
        name = "fonts";
        hostPkgs = pkgs;

        nodes.machine = {
          imports = [ fontsModule ];

          networking.hostName = "fonts-test";
          system.stateVersion = "25.11";
        };

        testScript = ''
          machine.start()
          machine.wait_for_unit("multi-user.target")

          machine.succeed("${pkgs.fontconfig}/bin/fc-match 'Noto Sans' | grep -i Noto")
          machine.succeed("${pkgs.fontconfig}/bin/fc-match 'Noto Sans CJK SC' | grep -i Noto")
          machine.succeed("${pkgs.fontconfig}/bin/fc-match 'Noto Color Emoji' | grep -i Emoji")
        '';
      };
      audioTest = nixpkgs.lib.nixos.runTest {
        name = "audio";
        hostPkgs = pkgs;

        nodes.machine = { pkgs, ... }: {
          imports = [ audioModule ];

          networking.hostName = "audio-test";
          system.stateVersion = "25.11";

          users.users.demo.isNormalUser = true;

          environment.systemPackages = [ pkgs.pulseaudio ];
        };

        testScript = ''
          machine.start()
          machine.wait_for_unit("multi-user.target")
          machine.succeed("loginctl enable-linger demo")
          machine.succeed("systemctl start user@1000.service")
          machine.wait_for_unit("user@1000.service")

          machine.succeed("runuser -u demo -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemctl --user is-active pipewire.socket")
          machine.succeed("runuser -u demo -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemctl --user is-active pipewire-pulse.socket")
          machine.succeed("runuser -u demo -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemctl --user start pipewire.service wireplumber.service pipewire-pulse.service")
          machine.succeed("runuser -u demo -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemctl --user is-active pipewire.service")
          machine.succeed("runuser -u demo -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemctl --user is-active wireplumber.service")
          machine.wait_until_succeeds("runuser -u demo -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus pactl info")
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
        audio = ./modules/audio.nix;
        common-desktop = commonDesktopModule;
        development-base = ./modules/development-base.nix;
        fonts = ./modules/fonts.nix;
        laptop-base = ./modules/laptop-base.nix;
        nix-settings = ./modules/nix-settings.nix;
        plasma-firefox = plasmaFirefoxModule;
        qemu-demo-user = qemuDemoUserModule;
        graphical-desktop = ./modules/graphical-desktop.nix;
      };

      legacyPackages.${system} = pkgs;

      nixosConfigurations.qemu-graphical = qemuGraphical;

      checks.${system} = {
        audio = audioTest;
        common-desktop = commonDesktopTest;
        fonts = fontsTest;
        plasma-firefox = plasmaFirefoxTest;
      };

      packages.${system} = {
        default = qemuPlasmaResult;
        audio-driver = audioTest.driver;
        audio-driver-interactive = audioTest.driverInteractive;
        common-desktop-driver = commonDesktopTest.driver;
        common-desktop-driver-interactive = commonDesktopTest.driverInteractive;
        fonts-driver = fontsTest.driver;
        fonts-driver-interactive = fontsTest.driverInteractive;
        qemu-vm = qemuVm;
        qemu-plasma-result = qemuPlasmaResult;
        plasma-firefox-driver = plasmaFirefoxTest.driver;
        plasma-firefox-driver-interactive = plasmaFirefoxTest.driverInteractive;
      };
    };
}
