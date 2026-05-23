{ pkgs, ... }:

{
  services.displayManager.sddm.enable = true;
  services.desktopManager.plasma6.enable = true;
  services.displayManager.defaultSession = "plasma";

  hardware.graphics.enable = true;

  environment.systemPackages = with pkgs; [
    firefox
    kdePackages.konsole
  ];
}
