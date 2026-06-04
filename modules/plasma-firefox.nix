{ config, lib, pkgs, ... }:

let
  firefoxLanguage = builtins.head (builtins.split "[_.]" config.common.locale.default);
in
{
  programs.firefox = {
    enable = true;
    languagePacks = lib.optional (firefoxLanguage != "en") firefoxLanguage;
    preferences."intl.locale.requested" = firefoxLanguage;
  };

  services.displayManager.sddm.enable = true;
  services.desktopManager.plasma6.enable = true;
  services.displayManager.defaultSession = "plasma";

  hardware.graphics.enable = true;

  environment.systemPackages = with pkgs; [
    kdePackages.konsole
  ];
}
