{ pkgs, commonDotfiles, ... }:

let
  nixUtils = import "${commonDotfiles}/nix-utils" {
    inherit pkgs;
    unstable = pkgs;
    nixgl = null;
  };

  nixUtilsDesktopEntries = pkgs.runCommand "nix-utils-desktop-entries" { } ''
    mkdir -p $out/share/applications
    mkdir -p $out/share/icons

    cp ${pkgs.libreoffice}/share/applications/*.desktop $out/share/applications/
    cp ${pkgs.chromium.browser}/share/applications/*.desktop $out/share/applications/
    cp ${pkgs.keepassxc}/share/applications/*.desktop $out/share/applications/
    cp ${pkgs.vlc}/share/applications/*.desktop $out/share/applications/
    cp ${pkgs.flameshot}/share/applications/*.desktop $out/share/applications/

    cp -r --no-preserve=mode,ownership ${pkgs.libreoffice}/share/icons/* $out/share/icons/
    cp -r --no-preserve=mode,ownership ${pkgs.chromium.browser}/share/icons/* $out/share/icons/
    cp -r --no-preserve=mode,ownership ${pkgs.keepassxc}/share/icons/* $out/share/icons/
    cp -r --no-preserve=mode,ownership ${pkgs.vlc}/share/icons/* $out/share/icons/
    cp -r --no-preserve=mode,ownership ${pkgs.flameshot}/share/icons/* $out/share/icons/

    substituteInPlace $out/share/applications/{base,calc,draw,impress,math,startcenter,writer,xsltfilter}.desktop \
      --replace-fail "Exec=libreoffice" "Exec=${nixUtils}/bin/libreoffice"
    substituteInPlace $out/share/applications/chromium-browser.desktop \
      --replace-fail "Exec=chromium" "Exec=${nixUtils}/bin/chromium"
    substituteInPlace $out/share/applications/org.keepassxc.KeePassXC.desktop \
      --replace-fail "Exec=keepassxc" "Exec=${nixUtils}/bin/keepassxc"
    substituteInPlace $out/share/applications/vlc.desktop \
      --replace-fail "Exec=${pkgs.vlc}/bin/vlc" "Exec=${nixUtils}/bin/vlc"
    substituteInPlace $out/share/applications/org.flameshot.Flameshot.desktop \
      --replace-fail "Exec=${pkgs.flameshot}/bin/flameshot" "Exec=${nixUtils}/bin/flameshot" \
      --replace-fail "Exec=flameshot" "Exec=${nixUtils}/bin/flameshot"
  '';
in
{
  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = [
    nixUtils
    nixUtilsDesktopEntries
  ];
}
