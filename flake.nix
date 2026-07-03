{
  description = "Small graphical NixOS VM for QEMU";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi";
    dotfiles = {
      url = "github:sashee/dotfiles/master";
      flake = false;
    };
  };

  outputs = { nixpkgs, nixpkgs-unstable, dotfiles, nixos-raspberrypi, ... }:
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
      mkRpi5 = { modules ? [ ] }: nixos-raspberrypi.lib.nixosSystem {
        trustCaches = false;
        specialArgs = {
          inherit dotfiles nixpkgs-unstable;
          nixpkgs-stable = nixpkgs;
        };
        modules = [
          nixos-raspberrypi.nixosModules.sd-image
          ({ ... }: { imports = with nixos-raspberrypi.nixosModules; [ raspberry-pi-5.base ]; })
          ./hosts/rpi5/configuration.nix
        ] ++ modules;
      };
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
        inherit nixpkgs pkgs stateVersion;
        machineModule = { ... }: {
          imports = [ commonDesktopModule ];
          common.autoUpgrade.enable = false;
          common.monitoring.enable = false;
        };
      };

      # aarch64 Raspberry Pi 5 check: exercise the doh module on the exact kernel
      # and nixpkgs the Pi runs, in a KVM-accelerated aarch64 VM.
      nixrpi = nixos-raspberrypi.inputs.nixpkgs;
      pkgsRpi = nixrpi.legacyPackages.aarch64-linux;
      rpi5Base = mkRpi5 { };
      # Boot rpi tests on the EXACT rpi kernel. QEMU's virt machine needs the generic
      # ECAM PCIe host bridge (a DT-bound module) force-loaded; virtio + 9p then autoload.
      rpiTestKernel = { lib, ... }: {
        boot.kernelPackages = lib.mkForce rpi5Base.config.boot.kernelPackages;
        boot.kernelPatches = lib.mkForce [ ];
        boot.initrd.kernelModules = [ "pci_host_generic" ];
      };
      # The real rpi system config as a test node (hosts/rpi5 on the rpi kernel, with
      # the nix-utils args mkRpi5 passes via specialArgs). All rpi tests build on this
      # so they exercise the deployed config.
      rpiSystemModule = { ... }: {
        imports = [ ./hosts/rpi5/configuration.nix rpiTestKernel ];
        _module.args = { inherit dotfiles nixpkgs-unstable; nixpkgs-stable = nixpkgs; };
      };
      dohTestRpi = import ./tests/doh.nix {
        nixpkgs = nixrpi;
        pkgs = pkgsRpi;
        stateVersion = rpi5Base.config.system.stateVersion;
        machineModule = rpiSystemModule;
      };
      autoUpgradeTestRpi = import ./tests/auto-upgrade-mocked-service.nix {
        nixpkgs = nixrpi;
        pkgs = pkgsRpi;
        stateVersion = rpi5Base.config.system.stateVersion;
        autoUpgradeModule = ./modules/auto-upgrade.nix;
        nodeModule = rpiSystemModule;
        flakeRef = "/etc/nixos#rpi5";
      };
      nixSettingsTestRpi = import ./tests/nix-settings.nix {
        nixpkgs = nixrpi;
        pkgs = pkgsRpi;
        stateVersion = rpi5Base.config.system.stateVersion;
        extraModule = rpiSystemModule;
        gcOptions = "--delete-old";
      };
      autoUpgradeRebootTestRpi = import ./tests/auto-upgrade-reboot.nix {
        nixpkgs = nixrpi;
        pkgs = pkgsRpi;
        stateVersion = rpi5Base.config.system.stateVersion;
        machineModule = rpiSystemModule;
      };
      zramTestRpi = import ./tests/zram.nix {
        nixpkgs = nixrpi;
        pkgs = pkgsRpi;
        stateVersion = rpi5Base.config.system.stateVersion;
        machineModule = rpiSystemModule;
      };
      nixGcRetentionTestRpi = import ./tests/nix-gc-retention.nix {
        nixpkgs = nixrpi;
        pkgs = pkgsRpi;
        stateVersion = rpi5Base.config.system.stateVersion;
        machineModule = rpiSystemModule;
        keptAfterGc = 1;  # --delete-old keeps only the current generation
      };
      # Nix only exposes /dev/kvm in the sandbox based on the daemon's system-features
      # (auto-set from the host's /dev/kvm), NOT a derivation's requiredSystemFeatures.
      # So dropping the kvm *requirement* lets tests schedule on KVM-less builders (the
      # free aarch64 CI runner) while QEMU's accel=kvm:tcg still uses KVM wherever it
      # exists (x86 runner) and only falls back to slow TCG when it doesn't (rpi).
      dropKvm = test: test.overrideTestDerivation (old: {
        requiredSystemFeatures = builtins.filter (f: f != "kvm") old.requiredSystemFeatures;
      });
      # All aarch64 (Raspberry Pi 5) checks in one place. Add new rpi tests here;
      # CI builds the aggregate below, so the workflow never needs editing.
      aarch64TestResults = builtins.mapAttrs (_: dropKvm) {
        doh = dohTestRpi;
        auto-upgrade = autoUpgradeTestRpi;
        nix-settings = nixSettingsTestRpi;
        auto-upgrade-reboot = autoUpgradeRebootTestRpi;
        zram = zramTestRpi;
        nix-gc-retention = nixGcRetentionTestRpi;
      };
      rpiAllTests = pkgsRpi.runCommand "rpi-all-tests" { } ''
        mkdir -p $out
        ${nixpkgs.lib.concatStringsSep "\n" (nixpkgs.lib.mapAttrsToList (name: test: "ln -s ${test} $out/${nixpkgs.lib.escapeShellArg name}") aarch64TestResults)}
      '';
      dohUpstreamTest = import ./tests/doh-upstream.nix {
        inherit nixpkgs pkgs commonDesktopModule stateVersion dohStamps;
      };
      dohCaptiveTest = import ./tests/doh-captive.nix {
        inherit nixpkgs pkgs commonDesktopModule stateVersion;
      };
      nmCaptivePortalTest = import ./tests/nm-captive-portal.nix {
        inherit nixpkgs pkgs commonDesktopModule stateVersion;
      };
      nmCaptivePortalIpv6Test = import ./tests/nm-captive-portal-ipv6.nix {
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
        gcOptions = "--delete-older-than 14d";
      };
      autoUpgradeMockedServiceTest = import ./tests/auto-upgrade-mocked-service.nix {
        autoUpgradeModule = ./modules/auto-upgrade.nix;
        flakeRef = "/etc/nixos#laptop";
        inherit nixpkgs pkgs stateVersion;
      };
      zramTest = import ./tests/zram.nix {
        inherit nixpkgs pkgs stateVersion;
        machineModule = ./modules/laptop-base.nix;
      };
      nixGcRetentionTest = import ./tests/nix-gc-retention.nix {
        inherit nixpkgs pkgs stateVersion;
        # The real laptop config (common-desktop imports nix-settings -> 14d default).
        machineModule = { ... }: {
          imports = [ commonDesktopModule ];
          common.monitoring.enable = false;
        };
        keptAfterGc = 14;  # --delete-older-than 14d: ~14 days of history kept under daily GC
      };
      testResults = builtins.mapAttrs (_: dropKvm) ({
        auto-upgrade-mocked-service = autoUpgradeMockedServiceTest;
        common-desktop = commonDesktopTest;
        doh = dohTest;
        doh-upstream = dohUpstreamTest;
        doh-captive = dohCaptiveTest;
        nm-captive-portal = nmCaptivePortalTest;
        nm-captive-portal-ipv6 = nmCaptivePortalIpv6Test;
        firewall = firewallTest;
        locale-firefox = localeFirefoxTest;
        monitoring-auto-upgrade = monitoringAutoUpgradeTest;
        monitoring-disk-space = monitoringDiskSpaceTest;
        monitoring-generations = monitoringGenerationsTest;
        monitoring-reporting = monitoringReportingTest;
        monitoring-restic = monitoringResticTest;
        nix-settings = nixSettingsTest;
        nix-gc-retention = nixGcRetentionTest;
        plasma-firefox = plasmaFirefoxTest;
        restic = resticTest;
        zram = zramTest;
      } // (nixpkgs.lib.mapAttrs'
        (name: test: nixpkgs.lib.nameValuePair "nix-utils-${name}" test)
        nixUtilsTests));
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
        doh = ./modules/doh.nix;
        restic = ./modules/restic.nix;
      };

      lib.restic = resticLib;
      lib.mkRpi5 = mkRpi5;

      legacyPackages.${system} = pkgs;

      nixosConfigurations = {
        qemu-graphical = qemuGraphical;
      };

      checks.${system} = testResults;
      checks.aarch64-linux = aarch64TestResults;
      packages.aarch64-linux.rpi-all-tests = rpiAllTests;

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
        nm-captive-portal-ipv6-driver = nmCaptivePortalIpv6Test.driver;
        nm-captive-portal-ipv6-driver-interactive = nmCaptivePortalIpv6Test.driverInteractive;
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
