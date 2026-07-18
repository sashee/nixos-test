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
      commonDesktopHostModule = { ... }: {
        imports = [ ./modules/common-desktop.nix ];
        _module.args.commonDotfiles = dotfiles;
        _module.args.unstable = unstable;
      };
      # VM-test guest clock: tomorrow at 10:00 UTC, computed when the VM starts
      # (qemu-vm.nix splices options unescaped into the start script, so the $()
      # runs at launch; the derivation string itself is constant). Always 10-34h
      # ahead of real time: past systemd's built-in epoch, past the notBefore of
      # build-time-generated test certs (tests/test-cert.nix mints CAs with the
      # real clock, so a base in the past fails their validation), and pinned to
      # 10:00 so no host timer slot (nix-gc at 03:15/15:15) can elapse mid-test.
      # The coreutils must match the platform the test driver runs on.
      testRtcBase = coreutils:
        "-rtc base=$(${coreutils}/bin/date -u -d tomorrow +%Y-%m-%dT10:00:00)";
      # The desktop config as a VM-test node; all tests use this variant so the
      # real host timers (nix-gc, ...) stay enabled but can never elapse mid-test.
      commonDesktopModule = { ... }: {
        imports = [ commonDesktopHostModule ];
        virtualisation.qemu.options = [ (testRtcBase pkgs.coreutils) ];
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
            common.irohSsh.enable = false;
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
      # Laptop hosts: config lives in-repo; the machine-unique parts (LUKS
      # device, filesystems) stay on the device in hardware-configuration.nix.
      # The on-device stub flake builds the deployable system with
      #   common.lib.hosts.anya-feher-laptop { modules = [ ./hardware-configuration.nix ]; }
      mkAnyaFeherLaptop = { modules ? [ ] }: nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./hosts/anya-feher-laptop/configuration.nix
          {
            _module.args.commonDotfiles = dotfiles;
            _module.args.unstable = unstable;
          }
        ] ++ modules;
      };
      qemuGraphical = nixpkgs.lib.nixosSystem {
        inherit system;

        modules = [
          "${nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
          commonDesktopHostModule
          qemuDemoUserModule

          {
            system.stateVersion = stateVersion;

            networking.hostName = "nixos-qemu";

            common.locale.default = "hu_HU.UTF-8";
            common.autoUpgrade.enable = false;
            common.monitoring.enable = false;
            # iroh SSH tunnel: enabled with a credential dir, but the key is
            # provisioned live in the running VM, not baked into the image.
            common.irohSsh.credentialDirectory = "/etc/credentials/iroh-ssh";

            virtualisation = {
              cores = 6;
              graphics = true;
              memorySize = 8192;
            };
          }
        ];
      };
      qemuVm = qemuGraphical.config.system.build.vm;
      # The real anya-feher-laptop config bootable in a local QEMU window;
      # qemu-vm.nix stands in for the on-device hardware config. Upgrade and
      # monitoring off like qemu-graphical (the VM has no /etc/nixos flake or
      # credentials); iroh-ssh skips on its missing credential as on first boot.
      anyaFeherLaptopQemuVm = (mkAnyaFeherLaptop {
        modules = [
          "${nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
          {
            common.autoUpgrade.enable = false;
            common.monitoring.enable = false;
            # VM-only: anya's real password is imperative state a fresh VM
            # image doesn't have, which would make the inactivity lock a dead end.
            users.users.anya.initialPassword = "anya";
            virtualisation = {
              cores = 6;
              graphics = true;
              memorySize = 8192;
            };
          }
        ];
      }).config.system.build.vm;
      plasmaFirefoxTest = import ./tests/plasma-firefox.nix {
        inherit nixpkgs pkgs commonDesktopModule qemuDemoUserModule stateVersion;
        user = "demo";
      };
      commonDesktopTest = import ./tests/common-desktop.nix {
        inherit nixpkgs pkgs commonDesktopModule qemuDemoUserModule stateVersion;
      };
      localeFirefoxTest = import ./tests/locale-firefox.nix {
        inherit nixpkgs pkgs commonDesktopModule qemuDemoUserModule stateVersion;
        user = "demo";
      };
      firewallTest = import ./tests/firewall.nix {
        inherit nixpkgs pkgs stateVersion;
        machineModule = commonDesktopModule;
      };
      dohTest = import ./tests/doh.nix {
        inherit nixpkgs pkgs stateVersion;
        machineModule = { ... }: {
          imports = [ commonDesktopModule ];
          common.autoUpgrade.enable = false;
          common.monitoring.enable = false;
          common.irohSsh.enable = false;
        };
      };

      # aarch64 Raspberry Pi 5 check: exercise the doh module on the exact kernel
      # and nixpkgs the Pi runs, in an aarch64 VM (KVM-accelerated on the Pi itself,
      # slow TCG on the KVM-less aarch64 CI runner).
      nixrpi = nixos-raspberrypi.inputs.nixpkgs;
      pkgsRpi = nixrpi.legacyPackages.aarch64-linux;
      rpi5Base = mkRpi5 { };
      # Boot rpi tests on the EXACT rpi kernel. QEMU's virt machine needs the generic
      # ECAM PCIe host bridge (a DT-bound module) force-loaded; virtio + 9p then autoload.
      # rtc-pl031 (QEMU virt's RTC) must probe in the initrd so HCTOSYS sets the clock
      # before stage-2 timer units start: left to udev it can land minutes into a TCG
      # boot, and that late clock jump wakes Persistent timers (nix-gc) mid-test.
      rpiTestKernel = { lib, ... }: {
        boot.kernelPackages = lib.mkForce rpi5Base.config.boot.kernelPackages;
        boot.kernelPatches = lib.mkForce [ ];
        boot.initrd.kernelModules = [ "pci_host_generic" "rtc-pl031" ];
        virtualisation.qemu.options = [ (testRtcBase pkgsRpi.coreutils) ];
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
      monitoringTestRpi = import ./tests/monitoring/rpi.nix {
        nixpkgs = nixrpi;
        pkgs = pkgsRpi;
        stateVersion = rpi5Base.config.system.stateVersion;
        machineModule = rpiSystemModule;
      };
      monitoringNixGcTestRpi = import ./tests/monitoring/nix-gc.nix {
        nixpkgs = nixrpi;
        pkgs = pkgsRpi;
        stateVersion = rpi5Base.config.system.stateVersion;
      };
      # Like monitoring-nix-gc: a unit test with no host input, run here because
      # the rpi suite evaluates against a different nixpkgs than the x86 one.
      monitoringIrohSshTestRpi = import ./tests/monitoring/iroh-ssh.nix {
        nixpkgs = nixrpi;
        pkgs = pkgsRpi;
        stateVersion = rpi5Base.config.system.stateVersion;
      };
      # Tests that plainly disable common.* toggles conflict with the rpi
      # config's explicit autoUpgrade.enable = true; the force-off masks both
      # normal-priority definitions (see connectivityFallbackTestRpi).
      rpiQuiescedSystemModule = { lib, ... }: {
        imports = [ rpiSystemModule ];
        common.autoUpgrade.enable = lib.mkForce false;
        common.monitoring.enable = lib.mkForce false;
      };
      dohUpstreamTestRpi = import ./tests/doh-upstream.nix {
        nixpkgs = nixrpi;
        pkgs = pkgsRpi;
        stateVersion = rpi5Base.config.system.stateVersion;
        commonDesktopModule = rpiQuiescedSystemModule;
        inherit dohStamps;
      };
      resticTestRpi = import ./tests/restic.nix {
        nixpkgs = nixrpi;
        pkgs = pkgsRpi;
        stateVersion = rpi5Base.config.system.stateVersion;
        commonDesktopModule = rpiQuiescedSystemModule;
      };
      # The dotfiles nix-utils suite on the real rpi config and kernel as the
      # real Pi user: the sandbox cases (userns/seccomp/bubblewrap) are
      # kernel-dependent, and the Pi runs a custom trimmed kernel.
      rpiNixUtilsTests = import "${dotfiles}/nix-utils/tests/lib.nix" {
        pkgs = pkgsRpi;
        machineModules = [
          rpiSystemModule
          {
            # The suite sets no node hostName; without one the rpi config's
            # mkDefault ties with the test framework's mkDefault "machine".
            networking.hostName = "nix-utils-test";
            system.stateVersion = rpi5Base.config.system.stateVersion;
            # 2 GiB, not the 4 GiB the generic wiring inherits from
            # qemu-demo-user.nix: these checks also run on the 4 GiB Pi itself.
            virtualisation.memorySize = nixpkgs.lib.mkDefault 2048;
            common.autoUpgrade.enable = nixpkgs.lib.mkForce false;
            common.monitoring.enable = nixpkgs.lib.mkForce false;
            common.irohSsh.enable = nixpkgs.lib.mkForce false;
          }
        ];
        user = "nixos";
      };
      # The REAL rpi system config as the node (exact Pi kernel, which ships
      # mac80211_hwsim -- verified 6.18.34 -- and carries the tpm-crb initrd
      # workaround). Only what cannot work in a VM is disabled: auto-upgrade
      # (needs /etc/nixos) and monitoring (needs credentials; 30-min timer would
      # fire mid-test). The rest of the deployed stack stays live.
      connectivityFallbackTestRpi = import ./tests/connectivity-fallback.nix {
        nixpkgs = nixrpi;
        pkgs = pkgsRpi;
        stateVersion = rpi5Base.config.system.stateVersion;
        machineModule = { lib, ... }: {
          imports = [ rpiSystemModule ];
          common.autoUpgrade.enable = lib.mkForce false;
          common.monitoring.enable = lib.mkForce false;
        };
      };
      firewallTestRpi = import ./tests/firewall.nix {
        nixpkgs = nixrpi;
        pkgs = pkgsRpi;
        stateVersion = rpi5Base.config.system.stateVersion;
        machineModule = rpiSystemModule;
      };
      irohSshTestRpi = import ./tests/iroh-ssh.nix {
        nixpkgs = nixrpi;
        pkgs = pkgsRpi;
        stateVersion = rpi5Base.config.system.stateVersion;
        machineModule = rpiSystemModule;
        inherit dohStamps;
      };
      bootClockTestRpi = import ./tests/boot-clock.nix {
        nixpkgs = nixrpi;
        pkgs = pkgsRpi;
        stateVersion = rpi5Base.config.system.stateVersion;
        machineModule = rpiSystemModule;
      };
      # Nix only exposes /dev/kvm in the sandbox based on the daemon's system-features
      # (auto-set from the host's /dev/kvm), NOT a derivation's requiredSystemFeatures.
      # So dropping the kvm *requirement* lets tests schedule on KVM-less builders (the
      # free aarch64 CI runner) while QEMU's accel=kvm:tcg still uses KVM wherever it
      # exists (x86 runner, and the Pi itself: the rpi5 kernel ships KVM), falling
      # back to slow TCG only where /dev/kvm is missing (the aarch64 CI runner).
      dropKvm = test: test.overrideTestDerivation (old: {
        requiredSystemFeatures = builtins.filter (f: f != "kvm") old.requiredSystemFeatures;
      });
      # All aarch64 (Raspberry Pi 5) checks in one place. Add new rpi tests here;
      # CI builds the aggregate below, so the workflow never needs editing.
      aarch64TestResults = builtins.mapAttrs (_: dropKvm) ({
        doh = dohTestRpi;
        doh-upstream = dohUpstreamTestRpi;
        auto-upgrade = autoUpgradeTestRpi;
        nix-settings = nixSettingsTestRpi;
        auto-upgrade-reboot = autoUpgradeRebootTestRpi;
        zram = zramTestRpi;
        nix-gc-retention = nixGcRetentionTestRpi;
        monitoring = monitoringTestRpi;
        connectivity-fallback = connectivityFallbackTestRpi;
        monitoring-nix-gc = monitoringNixGcTestRpi;
        monitoring-iroh-ssh = monitoringIrohSshTestRpi;
        firewall = firewallTestRpi;
        iroh-ssh = irohSshTestRpi;
        restic = resticTestRpi;
        boot-clock = bootClockTestRpi;
      } // (nixpkgs.lib.mapAttrs'
        (name: test: nixpkgs.lib.nameValuePair "nix-utils-${name}" test)
        rpiNixUtilsTests)) // {
        # Pure build check, no VM: every module in hosts/rpi5/required-modules.txt
        # exists in the Pi kernel (see modules/required-kernel-modules.nix). Kept
        # outside the dropKvm mapAttrs since it isn't a runTest derivation.
        required-kernel-modules = rpi5Base.config.system.build.requiredKernelModulesCheck;
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
      nmCaptivePortalIpv6Test = import ./tests/nm-captive-portal-ipv6.nix {
        inherit nixpkgs pkgs commonDesktopModule stateVersion;
      };
      resticTest = import ./tests/restic.nix {
        inherit nixpkgs pkgs commonDesktopModule stateVersion;
      };
      irohSshTest = import ./tests/iroh-ssh.nix {
        inherit nixpkgs pkgs stateVersion dohStamps;
        machineModule = commonDesktopModule;
      };
      monitoringAutoUpgradeTest = import ./tests/monitoring/auto-upgrade.nix {
        inherit nixpkgs pkgs commonDesktopModule stateVersion;
      };
      monitoringDiskSpaceTest = import ./tests/monitoring/disk-space.nix {
        inherit nixpkgs pkgs commonDesktopModule stateVersion;
      };
      monitoringGenerationsTest = import ./tests/monitoring/generations.nix {
        inherit nixpkgs pkgs commonDesktopModule stateVersion;
      };
      monitoringReportingTest = import ./tests/monitoring/reporting.nix {
        inherit nixpkgs pkgs commonDesktopModule stateVersion;
      };
      monitoringResticTest = import ./tests/monitoring/restic.nix {
        inherit nixpkgs pkgs commonDesktopModule stateVersion;
      };
      monitoringNixGcTest = import ./tests/monitoring/nix-gc.nix {
        inherit nixpkgs pkgs stateVersion;
      };
      monitoringIrohSshTest = import ./tests/monitoring/iroh-ssh.nix {
        inherit nixpkgs pkgs stateVersion;
      };
      nixSettingsTest = import ./tests/nix-settings.nix {
        inherit nixpkgs pkgs stateVersion;
        gcOptions = "--delete-older-than 14d";
      };
      autoUpgradeMockedServiceTest = import ./tests/auto-upgrade-mocked-service.nix {
        autoUpgradeModule = ./modules/auto-upgrade.nix;
        flakeRef = "/etc/nixos#laptop";
        # Run against the real laptop stack (like the rpi/anya variants use their
        # host configs), not a bare module node -- so it exercises the deployed
        # config and inherits the laptop-base initrd RTC fix.
        nodeModule = { ... }: {
          imports = [ commonDesktopModule ];
          common.monitoring.enable = false;
          common.irohSsh.enable = false;
        };
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
          common.irohSsh.enable = false;
        };
        keptAfterGc = 14;  # --delete-older-than 14d: ~14 days of history kept under daily GC
      };
      # No real image exists for x86 (the deployed system is aarch64-only), so
      # this variant runs on a minimal module+firewall node.
      connectivityFallbackTest = import ./tests/connectivity-fallback.nix {
        inherit nixpkgs pkgs stateVersion;
        machineModule = { ... }: {
          imports = [ ./modules/connectivity-fallback.nix ./modules/firewall.nix ];
        };
      };
      # icount concept test: production timer constants under TCG time-warp.
      connectivityFallbackTimingTest = import ./tests/connectivity-fallback-timing.nix {
        inherit nixpkgs pkgs stateVersion;
        moduleUnderTest = ./modules/connectivity-fallback.nix;
      };
      # The real anya-feher-laptop host config as a test node (mirrors
      # rpiSystemModule; plain x86, so no kernel neutralization is needed).
      # Feature tests run against it so a host-config change that breaks a
      # feature fails that feature's -anya variant.
      anyaFeherLaptopSystemModule = { ... }: {
        imports = [ ./hosts/anya-feher-laptop/configuration.nix ];
        _module.args.commonDotfiles = dotfiles;
        _module.args.unstable = unstable;
        virtualisation.qemu.options = [ (testRtcBase pkgs.coreutils) ];
      };
      # Eval-only smoke check: force full evaluation (assertions included) of
      # the deployable system with a stand-in hardware config, so a broken host
      # config fails CI instead of the laptop's next auto-upgrade. The context
      # discard keeps the check from depending on (= building) the system.
      anyaFeherLaptopEval =
        let
          stubHw = {
            fileSystems."/" = {
              device = "/dev/disk/by-label/nixos";
              fsType = "ext4";
            };
          };
          toplevel = (mkAnyaFeherLaptop { modules = [ stubHw ]; }).config.system.build.toplevel;
        in
        pkgs.runCommand "anya-feher-laptop-eval" { } ''
          echo ${nixpkgs.lib.escapeShellArg (builtins.unsafeDiscardStringContext toplevel.drvPath)} > $out
        '';
      anyaFeherLaptopTest = import ./tests/anya-feher-laptop.nix {
        inherit nixpkgs pkgs stateVersion;
        machineModule = anyaFeherLaptopSystemModule;
      };
      anyaFeherLaptopDohTest = import ./tests/doh.nix {
        inherit nixpkgs pkgs stateVersion;
        machineModule = { ... }: {
          imports = [ anyaFeherLaptopSystemModule ];
          common.autoUpgrade.enable = false;
          common.monitoring.enable = false;
          common.irohSsh.enable = false;
        };
      };
      anyaFeherLaptopDohUpstreamTest = import ./tests/doh-upstream.nix {
        inherit nixpkgs pkgs stateVersion dohStamps;
        commonDesktopModule = anyaFeherLaptopSystemModule;
      };
      anyaFeherLaptopDohCaptiveTest = import ./tests/doh-captive.nix {
        inherit nixpkgs pkgs stateVersion;
        commonDesktopModule = anyaFeherLaptopSystemModule;
      };
      anyaFeherLaptopFirewallTest = import ./tests/firewall.nix {
        inherit nixpkgs pkgs stateVersion;
        machineModule = anyaFeherLaptopSystemModule;
      };
      anyaFeherLaptopIrohSshTest = import ./tests/iroh-ssh.nix {
        inherit nixpkgs pkgs stateVersion dohStamps;
        machineModule = anyaFeherLaptopSystemModule;
      };
      anyaFeherLaptopZramTest = import ./tests/zram.nix {
        inherit nixpkgs pkgs stateVersion;
        machineModule = anyaFeherLaptopSystemModule;
      };
      anyaFeherLaptopMonitoringAutoUpgradeTest = import ./tests/monitoring/auto-upgrade.nix {
        inherit nixpkgs pkgs stateVersion;
        commonDesktopModule = anyaFeherLaptopDesktopNode;
      };
      anyaFeherLaptopMonitoringDiskSpaceTest = import ./tests/monitoring/disk-space.nix {
        inherit nixpkgs pkgs stateVersion;
        commonDesktopModule = anyaFeherLaptopDesktopNode;
      };
      anyaFeherLaptopMonitoringGenerationsTest = import ./tests/monitoring/generations.nix {
        inherit nixpkgs pkgs stateVersion;
        commonDesktopModule = anyaFeherLaptopDesktopNode;
      };
      anyaFeherLaptopMonitoringReportingTest = import ./tests/monitoring/reporting.nix {
        inherit nixpkgs pkgs stateVersion;
        commonDesktopModule = anyaFeherLaptopDesktopNode;
      };
      anyaFeherLaptopMonitoringResticTest = import ./tests/monitoring/restic.nix {
        inherit nixpkgs pkgs stateVersion;
        commonDesktopModule = anyaFeherLaptopDesktopNode;
      };
      # flakeRef must equal the host's common.autoUpgrade.flake: the test sets
      # it too, and equal definitions merge while different ones conflict.
      anyaFeherLaptopAutoUpgradeTest = import ./tests/auto-upgrade-mocked-service.nix {
        inherit nixpkgs pkgs stateVersion;
        autoUpgradeModule = ./modules/auto-upgrade.nix;
        nodeModule = anyaFeherLaptopSystemModule;
        flakeRef = "/etc/nixos#anya-feher-laptop";
      };
      anyaFeherLaptopNixSettingsTest = import ./tests/nix-settings.nix {
        inherit nixpkgs pkgs stateVersion;
        extraModule = anyaFeherLaptopSystemModule;
        gcOptions = "--delete-older-than 14d";
      };
      anyaFeherLaptopNixGcRetentionTest = import ./tests/nix-gc-retention.nix {
        inherit nixpkgs pkgs stateVersion;
        machineModule = anyaFeherLaptopSystemModule;
        keptAfterGc = 14;  # spec: generations are kept for 14 days
      };
      anyaFeherLaptopNmCaptivePortalTest = import ./tests/nm-captive-portal.nix {
        inherit nixpkgs pkgs stateVersion;
        commonDesktopModule = anyaFeherLaptopSystemModule;
      };
      anyaFeherLaptopNmCaptivePortalIpv6Test = import ./tests/nm-captive-portal-ipv6.nix {
        inherit nixpkgs pkgs stateVersion;
        commonDesktopModule = anyaFeherLaptopSystemModule;
      };
      anyaFeherLaptopResticTest = import ./tests/restic.nix {
        inherit nixpkgs pkgs stateVersion;
        commonDesktopModule = anyaFeherLaptopSystemModule;
      };
      anyaFeherLaptopBootClockTest = import ./tests/boot-clock.nix {
        inherit nixpkgs pkgs stateVersion;
        machineModule = anyaFeherLaptopSystemModule;
      };
      # Spec: "do not reboot automatically, takes effect on next manual reboot" --
      # same mocked kernel-changing upgrade as the rpi's reboot test, opposite assertion.
      anyaFeherLaptopAutoUpgradeNoRebootTest = import ./tests/auto-upgrade-reboot.nix {
        inherit nixpkgs pkgs stateVersion;
        machineModule = anyaFeherLaptopSystemModule;
        expectReboot = false;
      };
      # The real anya host config with desktop-adequate VM sizing (the generic
      # variants get this from qemu-demo-user.nix, which host variants don't
      # import). Purely virtualisation.* resources -- no config change, so the
      # system under test is still the real config. Used by every anya node that
      # boots the full autologin desktop under a heavy wait (monitoring, restic,
      # plasma/locale firefox, nix-utils). Timezone-adaptive tests (fire_timer)
      # handle anya's Europe/Budapest, so no UTC pin or headless variant.
      anyaFeherLaptopDesktopNode = { lib, ... }: {
        imports = [ anyaFeherLaptopSystemModule ];
        virtualisation.cores = lib.mkDefault 2;
        virtualisation.memorySize = lib.mkDefault 4096;
      };
      anyaFeherLaptopPlasmaFirefoxTest = import ./tests/plasma-firefox.nix {
        inherit nixpkgs pkgs stateVersion;
        commonDesktopModule = anyaFeherLaptopDesktopNode;
        user = "anya";
      };
      anyaFeherLaptopLocaleFirefoxTest = import ./tests/locale-firefox.nix {
        inherit nixpkgs pkgs stateVersion;
        commonDesktopModule = anyaFeherLaptopDesktopNode;
        user = "anya";
      };
      # Same dotfiles suite as the generic nix-utils checks, on the real host
      # config as the real primary user (the suite needs no sudo).
      anyaFeherLaptopNixUtilsTests = import "${dotfiles}/nix-utils/tests/lib.nix" {
        inherit pkgs;
        machineModules = [
          anyaFeherLaptopDesktopNode
          {
            # The suite sets no node hostName; without one the host config's
            # mkDefault ties with the test framework's mkDefault "machine".
            networking.hostName = "nix-utils-test";
            system.stateVersion = stateVersion;
            common.autoUpgrade.enable = false;
            common.monitoring.enable = false;
            common.irohSsh.enable = false;
          }
        ];
        user = "anya";
      };
      # The host's own check set (host-name-prefixed): runs in its own parallel
      # CI job via `make run-host-tests HOST=anya-feher-laptop`, separate from
      # the generic x86 tests -- same isolation the rpi set gets from being a
      # different system. Also merged into checks.x86_64-linux so local
      # `nix build .#checks...` and `nix flake check` see everything.
      anyaFeherLaptopChecks = builtins.mapAttrs (_: dropKvm) ({
        anya-feher-laptop = anyaFeherLaptopTest;
        anya-feher-laptop-doh = anyaFeherLaptopDohTest;
        anya-feher-laptop-doh-upstream = anyaFeherLaptopDohUpstreamTest;
        anya-feher-laptop-doh-captive = anyaFeherLaptopDohCaptiveTest;
        anya-feher-laptop-firewall = anyaFeherLaptopFirewallTest;
        anya-feher-laptop-iroh-ssh = anyaFeherLaptopIrohSshTest;
        anya-feher-laptop-zram = anyaFeherLaptopZramTest;
        anya-feher-laptop-monitoring-auto-upgrade = anyaFeherLaptopMonitoringAutoUpgradeTest;
        anya-feher-laptop-monitoring-disk-space = anyaFeherLaptopMonitoringDiskSpaceTest;
        anya-feher-laptop-monitoring-generations = anyaFeherLaptopMonitoringGenerationsTest;
        anya-feher-laptop-monitoring-reporting = anyaFeherLaptopMonitoringReportingTest;
        anya-feher-laptop-monitoring-restic = anyaFeherLaptopMonitoringResticTest;
        anya-feher-laptop-auto-upgrade = anyaFeherLaptopAutoUpgradeTest;
        anya-feher-laptop-auto-upgrade-no-reboot = anyaFeherLaptopAutoUpgradeNoRebootTest;
        anya-feher-laptop-nix-settings = anyaFeherLaptopNixSettingsTest;
        anya-feher-laptop-nix-gc-retention = anyaFeherLaptopNixGcRetentionTest;
        anya-feher-laptop-nm-captive-portal = anyaFeherLaptopNmCaptivePortalTest;
        anya-feher-laptop-nm-captive-portal-ipv6 = anyaFeherLaptopNmCaptivePortalIpv6Test;
        anya-feher-laptop-restic = anyaFeherLaptopResticTest;
        anya-feher-laptop-boot-clock = anyaFeherLaptopBootClockTest;
        anya-feher-laptop-plasma-firefox = anyaFeherLaptopPlasmaFirefoxTest;
        anya-feher-laptop-locale-firefox = anyaFeherLaptopLocaleFirefoxTest;
      } // (nixpkgs.lib.mapAttrs'
        (name: test: nixpkgs.lib.nameValuePair "anya-feher-laptop-nix-utils-${name}" test)
        anyaFeherLaptopNixUtilsTests)) // {
        # Eval-only runCommand, not a VM test: no kvm feature to drop.
        anya-feher-laptop-eval = anyaFeherLaptopEval;
      };
      testResults = builtins.mapAttrs (_: dropKvm) ({
        auto-upgrade-mocked-service = autoUpgradeMockedServiceTest;
        common-desktop = commonDesktopTest;
        doh = dohTest;
        doh-upstream = dohUpstreamTest;
        iroh-ssh = irohSshTest;
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
        monitoring-nix-gc = monitoringNixGcTest;
        monitoring-iroh-ssh = monitoringIrohSshTest;
        nix-settings = nixSettingsTest;
        nix-gc-retention = nixGcRetentionTest;
        plasma-firefox = plasmaFirefoxTest;
        restic = resticTest;
        connectivity-fallback = connectivityFallbackTest;
        connectivity-fallback-timing = connectivityFallbackTimingTest;
        zram = zramTest;
      } // (nixpkgs.lib.mapAttrs'
        (name: test: nixpkgs.lib.nameValuePair "nix-utils-${name}" test)
        nixUtilsTests));
    in
    {
      nixosModules = {
        auto-upgrade = ./modules/auto-upgrade.nix;
        common-desktop = commonDesktopHostModule;
        doh = ./modules/doh.nix;
        restic = ./modules/restic.nix;
      };

      lib.restic = resticLib;
      lib.hosts.rpi5 = mkRpi5;
      lib.hosts.anya-feher-laptop = mkAnyaFeherLaptop;
      # Named check sets for the Makefile's run-checks (SET=...): the generic
      # x86 suite and one set per laptop host, each run by its own CI job.
      lib.checkSets = {
        generic-x86 = testResults;
        anya-feher-laptop = anyaFeherLaptopChecks;
      };

      legacyPackages.${system} = pkgs;

      nixosConfigurations = {
        qemu-graphical = qemuGraphical;
      };

      checks.${system} = testResults // anyaFeherLaptopChecks;
      checks.aarch64-linux = aarch64TestResults;
      # The exact patched kernel every rpi check boots (rpiTestKernel pins the
      # node to this package, so the outPath matches the checks). CI exports its
      # closure as the rpi-kernel-cache artifact; `make import-rpi-kernel` loads
      # it into a laptop's store so local rpi test runs skip the kernel compile.
      packages.aarch64-linux.rpi-test-kernel = rpi5Base.config.boot.kernelPackages.kernel;

      packages.${system} = {
        default = qemuVm;
        iroh-ssh = pkgs.callPackage ./packages/iroh-ssh/package.nix { };
        auto-upgrade-mocked-service-driver = autoUpgradeMockedServiceTest.driver;
        auto-upgrade-mocked-service-driver-interactive = autoUpgradeMockedServiceTest.driverInteractive;
        common-desktop-driver = commonDesktopTest.driver;
        common-desktop-driver-interactive = commonDesktopTest.driverInteractive;
        doh-driver = dohTest.driver;
        doh-driver-interactive = dohTest.driverInteractive;
        iroh-ssh-driver = irohSshTest.driver;
        iroh-ssh-driver-interactive = irohSshTest.driverInteractive;
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
        monitoring-nix-gc-driver = monitoringNixGcTest.driver;
        monitoring-nix-gc-driver-interactive = monitoringNixGcTest.driverInteractive;
        monitoring-iroh-ssh-driver = monitoringIrohSshTest.driver;
        monitoring-iroh-ssh-driver-interactive = monitoringIrohSshTest.driverInteractive;
        nix-settings-driver = nixSettingsTest.driver;
        nix-settings-driver-interactive = nixSettingsTest.driverInteractive;
        qemu-vm = qemuVm;
        anya-feher-laptop-vm = anyaFeherLaptopQemuVm;
        plasma-firefox-driver = plasmaFirefoxTest.driver;
        plasma-firefox-driver-interactive = plasmaFirefoxTest.driverInteractive;
        restic-driver = resticTest.driver;
        restic-driver-interactive = resticTest.driverInteractive;
        zram-driver = zramTest.driver;
        zram-driver-interactive = zramTest.driverInteractive;
      } // nixUtilsTestDrivers;
    };
}
