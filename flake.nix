{
  description = "Small graphical NixOS VM for QEMU";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs = { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      stateVersion = nixpkgs.lib.trivial.release;
      pkgs = nixpkgs.legacyPackages.${system};
      commonDesktopModule = ./modules/common-desktop.nix;
      qemuDemoUserModule = ./modules/qemu-demo-user.nix;
      dohStamps = import ./lib/doh-stamps.nix;
      resticLib = import ./lib/restic.nix { lib = nixpkgs.lib; };
      qemuGraphical = nixpkgs.lib.nixosSystem {
        inherit system;

        modules = [
          "${nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
          commonDesktopModule
          qemuDemoUserModule

          {
            system.stateVersion = stateVersion;

            networking.hostName = "nixos-qemu";

            common.locale.default = "hu_HU.UTF-8";

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
        inherit nixpkgs pkgs commonDesktopModule qemuDemoUserModule stateVersion;
      };
      commonDesktopTest = import ./tests/common-desktop.nix {
        inherit nixpkgs pkgs commonDesktopModule qemuDemoUserModule stateVersion;
      };
      localeFirefoxTest = import ./tests/locale-firefox.nix {
        inherit nixpkgs pkgs commonDesktopModule qemuDemoUserModule stateVersion;
      };
      firewallTest = import ./tests/firewall.nix {
        inherit nixpkgs pkgs commonDesktopModule stateVersion;
      };
      dohTest = import ./tests/doh.nix {
        inherit nixpkgs pkgs commonDesktopModule stateVersion;
      };
      dohUpstreamTest = import ./tests/doh-upstream.nix {
        inherit nixpkgs pkgs commonDesktopModule stateVersion dohStamps;
      };
      resticTest = import ./tests/restic.nix {
        inherit nixpkgs pkgs commonDesktopModule stateVersion;
      };
      testResults = {
        common-desktop = commonDesktopTest;
        doh = dohTest;
        doh-upstream = dohUpstreamTest;
        firewall = firewallTest;
        locale-firefox = localeFirefoxTest;
        plasma-firefox = plasmaFirefoxTest;
        restic = resticTest;
      };
      testResultLinks = nixpkgs.lib.concatStringsSep "\n" (
        nixpkgs.lib.mapAttrsToList
          (name: test: "ln -s ${test} $out/${nixpkgs.lib.escapeShellArg name}")
          testResults
      );
      qemuCheckLinks = nixpkgs.lib.concatStringsSep "\n" (
        nixpkgs.lib.mapAttrsToList
          (name: _: "ln -s ${allTestResults}/${nixpkgs.lib.escapeShellArg name} $out/${nixpkgs.lib.escapeShellArg "${name}-check"}")
          testResults
      );
      allTestResults = pkgs.runCommand "all-test-results" { } ''
        mkdir -p $out
        ${testResultLinks}
      '';
      qemuPlasmaResult = pkgs.runCommand "qemu-plasma-result" { } ''
        mkdir -p $out/bin
        ln -s ${qemuVm}/bin/run-nixos-qemu-vm $out/bin/run-nixos-qemu-vm
        ln -s ${allTestResults} $out/test-results
        ${qemuCheckLinks}
        cp ${allTestResults}/plasma-firefox/plasma-desktop.png $out/plasma-desktop.png
        cp ${allTestResults}/plasma-firefox/firefox-page.png $out/firefox-page.png

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

      lib.restic = resticLib;

      legacyPackages.${system} = pkgs;

      nixosConfigurations.qemu-graphical = qemuGraphical;

      checks.${system} = testResults;

      packages.${system} = {
        default = qemuPlasmaResult;
        all-test-results = allTestResults;
        common-desktop-driver = commonDesktopTest.driver;
        common-desktop-driver-interactive = commonDesktopTest.driverInteractive;
        doh-driver = dohTest.driver;
        doh-driver-interactive = dohTest.driverInteractive;
        doh-upstream-driver = dohUpstreamTest.driver;
        doh-upstream-driver-interactive = dohUpstreamTest.driverInteractive;
        firewall-driver = firewallTest.driver;
        firewall-driver-interactive = firewallTest.driverInteractive;
        locale-firefox-driver = localeFirefoxTest.driver;
        locale-firefox-driver-interactive = localeFirefoxTest.driverInteractive;
        qemu-vm = qemuVm;
        qemu-plasma-result = qemuPlasmaResult;
        plasma-firefox-driver = plasmaFirefoxTest.driver;
        plasma-firefox-driver-interactive = plasmaFirefoxTest.driverInteractive;
        restic-driver = resticTest.driver;
        restic-driver-interactive = resticTest.driverInteractive;
      };
    };
}
