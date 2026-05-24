{ pkgs, lib, ... }:

{
  networking.networkmanager.enable = true;

  users.users.demo = {
    isNormalUser = true;
    initialPassword = "demo";
    extraGroups = [ "networkmanager" "wheel" ];
  };

  services.displayManager.autoLogin.enable = true;
  services.displayManager.autoLogin.user = "demo";

  virtualisation = {
    cores = lib.mkDefault 2;
    memorySize = lib.mkDefault 4096;
  };

  environment.systemPackages = with pkgs; [
    curl
    mesa-demos
    vim
  ];
}
