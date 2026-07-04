{ config, lib, pkgs, ... }:

let
  cfg = config.common.autoUpgrade;
  flakeRoot = if cfg.flake == null then null else builtins.head (lib.splitString "#" cfg.flake);
  updateCommand = lib.optionalString (flakeRoot != null) (lib.escapeShellArgs [
    "nix"
    "flake"
    "update"
    "common"
    "--flake"
    flakeRoot
    "--commit-lock-file"
  ]);

  # Reboot after a successful boot-generation upgrade when the freshly-built generation differs
  # from the running system. operation = "boot" already made it the default generation, so the
  # reboot just activates it. Compares the full system toplevel, so ANY change triggers a reboot --
  # unlike system.autoUpgrade.allowReboot, which reboots only on kernel/initrd/kernel-modules changes.
  rebootIfChanged = pkgs.writeShellApplication {
    name = "nixos-upgrade-reboot-if-changed";
    runtimeInputs = [ pkgs.coreutils config.systemd.package ];
    text = ''
      booted="$(readlink -f /run/booted-system)"
      built="$(readlink -f /nix/var/nix/profiles/system)"
      if [ "$booted" != "$built" ]; then
        echo "auto-upgrade: new generation differs from booted system; scheduling reboot"
        shutdown -r +1
      fi
    '';
  };
in
{
  options.common.autoUpgrade = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to enable automatic NixOS boot-generation updates.";
    };

    flake = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/etc/nixos#my-laptop";
      description = ''
        Flake URI and NixOS configuration attribute used by nixos-rebuild.
      '';
    };

    rebootOnChange = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Reboot (via `shutdown -r +1`) after a successful upgrade whenever the new boot
        generation differs from the currently running system -- i.e. on ANY change, not only
        kernel/initrd/kernel-modules changes (which is all `system.autoUpgrade.allowReboot`
        covers). Enable only one of the two reboot paths.
      '';
    };

  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.flake != null;
        message = "common.autoUpgrade.flake must be set when common.autoUpgrade.enable is true.";
      }
      {
        assertion = !(cfg.rebootOnChange && config.system.autoUpgrade.allowReboot);
        message = "common.autoUpgrade.rebootOnChange and system.autoUpgrade.allowReboot both reboot after an upgrade; enable only one.";
      }
    ];

    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    system.autoUpgrade = {
      enable = true;
      inherit (cfg) flake;
      dates = "daily";
      flags = [
        "--print-build-logs"
        "--commit-lock-file"
      ];
      operation = "boot";
      randomizedDelaySec = "2h";
    };

    systemd.services.nixos-upgrade.environment = {
      GIT_AUTHOR_NAME = "NixOS Auto-upgrade";
      GIT_AUTHOR_EMAIL = "root@${config.networking.hostName}";
      GIT_COMMITTER_NAME = "NixOS Auto-upgrade";
      GIT_COMMITTER_EMAIL = "root@${config.networking.hostName}";
    };

    systemd.services.nixos-upgrade.preStart = updateCommand;

    # After a successful boot-generation upgrade, reboot if anything changed (opt-in). Runs only
    # on ExecStart success and exits 0 either way, so the unit still succeeds and nixos-upgrade's
    # OnSuccess (the monitoring last-success marker) still fires before the +1min reboot.
    systemd.services.nixos-upgrade.serviceConfig.ExecStartPost =
      lib.mkIf cfg.rebootOnChange (lib.getExe rebootIfChanged);

    # The system `git` may be a sandboxed wrapper (nix-utils) that cannot write
    # outside the user's home; auto-upgrade commits the lock in the flake dir
    # (e.g. /etc/nixos), so ensure a real git is first on the service PATH.
    systemd.services.nixos-upgrade.path = lib.mkBefore [ pkgs.git ];
  };
}
