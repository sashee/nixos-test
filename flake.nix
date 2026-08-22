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
          # ...and the collector for the same reason. The producer's path on the Pi is
          # producer -> collector -> receiver, and a fast x86 check that skipped the middle hop
          # would be exercising a topology nothing deploys -- including the clock gate being
          # OFF, which is a consequence of that hop (see common.systemMetrics.viaCollector).
          "${monitoring-platform}/nix/collector-module.nix"
        ];
        _module.args.commonDotfiles = dotfiles;
        _module.args.unstable = unstable;

        services.monitoring-platform.enable = true;
        services.mp-collector.enable = true;
        # Pointed at the collector, not the receiver, exactly as hosts/rpi5 is.
        common.systemMetrics = {
          enable = true;
          socketPath = config.services.mp-collector.socketPath;
          group = config.services.mp-collector.group;
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
      # same treatment every VM test acquires a daemon -- one that steps the clock forward to
      # its drift file on start (`chronyd -s`) and has an hourly correction service beside it --
      # that argues with the ~10 tests which drive the clock with `date -s`.
      #
      # Priority 90 rather than mkForce: it has to beat the host config's normal-priority
      # `enable = true`, while leaving mkForce free for the two tests that are ABOUT time and
      # must switch it back on.
      testNodeTimeSyncOff = { lib, ... }: {
        common.timeSync.enable = lib.mkOverride 90 false;
      };
      # The same treatment for the measurement receiver. Its clock gate refuses to start the
      # service until the kernel's clock error estimate is small, and a test node has no time
      # source to get there with: testNodeTimeSyncOff took chrony away and qemu-vm.nix had
      # already disabled timesyncd. So the gate holds every boot for its full derived
      # TimeoutStartSec and then fails the unit, which is how it broke the system-metrics test
      # -- a test that holds its NTP node down on purpose, to watch the producer wait for a
      # clock it does not have yet.
      #
      # This is the only place the gate is switched off. It is exercised by the two
      # monitoringPlatformTests* suites, which are the only nodes that can satisfy it: each
      # brings its own NTP node and forces this back on. The rpi one, against the real Pi
      # config, is where the gate's correctness is decided.
      #
      # Priority 90 for the same reason as testNodeTimeSyncOff: leave mkForce free for the
      # suite that must switch it back on.
      testNodeClockGateOff = { lib, ... }: {
        services.monitoring-platform.clockGate.enable = lib.mkOverride 90 false;
      };
      # The collector's §9 health event is an ordinary measurement and lands in the same table
      # as everything else, on a 60-second timer. That is wanted in production -- "no daemon has
      # disciplined this device's clock since boot" is a work item, not a mystery -- and ruinous
      # in a test: tests/system-metrics.nix asserts an exact set of measurement types and an
      # exact batch count, both of which a row arriving on a timer breaks. Upstream's own harness
      # defaults it to 0 for the same reason.
      #
      # Priority 90 like the two overrides above, and for the same reason: it has to beat the
      # normal-priority definitions a host config makes, while leaving mkForce free for the
      # upstream collector-clock case, which sets an interval of 5 because measuring the health
      # event IS its subject.
      testNodeCollectorHealthOff = { lib, ... }: {
        services.mp-collector.healthIntervalSecs = lib.mkOverride 90 0;
      };
      # The collector's API key, which hosts/rpi5 loads with LoadCredentialEncrypted= from
      # /etc/credentials/mp-collector/mp-api-key. That blob is provisioned out-of-band on the Pi
      # and a guest has none, and a named-but-missing LoadCredential* is FATAL: the unit dies at
      # step CREDENTIALS with 243, Restart=on-failure brings it back every 5s, and any test that
      # waits for it (tests/detected-devices.nix, tests/system-metrics.nix) waits out the global
      # timeout instead. Every rpi node inherits the deployed config, so without this every rpi
      # check runs with no collector -- silently, for the ones that only produce measurements.
      #
      # Provisioned rather than switched off, so the credential wiring itself is under test on
      # both arches: the id, the file name and the --name= the blob is authenticated with all have
      # to agree, and only a real decryption proves they do. The alternative (mkForce [ ]) would
      # make the tests pass while leaving that untested.
      #
      # Encrypted at boot rather than at build time or during activation, and this is not a
      # preference: the blob is bound to the host key in /var/lib/systemd/credential.secret, which
      # does not exist in the store and is not yet set up while activation runs. systemd-creds
      # creates it on first use, which is here. (Same reason tests/monitoring/*.nix and
      # tests/restic.nix all provision their blobs from a boot-time oneshot.)
      #
      # The ordering is the fiddly part. mp-collector runs with DefaultDependencies=false because
      # it must precede the time daemons, so it starts long before multi-user.target and a
      # provisioning unit with ordinary dependencies cannot precede it -- worse, it would close an
      # ordering cycle (mp-collector -> us -> sysinit.target -> systemd-timesyncd -> mp-collector)
      # that systemd resolves by dropping a job of its choosing. Hence the same three lines the
      # collector itself carries: no default dependencies, ordered after local-fs.target for a
      # writable /etc and /var, and requiredBy= rather than a bare before= so the collector waits
      # for the key to exist instead of merely being ordered after an attempt to write it.
      #
      # The token provisioned here is a PLACEHOLDER and is meant to be refused: it is well-formed
      # (SPEC.md §13 is `mpk_` + 16 hex + `.` + 64 hex) but was never issued, so the receiver
      # answers 401 and keeps nothing. That is now the whole of its job -- to be a decryptable
      # credential of the right shape so the unit starts on time, and nothing more.
      #
      # It used to be the key the tests ran on, back when the receiver only verified and logged.
      # It cannot be any more: §13 phase 2 enforces, on the read path as well as the write path,
      # so an unissued key means no telemetry reaches the receiver at all. A real key cannot be
      # issued here either -- the database it must be issued into does not exist until the
      # receiver's StateDirectory= makes it, which is long after this unit runs. The three tests
      # that read the receiver back therefore issue their own at test-script time and restart the
      # collector onto it; see lib/test-mp-auth.nix, which explains the ordering that forces this.
      #
      # The receiver's package goes on PATH for that step: `create-api-key` is its CLI, and
      # hosts/rpi5 installs only git, so without this the tests have no way to mint a key. Test
      # nodes only -- the deployed Pi issues its key out-of-band and needs no such tool on PATH.
      #
      # Inert in the two monitoring-platform suites, which compose this via the rpi node but bring
      # upstream's own harness with them: that harness points apiKeyFile at its own plaintext
      # /etc/mp-api-key and beats hosts/rpi5's mkDefault, so the blob below is still provisioned and
      # simply never read. Harmless, and not worth a switch -- but it does mean the credential
      # wiring this fixture exists to exercise is under test in the rpi5 and rpi5-x86 producer
      # checks, not in those two.
      testNodeCollectorApiKey = { pkgs, config, ... }: {
        environment.systemPackages = [ config.services.monitoring-platform.package ];
        systemd.services.test-mp-api-key = {
          description = "Provision the collector's API key credential (test nodes only)";
          requiredBy = [ "mp-collector.service" ];
          before = [ "mp-collector.service" ];
          unitConfig = {
            DefaultDependencies = false;
            After = [ "local-fs.target" ];
            RequiresMountsFor = [ "/etc" "/var/lib" ];
          };
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            install -d -m 0700 /etc/credentials/mp-collector
            printf '%s' 'mpk_dededededededede.abababababababababababababababababababababababababababababababab' \
              | ${pkgs.systemd}/bin/systemd-creds encrypt --name=mp-api-key - \
                  /etc/credentials/mp-collector/mp-api-key
            chmod 0600 /etc/credentials/mp-collector/mp-api-key
          '';
        };
      };
      # The iroh tunnel hosts/rpi5 puts between the collector and the receiver
      # (modules/monitoring-platform-tunnel.nix). Both halves need a provisioned credential, a
      # reachable relay and endpoint-id discovery -- an entire impersonated n0 in the test, which
      # tests/monitoring-platform-tunnel.nix builds and no other suite has. Left on, every rpi
      # check that asserts a measurement arrived would instead be asserting that iroh works,
      # and would fail: the units skip on ConditionPathExists and the collector spools.
      #
      # So the tunnel comes out and the collector is pointed back at the receiver's own socket,
      # which is the path this hop replaced. Priority 90 for the reason the overrides above give:
      # it must beat hosts/rpi5's normal-priority definitions while leaving mkForce free for the
      # one suite that switches the tunnel back on.
      testNodeMpTunnelOff = { config, lib, ... }: {
        common.mpTunnel.server.enable = lib.mkOverride 90 false;
        common.mpTunnel.client.enable = lib.mkOverride 90 false;
        services.mp-collector.forwardTo =
          lib.mkOverride 90 config.services.monitoring-platform.socketPath;
        services.mp-collector.forwardToGroup =
          lib.mkOverride 90 config.services.monitoring-platform.group;
      };
      # VM-test guest clock: tomorrow at 10:00 UTC. See lib/test-rtc-base.nix for why, and
      # for why it is a file rather than a binding here (a test file needs it for a helper
      # node that must share the clock of the node under test).
      testRtcBase = import ./lib/test-rtc-base.nix;
      # The desktop config as a VM-test node; all tests use this variant so the
      # real host timers (nix-gc, ...) stay enabled but can never elapse mid-test.
      commonDesktopModule = { ... }: {
        imports = [
          commonDesktopHostModule
          testNodeTimeSyncOff
          testNodeClockGateOff
          testNodeCollectorHealthOff
        ];
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
      # The monitoring platform's own VM suite on x86: the fast companion to the aarch64 run
      # below, which stays the one that decides (its SPEC.md 11.1 -- the sandbox assertions
      # are only meaningful against the systemd the target actually boots, and only the Pi
      # deploys the service).
      #
      # What this buys, and why it is not redundant with either of the other two runs: the
      # harness has to give the machine under test a working time source without touching how
      # it keeps time, and getting that wrong fails at RUNTIME, not evaluation. Upstream's own
      # synthetic machine runs no time daemon, so its suite cannot exercise that path at all;
      # ours runs chrony over NTS with `minsources 2` against a four-name server list, which
      # is what caught a harness that pointed every name at one address (one usable source,
      # `minsources` unsatisfiable, the clock gate never opening). That property is
      # arch-independent, so pinning it here means a laptop reproduces it in minutes instead
      # of it only surfacing on hardware neither CI nor a laptop can emulate.
      #
      # The node is rpi5X86QuiescedModule -- the same one every other check in this set uses, and
      # the x86 twin of the rpiQuiescedSystemModule the aarch64 run below takes. That is the whole
      # point of a "fast companion": it is only a mirror if it is built from the same host config.
      #
      # It was not, until 2026-08-15, and that cost a red CI run. This suite used to get a minimal
      # node of its own -- upstream's module.nix plus modules/time-sync.nix and nothing else -- which
      # never composed hosts/rpi5. So when hosts/rpi5 and upstream's own harness both came to define
      # services.mp-collector.apiKeyFile, the resulting conflict was invisible here and failed only
      # on aarch64, where the node does compose the deployed config. A mirror that omits the thing
      # under test reports green for the arch it cannot see.
      #
      # The old node's stated reason for existing does not survive the move: it was chosen over
      # commonDesktopModule because that pulls modules/nix-utils.nix, whose sandboxed `sqlite3`
      # shadows root's and stops the harness reading the receiver's database. hosts/rpi5 has no such
      # collision -- nix-utils is on the nixos user's PATH only -- so the objection was always to the
      # desktop config specifically, and the comment already noted hosts/rpi5 was the better target.
      monitoringPlatformTestsX86 = import "${monitoring-platform}/nix/tests/lib.nix" {
        inherit pkgs;
        # Not the repo-level stateVersion: this node is the Pi's config, and stateVersion changes
        # module defaults. See rpi5StateVersion for why it is read from a file rather than taken
        # from rpi5Base, which would drag a nixos-raspberrypi eval into every x86 check process.
        stateVersion = rpi5StateVersion;
        machineModules = [
          rpi5X86QuiescedModule
          {
            # Same reason as the aarch64 run: the harness sets no node hostName, so without one
            # the rpi config's mkDefault ties with the framework's.
            networking.hostName = "monitoring-platform-test";
            virtualisation.memorySize = nixpkgs.lib.mkDefault 2048;
            # The tunnel has no credential in a VM so the unit would only skip, but keep the node
            # deterministic: nothing here is about remote access.
            common.irohSsh.enable = nixpkgs.lib.mkForce false;
            # Undo testNodeClockGateOff, which every rpi node inherits via rpi5X86NodeBase. This
            # suite is the one that tests the gate -- its clock-gate case asserts the gate is on
            # the unit at all, so an off switch here would make the case fail rather than skip --
            # and it is also the only one that can satisfy it, because its harness gives the node
            # a real NTP server.
            services.monitoring-platform.clockGate.enable = nixpkgs.lib.mkForce true;
          }
        ];
      };
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
        # The on-host forwarding collector. A separate module from the receiver upstream
        # because the two units are deliberate opposites -- the receiver refuses to start
        # until the clock is good, the collector must be running BEFORE anything can step it
        # -- and this host runs both.
        "${monitoring-platform}/nix/collector-module.nix"
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
        user = "demo";
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
        inherit nixpkgs pkgs stateVersion dohStamps;
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
        imports = rpi5HostModules ++ [
          rpiTestKernel
          testNodeTimeSyncOff
          testNodeClockGateOff
          testNodeCollectorHealthOff
          testNodeCollectorApiKey
          testNodeMpTunnelOff
        ];
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
        inherit dohStamps;
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
        journalMaxUse = "256M";
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
      # The inverter producer against emulated FTDI adapters. Slow here (TCG, and every subtest
      # waits out at least one poll interval), which is why the same file also runs as an x86
      # check -- but this is the run on the kernel the Pi actually boots, and therefore the one
      # that says whether ftdi_sio and the by-id naming behave there.
      inverterMonitoringTestRpi = import ./tests/inverter-monitoring.nix {
        nixpkgs = nixrpi;
        pkgs = pkgsRpi;
        stateVersion = rpi5Base.config.system.stateVersion;
        machineModule = rpiSystemModule;
        globalTimeout = 2400;
      };
      # The BMS producer against emulated FTDI adapters, with the inverter producer live beside it on
      # the same bus -- the port contention between them is half of what this check is for, and it
      # cannot be seen from either producer's own test. Slow here (TCG, and several subtests wait out
      # a measurement interval), which is why the same file also runs as an x86 check; but this is
      # the run on the kernel the Pi actually boots.
      bmsMonitoringTestRpi = import ./tests/bms-monitoring.nix {
        nixpkgs = nixrpi;
        pkgs = pkgsRpi;
        stateVersion = rpi5Base.config.system.stateVersion;
        machineModule = rpiSystemModule;
        globalTimeout = 3000;
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
            # Undo testNodeClockGateOff, which every other rpi node inherits from
            # rpiNodeBase. This suite is the one that tests the gate -- its clock-gate case
            # asserts the gate is on the unit at all, so an off switch here would make the
            # case fail rather than skip -- and it is also the only one that can satisfy the
            # gate, because its harness gives the node a real NTP server.
            services.monitoring-platform.clockGate.enable = nixpkgs.lib.mkForce true;
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
      # The time-correction service on the REAL rpi config -- the valuable variant, since the
      # RTC-less Pi is the host that actually needs it: the deployed dnscrypt, the DoH egress
      # rules and the default-deny firewall are all live around it.
      timeCorrectionTestRpi = import ./tests/time-correction.nix {
        nixpkgs = nixrpi;
        pkgs = pkgsRpi;
        stateVersion = rpi5Base.config.system.stateVersion;
        inherit dohStamps ntsServers;
        # Same reasoning as connectivityWatchdogTestRpi: hosts/rpi5 enables
        # connectivity-fallback, whose check would fire at the production 5min bootGrace
        # inside a test whose subtests span far longer than that. Push the deadline past the
        # end of the run rather than removing the units.
        machineModule = { ... }: {
          imports = [ rpiConnectivitySystemModule ./modules/time-sync.nix ];
          common.connectivityFallback.bootGrace = "3h";
        };
        globalTimeout = 1800;
      };
      # The full time chain on the REAL rpi config: correction service -> DNS -> chrony over NTS.
      # The RTC-less Pi is the host the bootstrap deadlock actually happens to, so this is the
      # variant that matters.
      ntsSyncTestRpi = import ./tests/nts-sync.nix {
        nixpkgs = nixrpi;
        pkgs = pkgsRpi;
        stateVersion = rpi5Base.config.system.stateVersion;
        inherit dohStamps ntsServers;
        machineModule = { ... }: {
          imports = [ rpiConnectivitySystemModule ./modules/time-sync.nix ];
          common.connectivityFallback.bootGrace = "3h";
        };
        # Four VMs under TCG, with a real reboot and several chrony synchronisations.
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
          # Load-bearing, not belt-and-braces: at the 600s interval hosts/rpi5 deploys, its
          # OnBootSec elapses inside this test's ~950 virtual seconds. The whole test rests on
          # the guest being idle between the two boundaries it measures, so a unit that wakes
          # it up is exactly the thing to keep off this node (see the header note). It read as
          # belt-and-braces while the interval was 1h and could not fire at all; shortening it
          # to 10min is what made this line the fix.
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
      # The one suite that switches testNodeMpTunnelOff back on, because it is the
      # one that brings a relay and a discovery domain with it.
      mpTunnelTestRpi = import ./tests/monitoring-platform-tunnel.nix {
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
        time-correction = timeCorrectionTestRpi;
        nts-sync = ntsSyncTestRpi;
        connectivity-fallback-timing = connectivityFallbackTimingTestRpi;
        monitoring-nix-gc = monitoringNixGcTestRpi;
        monitoring-iroh-ssh = monitoringIrohSshTestRpi;
        firewall = firewallTestRpi;
        iroh-ssh = irohSshTestRpi;
        # Not "monitoring-platform-tunnel": the monitoring-platform-* names in this
        # set are upstream's own suite, mapped in below, and this is not one of them.
        mp-tunnel = mpTunnelTestRpi;
        restic = resticTestRpi;
        boot-clock = bootClockTestRpi;
        system-metrics = systemMetricsTestRpi;
        inverter-monitoring = inverterMonitoringTestRpi;
        bms-monitoring = bmsMonitoringTestRpi;
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

      # ---------------------------------------------------------------------------
      # The rpi5 config on x86: the fast companion to the aarch64 set above.
      #
      # The aarch64 set stays the one that DECIDES -- it is the only run on the kernel and
      # the arch the Pi actually boots. But it is also the one nobody can run: the patched
      # kernel is in no binary cache (hours of emulated compile without the CI artifact),
      # and even with the artifact imported the driver, QEMU and the guest all run under
      # binfmt/TCG on a laptop. So the rpi-only features -- connectivity fallback and
      # watchdog, the time-correction/NTS bootstrap, --delete-old GC, the measurement
      # producer -- had no run a change could be iterated against.
      #
      # This set closes that gap: the SAME rpi5HostModules the deployed Pi and every
      # aarch64 node compose, on x86 nixpkgs under KVM. That is possible at all because
      # rpi5HostModules is deliberately hardware-free -- the nixos-raspberrypi modules
      # (sd-image, raspberry-pi-5.base) are added only by mkRpi5 -- so the host config
      # itself is arch-neutral apart from the two kernel-coupled options undone below.
      #
      # What it therefore CANNOT catch, and what the aarch64 run remains responsible for:
      # a kernel bump dropping a module the Pi needs (required-kernel-modules), the
      # tpm-crb-in-initrd class of build break, brcmfmac AP behaviour, RTC-less boot
      # ordering, and anything whose outcome depends on TCG timing.
      # ---------------------------------------------------------------------------

      # The x86 counterpart of rpiTestKernel: what has to change for hosts/rpi5 to boot a
      # kernel the Pi never runs. Three things, and only three -- everything else in that
      # host config is arch-independent and is left exactly as deployed.
      rpi5X86Kernel = { lib, ... }: {
        # 1. headless-trim is a structuredExtraConfig, so left in place it would force a
        #    full custom x86 kernel build -- the exact cost this whole variant exists to
        #    avoid. Emptied, the `apply` on boot.kernelPackages overrides with
        #    arg-identical values, so the node lands on the cached pkgs.linuxPackages.
        #    Note what that costs: BTF is ON here and OFF on the Pi, so systemd's
        #    RestrictFileSystems= actually works on this node and no-ops on the real one.
        #    No ported check asserts on it; one that did would belong in the aarch64 set.
        boot.kernelPatches = lib.mkForce [ ];
        # 2. required-modules.txt is a snapshot of the live Pi (rp1_*, raspberrypi_*, vc4,
        #    aes_ce_*, macb). The check is wired into system.checks, so it runs as part of
        #    every toplevel build and this node would not build at all. Forced off rather
        #    than pointed at a second x86 list: the list IS the point, and a parallel one
        #    would be a thing to maintain that guards nothing. The check stays an aarch64
        #    check (`required-kernel-modules`), which is where it means something.
        common.requiredKernelModules.enable = lib.mkForce false;
        # 3. The direct analogue of rpiTestKernel's rtc-pl031, and NOT free just because
        #    x86 QEMU has an ordinary RTC: nixpkgs builds rtc_cmos as a module and does not
        #    put it in the default initrd. modules/laptop-base.nix is where the laptops get
        #    this line, and hosts/rpi5 does not import it. Left out, the clock sits at
        #    systemd's build epoch through early boot and jumps forward in stage-2 -- which
        #    wakes the Persistent nix-gc timers mid-test, the very thing rpiTestKernel's
        #    rtc-pl031 exists to prevent. rpi5-x86-boot-clock is the guard: drop this line
        #    and it fails, by name, quoting the fix.
        boot.initrd.availableKernelModules = [ "rtc_cmos" ];
        # boot.initrd.systemd.tpm2.enable = false (hosts/rpi5) is left alone on purpose:
        # it is a no-op on x86 and forcing it back on would be a config the Pi never runs.
      };
      # The x86 counterpart of rpiNodeBase: same rpi5HostModules, same specialArgs
      # re-supplied as _module.args, same test-node overrides -- only the kernel
      # differs. Note the top-level `nixpkgs`/`pkgs` here, not nixrpi/pkgsRpi.
      rpi5X86NodeBase = { ... }: {
        imports = rpi5HostModules ++ [
          rpi5X86Kernel
          testNodeTimeSyncOff
          testNodeClockGateOff
          testNodeCollectorHealthOff
          testNodeCollectorApiKey
          testNodeMpTunnelOff
        ];
        # rpiSystemArgs verbatim: nixpkgs-stable is already the top-level `nixpkgs`, and
        # hosts/rpi5 derives its `system` from pkgs.stdenv.hostPlatform, so the nix-utils
        # env it builds follows the platform with no argument change.
        _module.args = rpiSystemArgs;
      };
      # The default x86 rpi node: the repo's standard RTC base on top, so the real host
      # timers stay enabled but can never elapse mid-test (mirrors rpiSystemModule).
      rpi5X86SystemModule = { ... }: {
        imports = [ rpi5X86NodeBase ];
        virtualisation.qemu.options = [ (testRtcBase pkgs.coreutils) ];
      };
      # One binding for both roles the aarch64 side splits into rpiQuiescedSystemModule
      # and rpiConnectivitySystemModule -- they are textually identical there. Only what
      # cannot work in a VM is off: auto-upgrade needs /etc/nixos, monitoring needs
      # credentials and its 30-min timer would fire mid-test. doh/dnscrypt, the firewall
      # and iroh-ssh stay live.
      rpi5X86QuiescedModule = { lib, ... }: {
        imports = [ rpi5X86SystemModule ];
        common.autoUpgrade.enable = lib.mkForce false;
        common.monitoring.enable = lib.mkForce false;
      };
      # hosts/rpi5's stateVersion without evaluating a system; see hosts/rpi5/state-version.nix
      # for why it is a file. Deliberately NOT rpi5Base.config.system.stateVersion, which the
      # aarch64 checks use: that would drag a full nixos-raspberrypi evaluation into every x86
      # check process, and the Makefile gives each check its own. Also not
      # nixpkgs.lib.trivial.release -- that is 26.05 while the Pi deploys 24.11, and
      # stateVersion changes module defaults, so the wrong one would quietly test a
      # configuration no host has.
      rpi5StateVersion = import ./hosts/rpi5/state-version.nix;
      # Every entry below is the same call shape -- the same test file as its aarch64 twin,
      # x86 nixpkgs/pkgs, the rpi config's own stateVersion -- so this factors that out and
      # each check carries only what genuinely differs: its node module and the host
      # constants (gcOptions, keptAfterGc, dirtyBytes, flakeRef), which are copied verbatim
      # from the aarch64 call sites because they are properties of the config, not the arch.
      # The globalTimeout arguments are NOT copied: they are TCG ceilings, and these run
      # under KVM, so the test files' own defaults apply.
      rpi5X86Test = file: args: import file ({
        inherit nixpkgs pkgs;
        stateVersion = rpi5StateVersion;
      } // args);
      # The dotfiles suite on the rpi5 config as the real Pi user. The aarch64 variant is
      # still the one that decides -- its sandbox cases (userns/seccomp/bubblewrap) are
      # kernel-dependent and the Pi runs a trimmed kernel -- but this one catches
      # config-level breakage (the user's package env, PATH, sudo) in minutes.
      rpi5X86NixUtilsTests = import "${dotfiles}/nix-utils/tests/lib.nix" {
        inherit pkgs;
        machineModules = [
          rpi5X86SystemModule
          {
            # The suite sets no node hostName; without one the rpi config's mkDefault
            # ties with the test framework's mkDefault "machine".
            networking.hostName = "nix-utils-test";
            system.stateVersion = rpi5StateVersion;
            # The same 2 GiB the aarch64 node gets, not the generic 4: keeping the two
            # runs resource-identical is what makes a divergence between them meaningful.
            virtualisation.memorySize = nixpkgs.lib.mkDefault 2048;
            common.autoUpgrade.enable = nixpkgs.lib.mkForce false;
            common.monitoring.enable = nixpkgs.lib.mkForce false;
            common.irohSsh.enable = nixpkgs.lib.mkForce false;
          }
        ];
        user = "nixos";
      };
      # Node for the three checks whose subtests outlast connectivity-fallback's production
      # bootGrace (5min). Same treatment and same reasoning as the aarch64 variants: push
      # the deadline past the end of the run rather than removing the units, so the
      # deployed fallback stack is still present around the feature under test.
      rpi5X86LongRunModule = { ... }: {
        imports = [ rpi5X86QuiescedModule ./modules/time-sync.nix ];
        common.connectivityFallback.bootGrace = "3h";
      };
      # The x86 rpi check set: the rpi5 host config on the stock x86 kernel, plus (below the
      # rpi5-x86-* block) the host-independent x86 checks that need a KVM leg to ride on and
      # whose subject the Pi is the host that deploys.
      #
      # required-kernel-modules stays out and has no x86 twin: it is aarch64 by definition
      # (see rpi5X86Kernel).
      rpi5X86Checks = builtins.mapAttrs (_: dropKvm) ({
        rpi5-x86-doh = rpi5X86Test ./tests/doh.nix {
          machineModule = rpi5X86SystemModule;
          inherit dohStamps;
        };
        rpi5-x86-doh-upstream = rpi5X86Test ./tests/doh-upstream.nix {
          commonDesktopModule = rpi5X86QuiescedModule;
          inherit dohStamps;
        };
        rpi5-x86-auto-upgrade = rpi5X86Test ./tests/auto-upgrade-mocked-service.nix {
          autoUpgradeModule = ./modules/auto-upgrade.nix;
          nodeModule = rpi5X86SystemModule;
          flakeRef = "/etc/nixos#rpi5";
        };
        rpi5-x86-auto-upgrade-reboot = rpi5X86Test ./tests/auto-upgrade-reboot.nix {
          machineModule = rpi5X86SystemModule;
        };
        rpi5-x86-nix-settings = rpi5X86Test ./tests/nix-settings.nix {
          extraModule = rpi5X86SystemModule;
          gcOptions = "--delete-old";
        };
        rpi5-x86-nix-gc-retention = rpi5X86Test ./tests/nix-gc-retention.nix {
          machineModule = rpi5X86SystemModule;
          keptAfterGc = 1;  # --delete-old keeps only the current generation
        };
        rpi5-x86-system = rpi5X86Test ./tests/system.nix {
          machineModule = rpi5X86SystemModule;
          dirtyBytes = 67108864;             # 64 MiB
          dirtyBackgroundBytes = 16777216;   # 16 MiB
          journalMaxUse = "256M";
        };
        rpi5-x86-system-metrics = rpi5X86Test ./tests/system-metrics.nix {
          machineModule = rpi5X86SystemModule;
        };
        # The devices producer. `iw` and the BlueZ pair are faked -- a guest has no wireless phy
        # and no Bluetooth controller at all -- so this runs the same on either arch, and runs
        # here because this is the set that gets KVM.
        rpi5-x86-detected-devices = rpi5X86Test ./tests/detected-devices.nix {
          machineModule = rpi5X86SystemModule;
        };
        # The emulated-USB one. `usb-serial` is a QEMU device, not a guest kernel feature, so
        # this runs the same on either arch -- but it is the set that runs under KVM, which
        # matters for a test whose subtests each wait out a poll interval.
        rpi5-x86-inverter-monitoring = rpi5X86Test ./tests/inverter-monitoring.nix {
          machineModule = rpi5X86SystemModule;
        };
        # The BMS producer, and the port contention between the two USB producers. `usb-serial` is a
        # QEMU device rather than a guest kernel feature, so this runs the same on either arch -- but
        # this is the set that gets KVM, which matters for a test whose subtests each wait out a
        # measurement interval and which drives a service through an automatic restart.
        rpi5-x86-bms-monitoring = rpi5X86Test ./tests/bms-monitoring.nix {
          machineModule = rpi5X86SystemModule;
        };
        rpi5-x86-monitoring = rpi5X86Test ./tests/monitoring/rpi.nix {
          machineModule = rpi5X86SystemModule;
        };
        rpi5-x86-firewall = rpi5X86Test ./tests/firewall.nix {
          machineModule = rpi5X86SystemModule;
        };
        # The guard on rpi5X86Kernel's rtc_cmos line -- see there. Its aarch64 twin guards
        # rpiTestKernel's rtc-pl031, so this check earns its place in both sets by
        # asserting a different fix each time.
        rpi5-x86-boot-clock = rpi5X86Test ./tests/boot-clock.nix {
          machineModule = rpi5X86SystemModule;
        };
        rpi5-x86-iroh-ssh = rpi5X86Test ./tests/iroh-ssh.nix {
          machineModule = rpi5X86SystemModule;
          inherit dohStamps;
        };
        rpi5-x86-mp-tunnel = rpi5X86Test ./tests/monitoring-platform-tunnel.nix {
          machineModule = rpi5X86SystemModule;
          inherit dohStamps;
        };
        rpi5-x86-restic = rpi5X86Test ./tests/restic.nix {
          commonDesktopModule = rpi5X86QuiescedModule;
        };
        rpi5-x86-connectivity-fallback = rpi5X86Test ./tests/connectivity-fallback.nix {
          machineModule = rpi5X86QuiescedModule;
        };
        rpi5-x86-connectivity-fallback-trigger = rpi5X86Test ./tests/connectivity-fallback-trigger.nix {
          machineModule = rpi5X86QuiescedModule;
        };
        rpi5-x86-connectivity-watchdog = rpi5X86Test ./tests/connectivity-watchdog.nix {
          machineModule = rpi5X86LongRunModule;
          inherit dohStamps;
        };
        rpi5-x86-time-correction = rpi5X86Test ./tests/time-correction.nix {
          machineModule = rpi5X86LongRunModule;
          inherit dohStamps ntsServers;
        };
        rpi5-x86-nts-sync = rpi5X86Test ./tests/nts-sync.nix {
          machineModule = rpi5X86LongRunModule;
          inherit dohStamps ntsServers;
        };
      } // (nixpkgs.lib.mapAttrs'
        (name: test: nixpkgs.lib.nameValuePair "rpi5-x86-nix-utils-${name}" test)
        rpi5X86NixUtilsTests)
      # Host-independent x86 checks that ride this leg, deliberately WITHOUT the rpi5-x86-
      # prefix: a check set is a CI partition, not a namespace, and none of these runs on
      # the rpi5 node. Re-pointing them at rpi5X86SystemModule would change what they
      # assert -- connectivity-fallback-timing's premise is TCG determinism and its
      # `-rtc clock=vm` warp would then meet the rtc_cmos initrd rpi5X86Kernel adds, which
      # is the very thing rpi5-x86-boot-clock exists to guard.
      #
      # monitoring-nix-gc and monitoring-iroh-ssh are host-input-free module unit tests
      # (tests/monitoring/{nix-gc,iroh-ssh}.nix build their own node and take no host
      # module); anya enables common.monitoring and common.irohSsh too, so they are here
      # for scheduling, not ownership. connectivity-fallback-timing and monitoring-platform-*
      # do belong to the Pi: it is the only host that deploys either. All four have an
      # aarch64 twin in the rpi5 set, which evaluates a different nixpkgs; these are the
      # fast x86 runs.
      // {
        monitoring-nix-gc = monitoringNixGcTest;
        monitoring-iroh-ssh = monitoringIrohSshTest;
        connectivity-fallback-timing = connectivityFallbackTimingTest;
      }
      # Same renaming as the aarch64 set: the harness's `platform` key is its shared-VM run,
      # so it takes the bare name and the isolated cases get suffixed. The names collide with
      # the aarch64 ones by design -- checks are per-system attrsets and doh/system/firewall
      # already do the same -- so a check name still identifies one test, on both arches.
      // (nixpkgs.lib.mapAttrs'
        (name: test: nixpkgs.lib.nameValuePair
          (if name == "platform" then "monitoring-platform" else "monitoring-platform-${name}")
          test)
        monitoringPlatformTestsX86));

      # NOT CI COVERAGE. Everything from here down that runs on commonDesktopModule exists
      # only to back a <name>-driver / -driver-interactive package below: they are the
      # interactive way into a test, and the generic desktop node is the cheapest one to
      # boot by hand. None of them is in a checkSet or in checks.${system}, so CI never
      # builds them -- each is covered by its anya-feher-laptop-* or rpi5-x86-* twin, which
      # asserts the same thing against a config some host actually deploys. Adding one back
      # to a set would just re-run a host test against the shared module.
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
      # The node for connectivity-fallback-timing. No real image exists for x86 (the deployed
      # system is aarch64-only), so it runs on this minimal module+firewall node. The firewall
      # is part of it deliberately: the setup script's runtime nixos-fw openings are only
      # emitted when the nftables firewall is managed, so without it that path is dead code.
      # The fallback/trigger/watchdog variants run on the real rpi config, on both arches.
      connectivityFallbackNode = { ... }: {
        imports = [ ./modules/connectivity-fallback.nix ./modules/firewall.nix ];
      };
      # icount concept test: production timer constants under TCG time-warp. Its aarch64
      # twin runs the same premise against the real rpi config; this one is the fast x86
      # run on the minimal node.
      connectivityFallbackTimingTest = import ./tests/connectivity-fallback-timing.nix {
        inherit nixpkgs pkgs stateVersion;
        machineModule = connectivityFallbackNode;
        rtcOption = "-rtc clock=vm,base=$(${pkgs.coreutils}/bin/date -u -d tomorrow +%Y-%m-%dT10:00:00)";
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
      # Stand-in for the machine-unique parts that live on the device, so the deployable laptop
      # system can be evaluated here at all. Shared by anyaFeherLaptopEval and
      # timeSyncDeployedTest, which both need the host config forced but neither of which may
      # depend on the device's real hardware-configuration.nix.
      laptopStubHw = {
        fileSystems."/" = {
          device = "/dev/disk/by-label/nixos";
          fsType = "ext4";
        };
      };
      # Eval-only smoke check: force full evaluation (assertions included) of
      # the deployable system with a stand-in hardware config, so a broken host
      # config fails CI instead of the laptop's next auto-upgrade. The context
      # discard keeps the check from depending on (= building) the system.
      anyaFeherLaptopEval =
        let
          toplevel = (mkAnyaFeherLaptop { modules = [ laptopStubHw ]; }).config.system.build.toplevel;
        in
        pkgs.runCommand "anya-feher-laptop-eval" { } ''
          echo ${nixpkgs.lib.escapeShellArg (builtins.unsafeDiscardStringContext toplevel.drvPath)} > $out
        '';
      # Same shape, for the demo QEMU VM. It is packages.default and packages.qemu-vm --
      # the entry point the README's "run it in QEMU" section builds -- and the only
      # remaining consumer of modules/qemu-demo-user.nix, so without this nothing would
      # notice it breaking: no CI leg builds nixosConfigurations.
      qemuGraphicalEval =
        let
          toplevel = qemuGraphical.config.system.build.toplevel;
        in
        pkgs.runCommand "qemu-graphical-eval" { } ''
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
      dohProvidersTest = import ./tests/doh-providers.nix {
        inherit pkgs dohStamps;
      };
      # Unlike the eval checks above this one is not pure data -- it forces both deployed host
      # configs to render time-correction.timer and time-correction.service, which costs an eval
      # of each. Worth it because the values it asserts are the ones no VM test can see: both
      # time tests override the cadence so their own subtests are not interrupted by a timed run,
      # and both override the server list and the floor so their impersonated providers are the
      # ones dialled.
      # The other side of the same module: that it REFUSES the configurations it says it does.
      # One base evaluation plus an extendModules per case, rather than a system build per case.
      timeSyncAssertionsTest = import ./tests/time-sync-assertions.nix {
        inherit pkgs nixpkgs ntsServers;
      };
      timeSyncDeployedTest = import ./tests/time-sync-deployed.nix {
        inherit pkgs ntsServers dohStamps;
        hosts = {
          rpi5 = rpi5Base;
          anya-feher-laptop = mkAnyaFeherLaptop { modules = [ laptopStubHw ]; };
        };
      };
      anyaFeherLaptopTest = import ./tests/anya-feher-laptop.nix {
        inherit nixpkgs pkgs stateVersion;
        machineModule = anyaFeherLaptopSystemModule;
      };
      anyaFeherLaptopDohTest = import ./tests/doh.nix {
        inherit nixpkgs pkgs stateVersion dohStamps;
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
        # Spec: this host disables bluetooth, same as the desktop check below. The disabled
        # state itself is asserted in tests/anya-feher-laptop.nix.
        bluetooth = false;
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
      # plasma/locale firefox, nix-utils, the two time checks below). Timezone-adaptive
      # tests (fire_timer) handle anya's Europe/Budapest, so no UTC pin or headless
      # variant.
      anyaFeherLaptopDesktopNode = { lib, ... }: {
        imports = [ anyaFeherLaptopSystemModule ];
        virtualisation.cores = lib.mkDefault 2;
        virtualisation.memorySize = lib.mkDefault 4096;
      };
      # The two halves of the time chain on the real laptop host config. timeSync is enabled
      # there (timeSyncSettings is in anyaFeherLaptopHostModule), so without these it was the
      # only common.* feature the laptop deploys with no -anya variant.
      #
      # The desktop node rather than the bare system module: nts-sync does two real reboots and
      # time-correction runs some fifteen subtests, which is the heavy-wait case above. Its
      # sizing is mkDefault, so anything a test sets for itself still wins.
      #
      # Each test re-enables common.timeSync with mkForce in its own nodes.machine, which is
      # what beats testNodeTimeSyncOff's priority-90 `false` -- the case that override reserves
      # mkForce for. globalTimeout above the files' 1200 default because a ceiling is cheap and
      # three full desktop boots are not.
      anyaFeherLaptopTimeCorrectionTest = import ./tests/time-correction.nix {
        inherit nixpkgs pkgs stateVersion dohStamps ntsServers;
        machineModule = { ... }: {
          imports = [ anyaFeherLaptopDesktopNode ./modules/time-sync.nix ];
        };
        globalTimeout = 1800;
      };
      anyaFeherLaptopNtsSyncTest = import ./tests/nts-sync.nix {
        inherit nixpkgs pkgs stateVersion dohStamps ntsServers;
        machineModule = { ... }: {
          imports = [ anyaFeherLaptopDesktopNode ./modules/time-sync.nix ];
        };
        globalTimeout = 1800;
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
      # The shared desktop payload -- the .desktop Exec= lines, the icons, desktop-file-validate
      # -- asserted on the host that deploys it: hosts/anya-feher-laptop/configuration.nix
      # imports modules/common-desktop.nix, so the whole payload is present. qemuDemoUserModule
      # stays null because the host provides its own user and autologin.
      anyaFeherLaptopCommonDesktopTest = import ./tests/common-desktop.nix {
        inherit nixpkgs pkgs stateVersion;
        commonDesktopModule = anyaFeherLaptopDesktopNode;
        user = "anya";
        # Spec: this host disables bluetooth (hosts/anya-feher-laptop/configuration.nix).
        # anya-feher-laptop asserts the disabled state; asserting it here too would just
        # duplicate it, and asserting the enabled state would contradict the spec.
        bluetooth = false;
      };
      # Same dotfiles suite as the nix-utils driver packages, on the real host
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
        anya-feher-laptop-time-correction = anyaFeherLaptopTimeCorrectionTest;
        anya-feher-laptop-nts-sync = anyaFeherLaptopNtsSyncTest;
        anya-feher-laptop-plasma-firefox = anyaFeherLaptopPlasmaFirefoxTest;
        anya-feher-laptop-locale-firefox = anyaFeherLaptopLocaleFirefoxTest;
        anya-feher-laptop-common-desktop = anyaFeherLaptopCommonDesktopTest;
      } // (nixpkgs.lib.mapAttrs'
        (name: test: nixpkgs.lib.nameValuePair "anya-feher-laptop-nix-utils-${name}" test)
        anyaFeherLaptopNixUtilsTests)) // {
        # Eval-only runCommand, not a VM test: no kvm feature to drop.
        anya-feher-laptop-eval = anyaFeherLaptopEval;
      };
      # Eval-only runCommands (throw on drift), not VM tests: no kvm feature to drop, and
      # arch-independent since stamps/endpoints are pure data, so x86_64 only. They are
      # their own checkSet, and therefore their own CI leg, precisely because they build
      # no machine image: the leg needs no KVM and reports a data drift in about a minute
      # instead of behind a VM suite. Being in SOME checkSet is not optional -- the
      # Makefile's run-checks builds a checkSet name by name, so a check outside every set
      # is never evaluated by CI.
      evalChecks = {
        doh-stamp-encode = dohStampEncodeTest;
        doh-endpoints = dohEndpointsTest;
        nts-servers = ntsServersTest;
        doh-providers = dohProvidersTest;
        time-sync-deployed = timeSyncDeployedTest;
        time-sync-assertions = timeSyncAssertionsTest;
        qemu-graphical-eval = qemuGraphicalEval;
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
      # Named check sets for the Makefile's run-checks (SET=...), one per CI leg: the
      # eval-only checks (no machine image, so no KVM), one set per laptop host, the rpi5
      # config on x86, and the rpi5 config on aarch64. Every check lives in exactly one
      # set -- run-checks builds a set name by name, so a check outside every set is never
      # evaluated by CI. There is deliberately no generic set: a shared-module check whose
      # subject some host deploys belongs to that host's set, where a regression names the
      # config it broke.
      lib.checkSets = {
        eval = evalChecks;
        anya-feher-laptop = anyaFeherLaptopChecks;
        rpi5-x86 = rpi5X86Checks;
        rpi5 = aarch64TestResults;
      };

      legacyPackages.${system} = pkgs;

      nixosConfigurations = {
        qemu-graphical = qemuGraphical;
      };

      checks.${system} = evalChecks // anyaFeherLaptopChecks // rpi5X86Checks;
      checks.aarch64-linux = aarch64TestResults;
      # The exact patched kernel every rpi check boots (rpiTestKernel pins the
      # node to this package, so the outPath matches the checks). Exposed so it
      # can be built on its own: `make export-rpi-kernel` packs it on an aarch64
      # machine and `make import-rpi-kernel` loads it into a laptop's store, so
      # local rpi test runs skip the kernel compile.
      packages.aarch64-linux.rpi-test-kernel = rpi5Base.config.boot.kernelPackages.kernel;

      packages.${system} = {
        default = qemuVm;
        iroh-ssh = pkgs.callPackage ./packages/iroh-ssh/package.nix { };
        # Exposed so the binary can be built on its own, which on the Pi is the difference
        # between one small build and evaluating a whole check inside a 4 GB evaluator -- and
        # the Pi is the host this exists for.
        time-correction = pkgs.callPackage ./packages/time-correction/package.nix { };
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
