{ config, lib, pkgs, ... }:

let
  firefoxLanguage = builtins.head (builtins.split "[_.]" config.common.locale.default);

  withoutNetwork = name: package: pkgs.symlinkJoin {
    inherit name;
    paths = [ package ];

    postBuild = ''
      rm -rf $out/bin
      mkdir -p $out/bin

      for exe in ${package}/bin/*; do
        name="$(basename "$exe")"
        cat > "$out/bin/$name" <<EOF
#!${pkgs.runtimeShell}
exec ${pkgs.bubblewrap}/bin/bwrap --unshare-net --die-with-parent --dev-bind / / -- "$exe" "\$@"
EOF
        chmod +x "$out/bin/$name"
      done
    '';
  };

  keepassxcOffline = withoutNetwork "keepassxc-offline" pkgs.keepassxc;
  libreofficeOffline = withoutNetwork "libreoffice-offline" pkgs.libreoffice-qt6-still;
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
    keepassxcOffline
    libreofficeOffline
  ];
}
