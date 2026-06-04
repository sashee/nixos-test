{ pkgs, commonDotfiles, ... }:

let
  nixUtils = import "${commonDotfiles}/nix-utils" {
    inherit pkgs;
    unstable = pkgs;
    nixgl = null;
  };
in
{
  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = [
    nixUtils
  ];
}
