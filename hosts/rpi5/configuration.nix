{ config, pkgs, lib, dotfiles, nixpkgs-stable, nixpkgs-unstable, ... }:
let
  inherit (pkgs.stdenv.hostPlatform) system;
  stable   = import nixpkgs-stable   { inherit system; config.allowUnfree = true; };
  unstable = import nixpkgs-unstable { inherit system; config.allowUnfree = true; };
  nixUtils = import "${dotfiles}/nix-utils/lib.nix" {
    pkgs  = stable;
    inherit unstable;
    nixgl = null;
    # Headless box, so the GUI programs go. Measured 2026-07-29 by diffing the nixUtils
    # closure with and without vlc + flameshot + keepassxc + claude: 7.26 GB -> 5.74 GB,
    # i.e. 1.52 GB and 385 of 2421 paths, and nothing outside this env references any of
    # them. The tail is bigger than the programs themselves suggest -- vlc drags in
    # qtdeclarative-5.15, openjdk-jre, samba, flite and freepats; keepassxc/flameshot drag
    # in Qt 6 + gtk4; and one of them pulls a *second* systemd build (distinct store path
    # from the system's own).
    #
    # The path count matters as much as the bytes: `nix` accumulates narinfo metadata per
    # path, and that growth (measured at 5.9 GB) is what forced a mid-build process restart
    # during the 2026-07-29 upgrade, so 16% fewer paths directly lowers the peak.
    #
    # opencode came off separately, and only became skippable with the dotfiles bump that
    # split host-tools-mcp into its own program: mcp-register/-prefix and the broker used
    # to ride on opencode's and claude's `scripts`, so dropping both agents would have
    # taken the registration CLIs -- the way this headless box is driven -- with them.
    skip  = [
      "chromium"
      "vkquake"
      "libreoffice"
      "tor-browser"
      "vlc"
      "flameshot"
      "keepassxc"
      "claude"
      "opencode"
    ];
  };
  no = lib.mkForce lib.kernel.no;
  yes = lib.mkForce lib.kernel.yes;
  # mkRpi5 passes no specialArgs beyond dotfiles/nixpkgs-*, so the helper that builds the
  # rest: URL and names the backend credentials is imported rather than injected.
  resticLib = import ../../lib/restic.nix { inherit lib; };
