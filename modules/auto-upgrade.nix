{ config, lib, ... }:

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

  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.flake != null;
        message = "common.autoUpgrade.flake must be set when common.autoUpgrade.enable is true.";
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
  };
}
