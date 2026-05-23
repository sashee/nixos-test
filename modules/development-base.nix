{ pkgs, ... }:

{
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  environment.systemPackages = with pkgs; [
    curl
    fd
    git
    htop
    jq
    ripgrep
    tree
    unzip
    vim
    wget
  ];
}
