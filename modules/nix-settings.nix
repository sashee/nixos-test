{ config, lib, ... }:

let
  cfg = config.common.nixSettings;
in
{
  options.common.nixSettings.gcOptions = lib.mkOption {
    type = lib.types.str;
    default = "--delete-older-than 14d";
    example = "--delete-old";
    description = ''
      Arguments passed to nix-collect-garbage for the automatic GC. Default keeps
      14 days of generations (laptops, which have a boot menu to roll back from).
      Hosts with no interactive boot selection and tight disk (e.g. the Pi) can
      use "--delete-old" to keep only the current generation.
    '';
  };

  config = {
    nix = {
      gc = {
        automatic = true;
        options = cfg.gcOptions;
      };

      settings = {
        auto-optimise-store = true;
        # Fsync store path contents before registering them in the Nix DB, so a
        # power cut mid-upgrade/GC can't leave a path registered as valid with
        # non-durable contents. Costs some write speed on builds/substitutions.
        fsync-store-paths = true;
        experimental-features = [ "nix-command" "flakes" ];
      };
    };
  };
}
