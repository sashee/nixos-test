{ config, pkgs, lib, dotfiles, nixpkgs-stable, nixpkgs-unstable, ... }:
let
  inherit (pkgs.stdenv.hostPlatform) system;
  stable   = import nixpkgs-stable   { inherit system; config.allowUnfree = true; };
  unstable = import nixpkgs-unstable { inherit system; config.allowUnfree = true; };
  nixUtils = import "${dotfiles}/nix-utils/lib.nix" {
    pkgs  = stable;
    inherit unstable;
    nixgl = null;
    skip  = [ "chromium" "vkquake" "libreoffice" "tor-browser"];
  };
  no = lib.mkForce lib.kernel.no;
  yes = lib.mkForce lib.kernel.yes;
in
{
  imports = [
    ../../modules/nix-settings.nix
    ../../modules/doh.nix
    ../../modules/restic.nix
    ../../modules/auto-upgrade.nix
  ];

  # Daily boot-generation auto-upgrade: pulls the latest `common` from the host
  # flake and rebuilds. Active once /etc/nixos#rpi5 exists (common on github).
  common.autoUpgrade.enable = true;
  common.autoUpgrade.flake = "/etc/nixos#rpi5";
  # Apply kernel/security updates by rebooting after the nightly auto-upgrade
  # (only when the kernel/initrd/kernel-modules actually changed).
  system.autoUpgrade.allowReboot = true;

  networking.hostName = lib.mkDefault "nixos-rpi5";

  # Compressed RAM-backed swap (same mechanism as the laptops); useful on the 4 GB Pi.
  zramSwap.enable = true;

  users.users.nixos = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    packages = [ nixUtils ];  # sandboxed nix-utils on the user's PATH only
    initialPassword = "nixos";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMLL9PCVcxgn98HQPQWNR618rPF0uxnGDQaUNeDCxumI sashee@sashee-laptop"
    ];
  };

  # Host-specific restic backups (restic module imported above), e.g.:
  # common.restic.backups.home = {
  #   repository = "rest:https://backup.example.com/rpi5"; paths = [ "/home/nixos" ];
  #   credentialDirectory = "/etc/credentials/restic/home"; user = "nixos";
  #   backend = { type = "rest"; credentials = [ "backend-username" "backend-password" ]; };
  # };

  networking.wireless.iwd.enable = true;
  services.openssh.enable = true;
  # nix-utils runs git/ssh in a bubblewrap userns where root-owned store files
  # appear as 'nobody', so OpenSSH rejects the Include'd systemd-ssh-proxy config
  # ("Bad owner or permissions"). We don't use the proxy, so drop the Include.
  programs.ssh.systemd-ssh-proxy.enable = false;
  services.openssh.settings.PasswordAuthentication = false;
  security.sudo.wheelNeedsPassword = false;
  system.stateVersion = lib.mkDefault "24.11";
  # Real system tools for root/services (flakes, auto-upgrade). The sandboxed
  # nix-utils tools live on the nixos user PATH only (see users.users.nixos).
  environment.systemPackages = [ pkgs.git ];

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
