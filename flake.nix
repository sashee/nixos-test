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
    # OTLP measurement receiver for the Pi (unix socket only). Deliberately not a
    # flake, and consumed like dotfiles: nix/module.nix is a plain NixOS module and
    # nix/package.nix a plain callPackage, so the service is built with the target
    # system's own nixpkgs instead of a second pinned one nothing here deploys.
    monitoring-platform = {
      url = "github:sashee/monitoring-platform";
      flake = false;
    };
  };

  outputs = { nixpkgs, nixpkgs-unstable, dotfiles, nixos-raspberrypi, monitoring-platform, ... }:
    let
      system = "x86_64-linux";
      stateVersion = nixpkgs.lib.trivial.release;
      pkgs = nixpkgs.legacyPackages.${system};
      unstable = import nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      };
      commonDesktopHostModule = { config, ... }: {
        imports = [
          timeSyncSettings
          ./modules/common-desktop.nix
          # TEMPORARY. The measurement receiver is a Pi feature; it is composed in here so the
          # x86 desktop config has one too, which is what lets the system-metrics producer be
          # tested in a fast x86 VM instead of only under aarch64 TCG. Deliberately NOT in
          # hosts/anya-feher-laptop/configuration.nix: that host composes its own module list
          # (anyaFeherLaptopHostModule) and so is untouched by this.
          "${monitoring-platform}/nix/module.nix"
        ];
        _module.args.commonDotfiles = dotfiles;
        _module.args.unstable = unstable;

        services.monitoring-platform.enable = true;
        common.systemMetrics = {
          enable = true;
          socketPath = config.services.monitoring-platform.socketPath;
          group = config.services.monitoring-platform.group;
        };
      };
      # Turning time synchronisation on, for every host that does. `floor` is the reason this
      # lives in flake.nix rather than in each host config: it is the bound on how far back a
      # compromised provider could roll the clock, so it has to be a build-time constant, and
      # `nixpkgs.lastModified` is the one in scope here (tests/restic.nix already uses it as a
      # clock base for the same reason).
      timeSyncSettings = {
        common.timeSync = {
          enable = true;
          floor = nixpkgs.lastModified;
        };
      };
      # The counterpart to qemu-vm.nix's `services.timesyncd.enable = false` ("Don't run ntpd
      # in the guest. It should get the correct time from KVM."). That line neutralises the
      # stock time daemon on every test node; chrony is now the time daemon, so without the
      # same treatment every VM test acquires a daemon -- and a rough-time unit retrying
      # forever against a network with no providers -- that argues with the ~10 tests which
      # drive the clock with `date -s`.
      #
      # Priority 90 rather than mkForce: it has to beat the host config's normal-priority
      # `enable = true`, while leaving mkForce free for the two tests that are ABOUT time and
      # must switch it back on.
      testNodeTimeSyncOff = { lib, ... }: {
        common.timeSync.enable = lib.mkOverride 90 false;
      };
      # VM-test guest clock: tomorrow at 10:00 UTC. See lib/test-rtc-base.nix for why, and
      # for why it is a file rather than a binding here (a test file needs it for a helper
      # node that must share the clock of the node under test).
      testRtcBase = import ./lib/test-rtc-base.nix;
      # The desktop config as a VM-test node; all tests use this variant so the
      # real host timers (nix-gc, ...) stay enabled but can never elapse mid-test.
      commonDesktopModule = { ... }: {
        imports = [ commonDesktopHostModule testNodeTimeSyncOff ];
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
      dohStamps = import ./lib/doh-stamps.nix { lib = nixpkgs.lib; };
      ntsServers = import ./lib/nts-servers.nix { lib = nixpkgs.lib; };
      resticLib = import ./lib/restic.nix { lib = nixpkgs.lib; };
      # Everything that makes up the rpi5 host config: the config itself plus the
      # external modules whose options it sets. Those cannot be imported from the host
      # config -- an `imports` entry has to be resolvable before module arguments
      # exist, so a specialArg would be needed on every path that evaluates hosts/rpi5,
      # including the test nodes, which cannot pass one through the upstream VM
      # harness. Every consumer composes this list instead (mkRpi5 for the deployed
      # system, rpiNodeBase for the test nodes), so no path can lose a declaration.
      rpi5HostModules = [
        "${monitoring-platform}/nix/module.nix"
        timeSyncSettings
        ./hosts/rpi5/configuration.nix
      ];
      mkRpi5 = { modules ? [ ] }: nixos-raspberrypi.lib.nixosSystem {
        trustCaches = false;
        specialArgs = {
          inherit dotfiles nixpkgs-unstable;
          nixpkgs-stable = nixpkgs;
        };
        modules = [
          nixos-raspberrypi.nixosModules.sd-image
          ({ ... }: { imports = with nixos-raspberrypi.nixosModules; [ raspberry-pi-5.base ]; })
        ] ++ rpi5HostModules ++ modules;
      };
      # Laptop hosts: config lives in-repo; the machine-unique parts (LUKS
      # device, filesystems) stay on the device in hardware-configuration.nix.
      # The on-device stub flake builds the deployable system with
      #   common.lib.hosts.anya-feher-laptop { modules = [ ./hardware-configuration.nix ]; }
      # The host config plus the module args it needs, as one module -- the same shape
      # as commonDesktopHostModule above. Both the deployed system (mkAnyaFeherLaptop)
      # and the test node (anyaFeherLaptopSystemModule) compose this, so neither path
      # can drift from the other or lose an arg. External modules whose options the
      # host config sets belong in this imports list too, for the reason spelled out
      # on rpi5HostModules.
      anyaFeherLaptopHostModule = { ... }: {
        imports = [ ./hosts/anya-feher-laptop/configuration.nix timeSyncSettings ];
        _module.args.commonDotfiles = dotfiles;
        _module.args.unstable = unstable;
      };
      mkAnyaFeherLaptop = { modules ? [ ] }: nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ anyaFeherLaptopHostModule ] ++ modules;
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
      # Kernel pinning only, no -rtc: that lives in rpiSystemModule below. See
      # rpiNodeBase for why the two are separate.
      rpiTestKernel = { lib, ... }: {
        boot.kernelPackages = lib.mkForce rpi5Base.config.boot.kernelPackages;
        boot.kernelPatches = lib.mkForce [ ];
        boot.initrd.kernelModules = [ "pci_host_generic" "rtc-pl031" ];
      };
      # The nix-utils args mkRpi5 passes via specialArgs; the VM harness has no
      # specialArgs, so a test node re-supplies them as _module.args.
      rpiSystemArgs = { inherit dotfiles nixpkgs-unstable; nixpkgs-stable = nixpkgs; };
      # The real rpi system config as a test node: rpi5HostModules (so the external
      # modules whose options hosts/rpi5 sets are declared exactly as on the deployed
      # system) on the pinned rpi kernel, with mkRpi5's specialArgs. Every rpi test
      # node builds on this, so they all exercise the deployed config.
      #
      # Deliberately supplies no -rtc. virtualisation.qemu.options is a list and QEMU
      # merges -rtc options, so a node that needs `clock=vm` (the icount timing test)
      # must be the only contributor -- a second `base=` key alongside it resolves in
      # no defined way. Such a node composes this; everything else takes the standard
      # RTC base by composing rpiSystemModule.
      rpiNodeBase = { ... }: {
        imports = rpi5HostModules ++ [ rpiTestKernel testNodeTimeSyncOff ];
        _module.args = rpiSystemArgs;
      };
      # The default rpi test node: rpiNodeBase plus the repo's standard RTC base, so
      # the real host timers stay enabled but can never elapse mid-test.
      rpiSystemModule = { ... }: {
        imports = [ rpiNodeBase ];
        virtualisation.qemu.options = [ (testRtcBase pkgsRpi.coreutils) ];
      };
      # The deployed rpi config as a connectivity-test node: only what cannot work in a VM
      # is disabled (auto-upgrade needs /etc/nixos; monitoring needs credentials and its
      # 30-min timer would fire mid-test). doh/dnscrypt, the firewall and iroh-ssh stay
      # live, so the connectivity checks run against the real egress rules.
      rpiConnectivitySystemModule = { lib, ... }: {
        imports = [ rpiSystemModule ];
        common.autoUpgrade.enable = lib.mkForce false;
        common.monitoring.enable = lib.mkForce false;
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
      # spec/rpi-features.md overrides the shared writeback thresholds with a
      # quarter of the laptop values (SD-card backing store).
      systemTestRpi = import ./tests/system.nix {
        nixpkgs = nixrpi;
        pkgs = pkgsRpi;
        stateVersion = rpi5Base.config.system.stateVersion;
        machineModule = rpiSystemModule;
        dirtyBytes = 67108864;             # 64 MiB
        dirtyBackgroundBytes = 16777216;   # 16 MiB
      };
      # The measurement producer against the receiver the Pi actually deploys. Slow here (TCG),
      # which is why the same file also runs as a generic x86 check.
      systemMetricsTestRpi = import ./tests/system-metrics.nix {
        nixpkgs = nixrpi;
        pkgs = pkgsRpi;
        stateVersion = rpi5Base.config.system.stateVersion;
        machineModule = rpiSystemModule;
        globalTimeout = 1800;
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
      # The monitoring platform's own VM suite, run against the REAL rpi config. Its
      # repo ships the same cases against a synthetic machine, but calls that the
      # weaker run on purpose: the assertions are about systemd sandboxing
      # (RestrictAddressFamilies, SystemCallFilter, ProtectSystem=strict), whose
      # semantics depend on the systemd version the target actually boots, so the
      # consumer-side run is the one that decides whether the hardening is correct
      # (its SPEC.md 11.1). Only the Pi deploys the service, hence no x86 variant.
      # Cases: `platform` runs the lightweight ones (readiness, ingest, socket-access,
      # hardening) as subtests on one VM; restart/ordering/crash-recovery get their own.
      monitoringPlatformTestsRpi = import "${monitoring-platform}/nix/tests/lib.nix" {
        pkgs = pkgsRpi;
        machineModules = [
          rpiQuiescedSystemModule
          {
            # Same reason as rpiNixUtilsTests: the harness sets no node hostName, so
            # without one the rpi config's mkDefault ties with the framework's.
            networking.hostName = "monitoring-platform-test";
            system.stateVersion = rpi5Base.config.system.stateVersion;
            virtualisation.memorySize = nixpkgs.lib.mkDefault 2048;
            # The tunnel has no credential in a VM so the unit would only skip, but
            # keep the node deterministic: nothing here is about remote access.
            common.irohSsh.enable = nixpkgs.lib.mkForce false;
          }
        ];
      };
      # The trigger-semantics regression test for the 2026-07-27 outage, on the REAL rpi
      # config (exact Pi kernel, live doh egress rules, live firewall -- so the setup
      # script's runtime nixos-fw openings are on the path here too). The decision logic
      # is arch-independent, but the incident was on the Pi and this is the deployed stack
      # that must not tear down its own network over a transient signal.
      connectivityFallbackTriggerTestRpi = import ./tests/connectivity-fallback-trigger.nix {
        nixpkgs = nixrpi;
        pkgs = pkgsRpi;
        stateVersion = rpi5Base.config.system.stateVersion;
        machineModule = rpiConnectivitySystemModule;
      };
      # The REAL rpi system config as the node (exact Pi kernel, which ships
      # mac80211_hwsim -- verified 6.18.34 -- and carries the tpm-crb initrd
      # workaround). The rest of the deployed stack stays live.
      connectivityFallbackTestRpi = import ./tests/connectivity-fallback.nix {
        nixpkgs = nixrpi;
        pkgs = pkgsRpi;
        stateVersion = rpi5Base.config.system.stateVersion;
        machineModule = rpiConnectivitySystemModule;
      };
      # The DNS-outage reboot failsafe on the REAL rpi config -- the valuable variant: the
      # deployed dnscrypt, the DoH egress rules that make a loopback-only probe the only
      # workable one, and the default-deny firewall are all live.
      connectivityWatchdogTestRpi = import ./tests/connectivity-watchdog.nix {
        nixpkgs = nixrpi;
        pkgs = pkgsRpi;
        stateVersion = rpi5Base.config.system.stateVersion;
        # hosts/rpi5 also enables connectivity-fallback, whose check would fire at the
        # production bootGrace of 5min -- inside a test that runs ~25 virtual minutes and
        # whose whole subject is a reboot. It happens to be harmless today (this node has
        # no wlan0, so the check takes its `iw`-failed fail-safe branch and starts nothing),
        # but that leaves the only thing between this test and a competing reboot every
        # bootGrace+setupTimeout sitting in an unrelated code path in another module. Push
        # the deadline past the end of the test instead; the fallback units stay present, so
        # this is still the deployed config.
        machineModule = { ... }: {
          imports = [ rpiConnectivitySystemModule ];
          common.connectivityFallback.bootGrace = "3h";
        };
        inherit dohStamps;
      };
      # The boot-time rough clock on the REAL rpi config -- the valuable variant, since the
      # RTC-less Pi is the host that actually needs it: the deployed dnscrypt, the DoH egress
      # rules and the default-deny firewall are all live around it.
      roughTimeTestRpi = import ./tests/rough-time.nix {
        nixpkgs = nixrpi;
        pkgs = pkgsRpi;
        stateVersion = rpi5Base.config.system.stateVersion;
        inherit dohStamps;
        # Same reasoning as connectivityWatchdogTestRpi: hosts/rpi5 enables
        # connectivity-fallback, whose check would fire at the production 5min bootGrace
        # inside a test whose retry subtests span far longer than that. Push the deadline
        # past the end of the run rather than removing the units.
        machineModule = { ... }: {
          imports = [ rpiConnectivitySystemModule ./modules/time-sync.nix ];
          common.connectivityFallback.bootGrace = "3h";
        };
        globalTimeout = 1800;
      };
      # The full time chain on the REAL rpi config: rough clock -> DNS -> chrony over NTS.
      # The RTC-less Pi is the host the bootstrap deadlock actually happens to, so this is the
      # variant that matters.
      ntsSyncTestRpi = import ./tests/nts-sync.nix {
        nixpkgs = nixrpi;
        pkgs = pkgsRpi;
        stateVersion = rpi5Base.config.system.stateVersion;
        inherit dohStamps;
        machineModule = { ... }: {
          imports = [ rpiConnectivitySystemModule ./modules/time-sync.nix ];
          common.connectivityFallback.bootGrace = "3h";
        };
        globalTimeout = 2400;
      };
      # Production timer constants under icount time-warp, on the real rpi config. Composes
      # rpiNodeBase rather than rpiSystemModule so this node owns the sole -rtc flag (it
      # needs clock=vm; see rpiNodeBase). irohSsh's failsafe is the one extra thing forced
      # off: it is wantedBy=multi-user.target with Restart=always and
      # rechecks every recheckIntervalSeconds=30 once its probe fails, so it would wake the
      # guest ~30x across the ~950 virtual seconds here and leave no idle gap for the clock
      # to warp through -- which is the entire mechanism this test measures. iroh-ssh.service
      # itself needs nothing: ConditionPathExists skips it with no credential.
      connectivityFallbackTimingTestRpi = import ./tests/connectivity-fallback-timing.nix {
        nixpkgs = nixrpi;
        pkgs = pkgsRpi;
        stateVersion = rpi5Base.config.system.stateVersion;
        rtcOption = "-rtc clock=vm,base=$(${pkgsRpi.coreutils}/bin/date -u -d tomorrow +%Y-%m-%dT10:00:00)";
        machineModule = { lib, ... }: {
          imports = [ rpiNodeBase ];
          common.autoUpgrade.enable = lib.mkForce false;
          common.monitoring.enable = lib.mkForce false;
          common.irohSsh.failsafe.enable = lib.mkForce false;
          # Its 1h timer cannot fire inside this test's ~950 virtual seconds, so this is
          # belt-and-braces rather than a fix -- but the whole test rests on the guest
          # being idle between the two boundaries it measures, so a unit that wakes it up
          # is exactly the thing to keep off this node (see the header note).
          common.connectivityWatchdog.enable = lib.mkForce false;
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
        system = systemTestRpi;
        nix-gc-retention = nixGcRetentionTestRpi;
        monitoring = monitoringTestRpi;
        connectivity-fallback = connectivityFallbackTestRpi;
        connectivity-fallback-trigger = connectivityFallbackTriggerTestRpi;
        connectivity-watchdog = connectivityWatchdogTestRpi;
        rough-time = roughTimeTestRpi;
        nts-sync = ntsSyncTestRpi;
        connectivity-fallback-timing = connectivityFallbackTimingTestRpi;
        monitoring-nix-gc = monitoringNixGcTestRpi;
        monitoring-iroh-ssh = monitoringIrohSshTestRpi;
        firewall = firewallTestRpi;
        iroh-ssh = irohSshTestRpi;
        restic = resticTestRpi;
        boot-clock = bootClockTestRpi;
        system-metrics = systemMetricsTestRpi;
      } // (nixpkgs.lib.mapAttrs'
        (name: test: nixpkgs.lib.nameValuePair "nix-utils-${name}" test)
        rpiNixUtilsTests)
      # The harness's `platform` key is its shared-VM run, so it takes the bare name
      # and the isolated cases get suffixed. dropKvm applies because these are inside
      # the mapAttrs argument: upstream only drops it in its own nix/tests/default.nix,
      # which we do not import.
      // (nixpkgs.lib.mapAttrs'
        (name: test: nixpkgs.lib.nameValuePair
          (if name == "platform" then "monitoring-platform" else "monitoring-platform-${name}")
          test)
        monitoringPlatformTestsRpi)) // {
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
      # spec/features/system.md: the shared values, asserted on the base module
      # that declares them (the -anya variant covers the real host config).
      systemTest = import ./tests/system.nix {
        inherit nixpkgs pkgs stateVersion;
        machineModule = ./modules/laptop-base.nix;
        dirtyBytes = 268435456;            # 256 MiB
        dirtyBackgroundBytes = 67108864;   #  64 MiB
      };
      systemMetricsTest = import ./tests/system-metrics.nix {
        inherit nixpkgs pkgs stateVersion;
        machineModule = commonDesktopModule;
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
      # No real image exists for x86 (the deployed system is aarch64-only), so the three
      # x86 connectivity variants run on this minimal module+firewall node. The firewall is
      # part of it deliberately: the setup script's runtime nixos-fw openings are only
      # emitted when the nftables firewall is managed, so without it that path is dead code.
      # The aarch64 variants of all three run on the real rpi config.
      connectivityFallbackNode = { ... }: {
        imports = [ ./modules/connectivity-fallback.nix ./modules/firewall.nix ];
      };
      connectivityFallbackTest = import ./tests/connectivity-fallback.nix {
        inherit nixpkgs pkgs stateVersion;
        machineModule = connectivityFallbackNode;
      };
      # Trigger decision logic (sustained non-association, flap tolerance, unusable
      # radio), isolated from the radio stack. Regression test for the 2026-07-27
      # reboot loop.
      connectivityFallbackTriggerTest = import ./tests/connectivity-fallback-trigger.nix {
        inherit nixpkgs pkgs stateVersion;
        machineModule = connectivityFallbackNode;
      };
      # icount concept test: production timer constants under TCG time-warp.
      connectivityFallbackTimingTest = import ./tests/connectivity-fallback-timing.nix {
        inherit nixpkgs pkgs stateVersion;
        machineModule = connectivityFallbackNode;
        rtcOption = "-rtc clock=vm,base=$(${pkgs.coreutils}/bin/date -u -d tomorrow +%Y-%m-%dT10:00:00)";
      };
      # The DNS-outage reboot failsafe on x86: the real desktop host config (which already
      # imports modules/doh.nix, so dnscrypt-proxy and its cache are the deployed ones)
      # with the watchdog module added and switched on. The feature ships only on the rpi,
      # so this variant exists for fast local feedback; the aarch64 variant against
      # hosts/rpi5 is the one that covers the deployed target.
      # The rough clock on the generic desktop config, for fast local feedback; the aarch64
      # variant against hosts/rpi5 is the one that covers the deployed target. The module is
      # imported here rather than through common-desktop.nix so the test exercises it before
      # any host switches its clock over to it.
      roughTimeTest = import ./tests/rough-time.nix {
        inherit nixpkgs pkgs stateVersion dohStamps;
        machineModule = { ... }: {
          imports = [ commonDesktopModule ./modules/time-sync.nix ];
        };
      };
      ntsSyncTest = import ./tests/nts-sync.nix {
        inherit nixpkgs pkgs stateVersion dohStamps;
        machineModule = { ... }: {
          imports = [ commonDesktopModule ./modules/time-sync.nix ];
        };
      };
      connectivityWatchdogTest = import ./tests/connectivity-watchdog.nix {
        inherit nixpkgs pkgs stateVersion dohStamps;
        machineModule = { ... }: {
          imports = [ commonDesktopModule ./modules/connectivity-watchdog.nix ];
          common.autoUpgrade.enable = false;
          common.monitoring.enable = false;
          common.irohSsh.enable = false;
          common.connectivityWatchdog.enable = true;
        };
      };
      # The real anya-feher-laptop host config as a test node (mirrors
      # rpiSystemModule; plain x86, so no kernel neutralization is needed). The RTC
      # base is the only thing this layer adds to the deployed composition. Feature
      # tests run against it so a host-config change that breaks a feature fails that
      # feature's -anya variant.
      anyaFeherLaptopSystemModule = { ... }: {
        imports = [ anyaFeherLaptopHostModule testNodeTimeSyncOff ];
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
      dohStampEncodeTest = import ./tests/doh-stamp-encode.nix {
        inherit pkgs dohStamps;
      };
      dohEndpointsTest = import ./tests/doh-endpoints.nix {
        inherit pkgs dohStamps;
      };
      ntsServersTest = import ./tests/nts-servers.nix {
        inherit pkgs ntsServers;
      };
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
      anyaFeherLaptopSystemTest = import ./tests/system.nix {
        inherit nixpkgs pkgs stateVersion;
        machineModule = anyaFeherLaptopSystemModule;
        dirtyBytes = 268435456;            # 256 MiB
        dirtyBackgroundBytes = 67108864;   #  64 MiB
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
        anya-feher-laptop-system = anyaFeherLaptopSystemTest;
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
        connectivity-fallback-trigger = connectivityFallbackTriggerTest;
        connectivity-watchdog = connectivityWatchdogTest;
        rough-time = roughTimeTest;
        nts-sync = ntsSyncTest;
        connectivity-fallback-timing = connectivityFallbackTimingTest;
        system = systemTest;
        system-metrics = systemMetricsTest;
      } // (nixpkgs.lib.mapAttrs'
        (name: test: nixpkgs.lib.nameValuePair "nix-utils-${name}" test)
        nixUtilsTests));
      # Eval-only runCommands (throw on drift), not VM tests: no kvm feature to drop, and
      # arch-independent since stamps/endpoints are pure data, so x86_64 only. These must
      # be part of the generic-x86 checkSet and not only of checks.${system}: the
      # Makefile's run-checks builds a checkSet name by name, so a check outside one is
      # never evaluated by CI.
      evalChecks = {
        doh-stamp-encode = dohStampEncodeTest;
        doh-endpoints = dohEndpointsTest;
        nts-servers = ntsServersTest;
      };
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
        generic-x86 = testResults // evalChecks;
        anya-feher-laptop = anyaFeherLaptopChecks;
      };

      legacyPackages.${system} = pkgs;

      nixosConfigurations = {
        qemu-graphical = qemuGraphical;
      };

      checks.${system} = testResults // evalChecks // anyaFeherLaptopChecks;
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
        system-driver = systemTest.driver;
        system-driver-interactive = systemTest.driverInteractive;
      } // nixUtilsTestDrivers;
    };
}
