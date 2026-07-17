# Host config for anya-feher-laptop (spec: spec/anya-feher-laptop.md).
# Everything machine-unique (LUKS device, filesystems, CPU microcode kind) lives
# in the on-device hardware-configuration.nix, injected by the laptop's stub
# flake via `common.lib.hosts.anya-feher-laptop { modules = [ ./hardware-configuration.nix ]; }`.
# Cadences deliberately absent: the module defaults already match the spec
# (GC daily + 14d retention, monitoring daily, auto-upgrade switch-on-boot
# without reboot). No restic backups yet; monitoring skips that check.
{ lib, ... }:

{
  imports = [ ../../modules/common-desktop.nix ];

  # mkDefault like the rpi: VM tests set their own hostName/stateVersion.
  networking.hostName = lib.mkDefault "anya-feher-laptop";
  system.stateVersion = lib.mkDefault "26.05";

  time.timeZone = "Europe/Budapest";

  # System and keyboard language is Hungarian. xkb covers the SDDM greeter and
  # X/localed defaults; kwin_wayland (the Plasma session) takes its default from
  # the KDE config cascade, so ship /etc/xdg/kxkbrc as the system-wide default.
  common.locale.default = "hu_HU.UTF-8";
  services.xserver.xkb.layout = "hu";
  console.keyMap = "hu";
  environment.etc."xdg/kxkbrc".text = ''
    [Layout]
    LayoutList=hu
    Use=true
  '';

  # Generic UEFI boot; the disk layout itself is in hardware-configuration.nix.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # anya: primary user, no sudo, auto-logged in; password set imperatively at
  # install (`passwd`, mutableUsers) so no password material lands in this repo.
  # networkmanager group: she joins wifi networks from the Plasma GUI.
  users.users.anya = {
    isNormalUser = true;
    extraGroups = [ "networkmanager" ];
  };
  services.displayManager.autoLogin = {
    enable = true;
    user = "anya";
  };

  # sashee: admin over ssh only. No password options -> the account stays
  # locked: no password/console login, key-only ssh; sudo must therefore not
  # prompt for a password.
  users.users.sashee = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    openssh.authorizedKeys.keys = [ (import ../../lib/ssh-keys.nix).sashee ];
  };
  services.openssh.settings.PasswordAuthentication = false;
  security.sudo.wheelNeedsPassword = false;

  # Never suspend (the machine must stay reachable over iroh while powered on).
  systemd.sleep.settings.Sleep = {
    AllowSuspend = "no";
    AllowHibernation = "no";
    AllowHybridSleep = "no";
    AllowSuspendThenHibernate = "no";
  };
  # Lid close locks the session instead of sleeping.
  services.logind.settings.Login = {
    HandleLidSwitch = "lock";
    HandleLidSwitchExternalPower = "lock";
  };
  # Inactivity locks: kscreenlocker is per-user config, so ship the system-wide
  # default (users can still tighten it in their session). 10 minutes; the spec
  # only mandates that inactivity locks, not the duration.
  environment.etc."xdg/kscreenlockerrc".text = ''
    [Daemon]
    Autolock=true
    LockOnResume=true
    Timeout=10
  '';

  # Spec: bluetooth disabled (laptop-base enables it at normal priority).
  hardware.bluetooth.enable = lib.mkForce false;
  services.blueman.enable = lib.mkForce false;

  # Auto-upgrade pulls the latest `common` via the on-device stub flake.
  common.autoUpgrade.flake = "/etc/nixos#anya-feher-laptop";

  # Encrypted credentials provisioned on-device (same convention as the rpi,
  # see docs/rpi5-rescue.md): systemd-creds encrypt --name=<name> - <dir>/<name>
  common.irohSsh.credentialDirectory = "/etc/credentials/iroh-ssh";
  common.monitoring.report.credentialDirectory = "/etc/credentials/monitoring";
}
