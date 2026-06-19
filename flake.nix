{
  description = "Small graphical NixOS VM for QEMU";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    dotfiles = {
      url = "github:sashee/dotfiles/bwrap";
      flake = false;
    };
  };

  outputs = { nixpkgs, nixpkgs-unstable, dotfiles, ... }:
    let
      system = "x86_64-linux";
      stateVersion = nixpkgs.lib.trivial.release;
      pkgs = nixpkgs.legacyPackages.${system};
      unstable = import nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      };
      commonDesktopModule = { ... }: {
        imports = [ ./modules/common-desktop.nix ];
        _module.args.commonDotfiles = dotfiles;
        _module.args.unstable = unstable;
      };
      qemuDemoUserModule = ./modules/qemu-demo-user.nix;
      nixUtilsTests = import "${dotfiles}/nix-utils/tests/lib.nix" {
        inherit pkgs;
        machineModules = [
          commonDesktopModule
          qemuDemoUserModule
          {
            system.stateVersion = stateVersion;
            common.autoUpgrade.enable = false;
            common.monitoring.enable = false;
          }
        ];
        user = "demo";
      };
      nixUtilsTestDrivers = nixpkgs.lib.concatMapAttrs
        (name: test: {
          "nix-utils-${name}-driver" = test.driver;
          "nix-utils-${name}-driver-interactive" = test.driverInteractive;
        })
        nixUtilsTests;
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
            common.autoUpgrade.enable = false;
            common.monitoring.enable = false;

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
      dohCaptiveTest = import ./tests/doh-captive.nix {
        inherit nixpkgs pkgs commonDesktopModule stateVersion;
      };
      nmCaptivePortalTest = import ./tests/nm-captive-portal.nix {
        inherit nixpkgs pkgs commonDesktopModule stateVersion;
      };
      resticTest = import ./tests/restic.nix {
        inherit nixpkgs pkgs commonDesktopModule stateVersion;
      };
      monitoringAutoUpgradeTest = import ./tests/monitoring/auto-upgrade.nix {
        inherit nixpkgs pkgs stateVersion;
      };
      monitoringDiskSpaceTest = import ./tests/monitoring/disk-space.nix {
        inherit nixpkgs pkgs stateVersion;
      };
      monitoringGenerationsTest = import ./tests/monitoring/generations.nix {
        inherit nixpkgs pkgs stateVersion;
      };
      monitoringReportingTest = import ./tests/monitoring/reporting.nix {
        inherit nixpkgs pkgs stateVersion;
      };
      monitoringResticTest = import ./tests/monitoring/restic.nix {
        inherit nixpkgs pkgs commonDesktopModule stateVersion;
      };
      nixSettingsTest = import ./tests/nix-settings.nix {
        inherit nixpkgs pkgs stateVersion;
      };
      autoUpgradeMockedServiceTest = import ./tests/auto-upgrade-mocked-service.nix {
        autoUpgradeModule = ./modules/auto-upgrade.nix;
        inherit nixpkgs pkgs stateVersion;
      };
      zramTest = import ./tests/zram.nix {
        inherit nixpkgs pkgs stateVersion;
      };
      testResults = {
        auto-upgrade-mocked-service = autoUpgradeMockedServiceTest;
        common-desktop = commonDesktopTest;
        doh = dohTest;
        doh-upstream = dohUpstreamTest;
        doh-captive = dohCaptiveTest;
        nm-captive-portal = nmCaptivePortalTest;
        firewall = firewallTest;
        locale-firefox = localeFirefoxTest;
        monitoring-auto-upgrade = monitoringAutoUpgradeTest;
        monitoring-disk-space = monitoringDiskSpaceTest;
        monitoring-generations = monitoringGenerationsTest;
        monitoring-reporting = monitoringReportingTest;
        monitoring-restic = monitoringResticTest;
        nix-settings = nixSettingsTest;
        plasma-firefox = plasmaFirefoxTest;
        restic = resticTest;
        zram = zramTest;
      } // (nixpkgs.lib.mapAttrs'
        (name: test: nixpkgs.lib.nameValuePair "nix-utils-${name}" test)
        nixUtilsTests);
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
        auto-upgrade = ./modules/auto-upgrade.nix;
        common-desktop = commonDesktopModule;
      };

      lib.restic = resticLib;

      legacyPackages.${system} = pkgs;

      nixosConfigurations = {
        qemu-graphical = qemuGraphical;
      };

      checks.${system} = testResults;

      packages.${system} = {
        default = qemuPlasmaResult;
        all-test-results = allTestResults;
        auto-upgrade-mocked-service-driver = autoUpgradeMockedServiceTest.driver;
        auto-upgrade-mocked-service-driver-interactive = autoUpgradeMockedServiceTest.driverInteractive;
        common-desktop-driver = commonDesktopTest.driver;
        common-desktop-driver-interactive = commonDesktopTest.driverInteractive;
        doh-driver = dohTest.driver;
        doh-driver-interactive = dohTest.driverInteractive;
        doh-upstream-driver = dohUpstreamTest.driver;
        doh-upstream-driver-interactive = dohUpstreamTest.driverInteractive;
        doh-captive-driver = dohCaptiveTest.driver;
        doh-captive-driver-interactive = dohCaptiveTest.driverInteractive;
        nm-captive-portal-driver = nmCaptivePortalTest.driver;
        nm-captive-portal-driver-interactive = nmCaptivePortalTest.driverInteractive;
        firewall-driver = firewallTest.driver;
        firewall-driver-interactive = firewallTest.driverInteractive;
        locale-firefox-driver = localeFirefoxTest.driver;
        locale-firefox-driver-interactive = localeFirefoxTest.driverInteractive;
        monitoring-auto-upgrade-driver = monitoringAutoUpgradeTest.driver;
        monitoring-auto-upgrade-driver-interactive = monitoringAutoUpgradeTest.driverInteractive;
        monitoring-disk-space-driver = monitoringDiskSpaceTest.driver;
        monitoring-disk-space-driver-interactive = monitoringDiskSpaceTest.driverInteractive;
        monitoring-generations-driver = monitoringGenerationsTest.driver;
        monitoring-generations-driver-interactive = monitoringGenerationsTest.driverInteractive;
        monitoring-reporting-driver = monitoringReportingTest.driver;
        monitoring-reporting-driver-interactive = monitoringReportingTest.driverInteractive;
        monitoring-restic-driver = monitoringResticTest.driver;
        monitoring-restic-driver-interactive = monitoringResticTest.driverInteractive;
        nix-settings-driver = nixSettingsTest.driver;
        nix-settings-driver-interactive = nixSettingsTest.driverInteractive;
        qemu-vm = qemuVm;
        qemu-plasma-result = qemuPlasmaResult;
        plasma-firefox-driver = plasmaFirefoxTest.driver;
        plasma-firefox-driver-interactive = plasmaFirefoxTest.driverInteractive;
        restic-driver = resticTest.driver;
        restic-driver-interactive = resticTest.driverInteractive;
        zram-driver = zramTest.driver;
        zram-driver-interactive = zramTest.driverInteractive;
      } // nixUtilsTestDrivers;
    };
}