in
{
  imports = [
    ../../modules/nix-settings.nix
    ../../modules/doh.nix
    ../../modules/restic.nix
    ../../modules/auto-upgrade.nix
    ../../modules/monitoring.nix
    ../../modules/system-metrics.nix
    ../../modules/detected-devices.nix
    ../../modules/inverter-monitoring.nix
    ../../modules/bms-monitoring.nix
    ../../modules/time-sync.nix
    ../../modules/connectivity-fallback.nix
    ../../modules/connectivity-watchdog.nix
    ../../modules/iroh-ssh.nix
    ../../modules/monitoring-platform-tunnel.nix
    ../../modules/required-kernel-modules.nix
    # Same default-deny inbound firewall as the laptops (nftables backend,
    # allowPing=false + ICMP echo-drop pre-table). The iroh tunnel is unaffected;
    # the wlan0 setup-portal ports are opened at runtime only while setup mode runs.
    ../../modules/firewall.nix
  ];

  # Daily boot-generation auto-upgrade: pulls the latest `common` from the host
  # flake and rebuilds. Active once /etc/nixos#rpi5 exists (common on github).
  common.autoUpgrade.enable = true;
  common.autoUpgrade.flake = "/etc/nixos#rpi5";
  # Reboot after the nightly auto-upgrade whenever anything changed, so a fresh boot always
  # matches the latest generation (not only on kernel/initrd/kernel-modules changes).
  common.autoUpgrade.rebootOnChange = true;

  networking.hostName = lib.mkDefault "nixos-rpi5";

  # Compressed RAM-backed swap (same mechanism as the laptops); useful on the 4 GB Pi.
  #
  # memoryPercent=100 rather than the module default of 50. `zram-size` is *uncompressed*
  # capacity, so the default gave 1.97 GiB of swap on this box -- and on 2026-07-29 that
  # ceiling was what turned a too-big nightly upgrade into a 5-hour outage. Measured at the
  # OOM: zram held 1.94 GiB (98% full) while `mem_used_max` was only 398 MiB, i.e. 10% of
  # RAM -- zstd was getting ~5:1 on the nix evaluator's heap, with only 1.3% of pages ever
  # incompressible (`huge_pages_since` 1678 of ~124k). So swap ran out with 90% of RAM still
  # unused by zram. Once swap was full the only reclaimable memory left was clean page cache,
  # so kswapd reclaimed ~1.62 TB worth of pages and the SD served 1.89 TB of reads (7.09 h
  # device-busy) while the build made 27 min of CPU progress in 7.5 h.
  #
  # 100 and not more: at the measured 5:1 a full 4.03 GiB costs 0.79 GiB of RAM, and even at
  # 2:1 it costs what the old 50% cost at 1:1 -- so this raises the ceiling without adding a
  # new worst case. 150 would bet on >=3:1, and `zramSwap` exposes no `mem_limit` (the sysfs
  # attribute is 0/unlimited), so there is no backstop if the ratio ever degrades.
  #
  # Not `writebackDevice`: it would push pages onto the SD, and *writes* are what wear the
  # card -- reads do not, which is why the 1.89 TB read above is harmless.
  #
  # Takes effect on reboot only: `disksize` is writable on an uninitialised zram device, so
  # a `switch` cannot resize swap that is already in use.
  zramSwap = {
    enable = true;
    memoryPercent = 100;
  };

  # Dirty-page writeback thresholds, a quarter of the laptop values (see
  # modules/laptop-base.nix, which this host does not import). Both scales are
  # wrong for this box by default: the kernel's ratio defaults (20%/10%) allow
  # ~800/400 MiB of dirty pages on 4 GiB of RAM, and the backing store is an SD
  # card, so a pool that large is many seconds of writes queued behind any fsync.
  # Starting writeback at 16 MiB keeps it trickling instead of bursting, and the
  # 64 MiB hard limit bounds how long a writer can be blocked.
  boot.kernel.sysctl = {
    "vm.dirty_bytes" = 67108864;              # 64 MiB
    "vm.dirty_background_bytes" = 16777216;   # 16 MiB
  };

  # Spec: journal max size = 256M (spec/rpi-features.md, System). journald's default is 10% of
  # the filesystem capped at 4 GB, i.e. ~2.9 GiB on this 29 GB SD -- and it gets there: the card
  # was holding 1022 MiB across 126 boots reaching back to 2024-12-19 before this cap. That is
  # both space this host cannot spare (the nightly upgrade needs GBs of headroom for a
  # from-source kernel) and steady write wear on the SD, for logs nobody reads past the last
  # few boots.
  #
  # No typed nixpkgs option exists for this: the journald module writes Storage/RateLimit*/Audit
  # from options and appends `extraConfig` verbatim, so the raw key is the documented route.
  # SystemMaxUse bounds archived + active journal files together; journald enforces it when it
  # rotates, so a switch does not shrink an over-cap journal on the spot --
  # `journalctl --vacuum-size=256M` does that immediately.
  #
  # Deliberately left alone: SystemKeepFree (default 15% of the fs), which is the other half of
  # the bound and only ever more conservative than a 256M cap here.
  services.journald.extraConfig = "SystemMaxUse=256M";

  # Spec: bluetooth enabled (spec/rpi-features.md, System). Set here rather than in a shared
  # module because the two hosts disagree -- modules/laptop-base.nix enables it for laptops and
  # anya-feher-laptop forces it back off, so there is no common default to inherit.
  #
  # The Pi's kernel side is already in place: `bluetooth`, `btbcm`, `btqca`, `btsdio` and
  # `hci_uart` are in hosts/rpi5/required-modules.txt (they came from the loaded-module
  # snapshot, so the onboard CYW43 radio is bound whether or not bluetoothd runs). What these
  # two options add is BlueZ, bluetoothd, its D-Bus policy and adapter management.
  hardware.bluetooth.enable = true;
  # Powers hci0 at boot (and turns LE on). Written by the nixpkgs module as
  # `Policy.AutoEnable` in /etc/bluetooth/main.conf, which is the assertable half in a VM --
  # a guest has no radio for hci0 to appear on.
  hardware.bluetooth.powerOnBoot = true;

  # No interactive boot menu on the Pi + limited SD space: keep only the current
  # generation on GC (laptops keep 14 days to roll back from the boot menu).
  common.nixSettings.gcOptions = "--delete-old";

  # GC twice a day: the nightly upgrade (starts 00:00-02:00) can run past the default
  # 03:15 slot (a nixpkgs-bump kernel rebuild took until ~05:20), which would leave the
  # old generation + build deps (GBs) on the SD until the *next* night -- overlapping
  # the next upgrade's download. The 15:15 pass clears them the same afternoon.
  nix.gc.dates = "*-*-* 03,15:15:00";

  # Health checks every 30 minutes (disk-space, generations, auto-upgrade). smart disabled (SD
  # card has no SMART); restic auto-skips with no backups. Reporting posts to a
  # Healthchecks URL read from a systemd-creds-encrypted file (LoadCredentialEncrypted);
  # provision it out-of-band: `systemd-creds encrypt --name=healthchecks-url - \
  # /etc/credentials/monitoring/healthchecks-url`.
  common.monitoring = {
    report.credentialDirectory = "/etc/credentials/monitoring";
    smart.enable = false;
    timerConfig.OnCalendar = "*:0/30";  # every 30 minutes (:00 and :30)
  };

  # OTLP/HTTP measurement receiver storing device measurements in SQLite under
  # /var/lib/monitoring-platform. Unrelated to common.monitoring above, which reports
  # this host's own health to Healthchecks; this one collects measurements *from*
  # devices. The module itself lives in the monitoring-platform input and is composed
  # in by rpi5HostModules (see flake.nix) -- which both the deployed system and the
  # test nodes build on -- not imported here.
  #
  # It listens on a unix socket only (RestrictAddressFamilies=AF_UNIX, enforced by the
  # kernel), so there is no port for the default-deny firewall to open: local access is
  # gated by the 0750 group-owned runtime directory, i.e. by membership of the
  # `monitoring-platform` group. Reaching it from off-box is the tunnel's job, below.
  services.monitoring-platform.enable = true;

  # The on-host collector every producer posts to, and the reason none of them names the
  # receiver. It buffers, resolves which clock frame each record was stamped in, and rewrites
  # the timestamps once the true time is known -- which is what this RTC-less box needs, since
  # its clock reads near the epoch from boot until chrony first syncs.
  #
  # It no longer posts to the receiver's socket: it posts to the tunnel's, which carries the
  # bytes over iroh to the receiver. Both ends are on this host today, so this hop is a
  # loopback that could have been a connect(2) -- which is the point. Running the split
  # transport now, while a mistake is one `systemctl status` away, means moving the receiver
  # off-box later changes no Nix at all: re-encrypt the client's iroh-ticket blob with the
  # new host's ticket and restart. Nothing below, and no producer, has to know.
  services.mp-collector.enable = true;
  services.mp-collector.forwardTo = config.common.mpTunnel.client.socketPath;
  services.mp-collector.forwardToGroup = "mp-tunnel";

  # The API key the collector presents to the receiver (SPEC.md §13). apiKeyEncrypted is the
  # module's default and is left unstated: the file is a systemd-creds blob like every other secret
  # on this host, so the module wires LoadCredentialEncrypted= and systemd decrypts it in PID 1
  # before the sandbox exists. The credential id and the file name must both be `mp-api-key`: the
  # name is authenticated into the blob, and decryption compares it.
  #
  # Provision out-of-band, ON THIS HOST -- there is no TPM on a Pi 5, so systemd-creds falls back to
  # the host key alone (/var/lib/systemd/credential.secret) and a reimaged SD needs a fresh key.
  # Issue it as the receiver's own user, or the WAL files it leaves in the 0700 state directory
  # belong to root and the receiver cannot write again:
  #   sudo -u monitoring-platform monitoring-platform create-api-key --label rpi5-collector \
  #     --db /var/lib/monitoring-platform/measurements.db \
  #   | systemd-creds encrypt --name=mp-api-key - /etc/credentials/mp-collector/mp-api-key
  #
  # This blob is load-bearing in both directions, and there is no longer a soft failure. §13 has
  # finished rolling out: the receiver enforces on the read path as well as the write path, so a
  # missing or unissued key costs DATA, not a warn line -- the collector keeps retrying a rejected
  # batch, so nothing is dropped on the floor, but nothing lands either and the outbox grows. An
  # unreadable blob is louder still: it fails this unit at start, and every producer on the host
  # posts through it.
  #
  # mkDefault because upstream's own VM harness (nix/tests/lib.nix) sets this option too, at normal
  # priority, for the nodes that compose this host config -- it issues a key of its own and points
  # the collector at a plaintext /etc/mp-api-key. The option is single-valued, so two normal
  # priorities are a hard evaluation error rather than a merge, and the harness that provisions the
  # key is the one that has to win. Nothing but a harness ever defines it, so on the deployed Pi
  # this is still the only definition and the rendered unit is unchanged.
  services.mp-collector.apiKeyFile = lib.mkDefault "/etc/credentials/mp-collector/mp-api-key";

  # The two ends of the hop above (see modules/monitoring-platform-tunnel.nix). The server half
  # answers on an iroh endpoint and forwards to the receiver's socket; the client half serves
  # the socket the collector posts to and dials that endpoint. Separate credential directories
  # because they hold different things -- an identity and an address -- and because the server's
  # secret must not be the ssh tunnel's (both listeners answer the same ALPN, so one key would
  # make sshd and the receiver indistinguishable to a dialer; the module asserts this).
  #
  # The tunnel authenticates nobody: anyone holding the endpoint id can open the pipe. The gate
  # is the API key above, which the receiver checks on every batch.
  #
  # Provision out-of-band, ON THIS HOST, before deploying this -- a missing blob leaves the unit
  # *skipped* by ConditionPathExists rather than failed, and the collector then spools to the SD
  # with nothing obviously broken. The ticket is a pure function of the secret, so the second
  # command can be re-run any time to recover it:
  #   iroh-ssh-generate-secret \
  #   | systemd-creds encrypt --name=iroh-secret - /etc/credentials/mp-tunnel/server/iroh-secret
  #
  #   systemd-creds decrypt --name=iroh-secret /etc/credentials/mp-tunnel/server/iroh-secret - \
  #   | iroh-ssh-ticket /dev/stdin \
  #   | systemd-creds encrypt --name=iroh-ticket - /etc/credentials/mp-tunnel/client/iroh-ticket
  common.mpTunnel.server = {
    enable = true;
    credentialDirectory = "/etc/credentials/mp-tunnel/server";
  };
  common.mpTunnel.client = {
    enable = true;
    credentialDirectory = "/etc/credentials/mp-tunnel/client";
  };

  # First producer: CPU, memory, filesystem usage and the current NixOS generation, every 15
  # minutes. Wired from the collector's own options rather than restating its defaults, so the
  # socket path and group cannot drift apart -- and pointed at the collector rather than the
  # receiver so this block needs no edit when the receiver moves.
  common.systemMetrics = {
    enable = true;
    socketPath = config.services.mp-collector.socketPath;
    group = config.services.mp-collector.group;
  };

  # Second producer: the devices this host can see, on the module's default 15-minute cadence the
  # spec asks for -- the same one the metrics producer runs. The radio collectors are on because
  # this host's whole USB fault story this summer was invisible without them; the price is that
  # every tick takes the radio off-channel for a few seconds, and wlan0 is how this host is reached.
  common.detectedDevices = {
    enable = true;
    socketPath = config.services.mp-collector.socketPath;
    group = config.services.mp-collector.group;
    usb.enable = true;
    wifi.enable = true;
    wifi.interface = "wlan0";
    bluetooth.enable = true;
  };

  # Third producer: the solar inverter on the USB serial adapter, one record a minute. Same
  # wiring rule as above -- socket and group come from the collector, not from restated
  # defaults. Everything else (2400 8N1, the command set, the 15-minute restart) is protocol or
  # spec and lives in the module.
  common.inverterMonitoring = {
    enable = true;
    socketPath = config.services.mp-collector.socketPath;
    group = config.services.mp-collector.group;
  };

  # Fourth producer: the battery BMS on the other USB serial adapter. Same wiring rule again.
  #
  # This one and the inverter above share the /dev/ttyUSB* pool and both start at boot, which is
  # the one interaction worth knowing about at the host level: they arbitrate with an advisory
  # flock on the device node, so no ordering or device pinning is declared here and none is needed.
  # See modules/bms-monitoring.nix for what that costs and why the alternative (udev-pinning each
  # cable to a fixed node) was not taken.
  #
  # Note the record cost, which is higher than the other three producers put together: a status row
  # plus one row per cell every minute, ~8.9M rows a year for a 16-cell pack. That is deliberate --
  # per-cell divergence is the whole reason to monitor a battery -- but it is the first thing to
  # turn down if the SD card fills.
  common.bmsMonitoring = {
    enable = true;
    socketPath = config.services.mp-collector.socketPath;
    group = config.services.mp-collector.group;
  };

  users.users.nixos = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    packages = [ nixUtils ];  # sandboxed nix-utils on the user's PATH only
    openssh.authorizedKeys.keys = [ (import ../../lib/ssh-keys.nix).sashee ];
  };

  # Nightly backup of the measurement database (restic module imported above). Runs as the
  # receiver's own user: the state directory is 0700 and this unit has CapabilityBoundingSet=""
  # plus PrivateUsers=true, so even root would not get in. The receiver is stopped for the
  # backup phase only -- the DB is WAL-mode, so its files are consistent on disk only while it
  # is down -- and started again before the prune and check phases (see modules/restic.nix).
  # The tunnel needs no such treatment: it dials the receiver's socket lazily, once per stream,
  # so it rides out the restart (the note on its `after` in modules/monitoring-platform-tunnel.nix).
  #
  # Off the default midnight slot: the auto-upgrade starts 00:00-02:00 and nix-gc runs
  # 03:15/15:15, and all three are SD-I/O bound on this box.
  #
  # The repository location is a credential too, not config: this repo is public, so the URL
  # would otherwise be in git (and, via upstream's PATH wrapper, in a world-readable store path).
  #
  # Provision out-of-band, ON THIS HOST -- there is no TPM on a Pi 5, so systemd-creds falls back
  # to the host key (/var/lib/systemd/credential.secret) and a reimaged SD needs fresh blobs. All
  # four must exist: the unit's ConditionPathExists lists them, so a missing one makes systemd
  # *skip* the unit rather than fail it, which shows up only as a monitoring check that never
  # goes green. The file name and the --name= must match; the name is authenticated into the blob.
  #   sudo install -d -m 0700 /etc/credentials/restic/monitoring-platform
  #   printf '%s' 'rest:https://<host>/' | sudo systemd-creds encrypt --name=repository - \
  #     /etc/credentials/restic/monitoring-platform/repository
  #   printf '%s' '<repo password>' | sudo systemd-creds encrypt --name=repository-password - \
  #     /etc/credentials/restic/monitoring-platform/repository-password
  #   printf '%s' '<rest user>'     | sudo systemd-creds encrypt --name=backend-username - \
  #     /etc/credentials/restic/monitoring-platform/backend-username
  #   printf '%s' '<rest password>' | sudo systemd-creds encrypt --name=backend-password - \
  #     /etc/credentials/restic/monitoring-platform/backend-password
  #   sudo chmod 0600 /etc/credentials/restic/monitoring-platform/*
  #
  # /var/lib/mp-collector is deliberately not in paths: spool plus epoch table, rebuilt from
  # scratch. Nor are the credential blobs -- host-key-encrypted, so useless off this SD.
  common.restic.backups.monitoring-platform = resticLib.rest {
    user = config.services.monitoring-platform.user;
    credentialDirectory = "/etc/credentials/restic/monitoring-platform";
    paths = [ "/var/lib/monitoring-platform" ];
    stopServices = [ "monitoring-platform.service" ];
    timerConfig = {
      OnCalendar = "*-*-* 05:00:00";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };

  networking.wireless.iwd.enable = true;
  common.connectivityFallback.enable = true;
  # The other half of the connectivity story: connectivityFallback only reacts to "not
  # associated to any wifi", because its remedy is new credentials. This one covers
  # associated-but-the-stack-is-wedged (brcmfmac firmware halt, wedged dnscrypt, an IPv4LL
  # lease) by rebooting after a day with no DNS at all -- on a headless box with no LAN
  # access that is otherwise a trip to the device.
  common.connectivityWatchdog.enable = true;
  # SSH over iroh (see modules/iroh-ssh.nix): sshd is reached through the tunnel's
  # outbound connection, so no inbound port is needed. Secret provisioned out-of-band:
  #   iroh-ssh-generate-secret | systemd-creds encrypt --name=iroh-secret - /etc/credentials/iroh-ssh/iroh-secret
  common.irohSsh.credentialDirectory = "/etc/credentials/iroh-ssh";
  services.openssh.enable = true;
  # nix-utils runs git/ssh in a bubblewrap userns where root-owned store files
  # appear as 'nobody', so OpenSSH rejects the Include'd systemd-ssh-proxy config
  # ("Bad owner or permissions"). We don't use the proxy, so drop the Include.
  programs.ssh.systemd-ssh-proxy.enable = false;
  services.openssh.settings.PasswordAuthentication = false;
  security.sudo.wheelNeedsPassword = false;
  # The literal lives in a file so flake.nix can read it without evaluating a system;
  # see hosts/rpi5/state-version.nix. This is still the only definition.
  system.stateVersion = lib.mkDefault (import ./state-version.nix);
  # Real system tools for root/services (flakes, auto-upgrade). The sandboxed
  # nix-utils tools live on the nixos user PATH only (see users.users.nixos).
  environment.systemPackages = [ pkgs.git ];

  # The bumped rpi kernel (6.18.34-unstable_20260604) no longer builds tpm-crb as a
  # module, but systemd-initrd TPM2 support pulls tpm-crb into
  # boot.initrd.availableKernelModules on aarch64, so the initrd module closure fails
  # with "modprobe: FATAL: Module tpm-crb not found". The Pi 5 has no TPM, so disable it.
  boot.initrd.systemd.tpm2.enable = false;

  # Fail the build (and so the nightly auto-upgrade) if the configured kernel
  # is missing any module the Pi uses -- a loud, pre-reboot error when switching
  # kernels (e.g. to mainline) instead of dead hardware after the upgrade reboot.
  common.requiredKernelModules = {
    enable = true;
    file = ./required-modules.txt;
  };

  boot.kernelPatches = [{
    name = "headless-trim";
    patch = null;
    structuredExtraConfig = {
      # ---- KERNEL DEBUG INFO: OFF (must stay off on this hardware) ----
      # We disable DWARF debug info + BTF. WHY: with debug info ON (which is what
      # BTF requires), the vmlinux + ~thousands of modules' debug info overflow the
      # 29 GB SD card during the build and it dies at `modules_install` with
      # "No space left on device" -- confirmed even WITH zlib-compressed debug info
      # AND an aggressive module trim (~3.6k modules) at 2h7m. So debug info only
      # fits on bigger/faster storage (e.g. a USB SSD); re-enable there.
      # Cost of OFF: no BTF -> systemd RestrictFileSystems= no-ops (the harmless
      # `bpf-restrict-fs` boot message) and bpftrace/CO-RE eBPF is unavailable.
      # Backtraces stay symbolized (kallsyms), ftrace/perf still work.
      DEBUG_INFO_BTF = no; DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT = no; DEBUG_INFO_DWARF4 = no; DEBUG_INFO_DWARF5 = no; DEBUG_INFO_NONE = yes;

      # ================================================================
      # HEADLESS MODULE TRIM -- DISABLED (all modules build). Uncomment the
      # block below to cut drivers this Pi never loads (~74 of ~5k are used),
      # dropping the build from ~6.5k modules toward ~3.6k (faster/smaller).
      # Keep NIC=macb (Cadence) + WiFi=brcmfmac (Broadcom) enabled.
      # NOTE: HWMON can't be disabled here (THERMAL force-selects it).
      # ================================================================
      #
      # # Discrete/desktop GPUs (keep vc4/v3d)
      # DRM_AMDGPU = no; DRM_NOUVEAU = no; DRM_I915 = no; DRM_XE = no; DRM_RADEON = no;
      # DRM_AST = no; DRM_VMWGFX = no; DRM_GMA500 = no; DRM_QXL = no; DRM_VBOXVIDEO = no;
      # DRM_VIRTIO_GPU = no;
      #
      # # Sound/audio; whole media subsystem (no camera/TV); IIO analog sensors
      # SOUND = no;
      # MEDIA_SUPPORT = no;
      # IIO = no;
      #
      # # Input: keep keyboard/mouse/evdev; drop joysticks/touch/tablets/misc
      # INPUT_JOYSTICK = no; INPUT_JOYDEV = no; INPUT_TOUCHSCREEN = no;
      # INPUT_TABLET = no; INPUT_MISC = no;
      #
      # # Staging drivers; USB-serial converter zoo
      # STAGING = no; USB_SERIAL = no;
      #
      # # Wired NIC vendors (keep CADENCE=macb)
      # NET_VENDOR_BROADCOM = no; NET_VENDOR_MARVELL = no; NET_VENDOR_MELLANOX = no;
      # NET_VENDOR_INTEL = no; NET_VENDOR_CHELSIO = no; NET_VENDOR_EMULEX = no;
      # NET_VENDOR_QLOGIC = no; NET_VENDOR_NETRONOME = no; NET_VENDOR_PENSANDO = no;
      # NET_VENDOR_CAVIUM = no; NET_VENDOR_HUAWEI = no; NET_VENDOR_AQUANTIA = no;
      # NET_VENDOR_SOLARFLARE = no; NET_VENDOR_AMD = no; NET_VENDOR_QUALCOMM = no;
      # NET_VENDOR_HISILICON = no; NET_VENDOR_REALTEK = no; NET_VENDOR_MICROCHIP = no;
      # NET_VENDOR_RENESAS = no; NET_VENDOR_STMICRO = no; NET_VENDOR_SAMSUNG = no;
      # NET_VENDOR_SOCIONEXT = no; NET_VENDOR_WANGXUN = no; NET_VENDOR_FUNGIBLE = no;
      # NET_VENDOR_NVIDIA = no; NET_VENDOR_GOOGLE = no; NET_VENDOR_AMAZON = no;
      # NET_VENDOR_META = no; NET_VENDOR_MICROSOFT = no; NET_VENDOR_CISCO = no;
      #
      # # Other Wi-Fi vendors + Broadcom softmac (keep brcmfmac fullmac)
      # WLAN_VENDOR_INTEL = no; WLAN_VENDOR_MEDIATEK = no; WLAN_VENDOR_RALINK = no;
      # WLAN_VENDOR_REALTEK = no; WLAN_VENDOR_ATH = no; WLAN_VENDOR_MARVELL = no;
      # WLAN_VENDOR_INTERSIL = no; WLAN_VENDOR_TI = no; WLAN_VENDOR_RSI = no;
      # WLAN_VENDOR_QUANTENNA = no; WLAN_VENDOR_SILABS = no; WLAN_VENDOR_ATMEL = no;
      # WLAN_VENDOR_ZYDAS = no; WLAN_VENDOR_ADMTEK = no; BRCMSMAC = no;
      #
      # # Enterprise SCSI/FC/RAID + SATA/PATA; RAID levels (keep dm_mod)
      # SCSI_LOWLEVEL = no; FUSION = no; ATA = no;
      # MD_RAID0 = no; MD_RAID1 = no; MD_RAID10 = no; MD_RAID456 = no; MD_MULTIPATH = no;
      #
      # # Exotic/enterprise filesystems (keep ext4/vfat/overlay/tmpfs/fuse; zfs via nixos)
      # XFS_FS = no; BTRFS_FS = no; F2FS_FS = no; GFS2_FS = no; OCFS2_FS = no;
      # NILFS2_FS = no; JFS_FS = no; REISERFS_FS = no; UBIFS_FS = no; CEPH_FS = no;
      # NFS_FS = no; NFSD = no; CIFS = no;
      #
      # # Exotic net protocols; VM-guest; Thunderbolt; lab DAQ; IB; CAN; ham/legacy
      # TIPC = no; SCTP = no; RDS = no; L2TP = no; VSOCKETS = no;
      # XEN = no; USB4 = no; COMEDI = no; INFINIBAND = no; CAN = no; HAMRADIO = no;
      # ATM = no; X25 = no;
    };
  }];
}
