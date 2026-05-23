{ pkgs, ... }:

{
  system.stateVersion = "25.11";

  networking.networkmanager.enable = true;

  users.users.demo = {
    isNormalUser = true;
    initialPassword = "demo";
    extraGroups = [ "networkmanager" "wheel" ];
  };

  services.displayManager.autoLogin.enable = true;
  services.displayManager.autoLogin.user = "demo";

  environment.systemPackages = with pkgs; [
    curl
    mesa-demos
    vim
  ];
}
