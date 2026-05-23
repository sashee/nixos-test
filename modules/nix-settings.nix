{
  nix = {
    gc = {
      automatic = true;
      options = "--delete-older-than 14d";
    };

    settings = {
      auto-optimise-store = true;
      experimental-features = [ "nix-command" "flakes" ];
    };
  };
}
