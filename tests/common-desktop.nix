{ nixpkgs, pkgs, commonDesktopModule, qemuDemoUserModule, stateVersion }:

nixpkgs.lib.nixos.runTest {
  name = "common-desktop";
  hostPkgs = pkgs;
  globalTimeout = 300;

  nodes.machine = {
    imports = [
      commonDesktopModule
      qemuDemoUserModule
    ];

    networking.hostName = "common-desktop-test";
    common.autoUpgrade.enable = false;
    common.monitoring.enable = false;
    common.irohSsh.enable = false;
    system.stateVersion = stateVersion;
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("graphical.target")
    machine.wait_until_succeeds("pgrep -u demo plasmashell")
    machine.wait_until_succeeds("pgrep -u demo kwin_wayland")

    machine.succeed("systemctl is-active NetworkManager.service")
    machine.succeed("systemctl is-enabled bluetooth.service")
    machine.succeed("systemctl is-active cups.socket")
    machine.wait_until_succeeds("systemctl is-active upower.service")
    machine.succeed("(systemctl is-enabled power-profiles-daemon.service || true) | grep -E '^(enabled|linked)$'")

    machine.succeed("command -v keepassxc")
    machine.succeed("command -v libreoffice")
    machine.succeed("command -v nvim")
    machine.succeed("command -v zsh")
    machine.succeed("command -v tmux")
    machine.succeed("command -v all-info-json")

    machine.succeed("test -e /run/current-system/sw/share/applications/writer.desktop")
    machine.succeed("test -e /run/current-system/sw/share/applications/calc.desktop")
    machine.succeed("test -e /run/current-system/sw/share/applications/impress.desktop")
    machine.succeed("test -e /run/current-system/sw/share/applications/chromium-browser.desktop")
    machine.succeed("test -e /run/current-system/sw/share/applications/org.keepassxc.KeePassXC.desktop")
    machine.succeed("test -e /run/current-system/sw/share/applications/vlc.desktop")
    machine.succeed("test -e /run/current-system/sw/share/applications/org.flameshot.Flameshot.desktop")

    machine.succeed("grep -E '^Exec=/nix/store/.*/bin/libreoffice --writer %U$' /run/current-system/sw/share/applications/writer.desktop")
    machine.succeed("grep -E '^Exec=/nix/store/.*/bin/libreoffice --calc %U$' /run/current-system/sw/share/applications/calc.desktop")
    machine.succeed("grep -E '^Exec=/nix/store/.*/bin/libreoffice --impress %U$' /run/current-system/sw/share/applications/impress.desktop")
    machine.succeed("grep -E '^Exec=/nix/store/.*/bin/chromium %U$' /run/current-system/sw/share/applications/chromium-browser.desktop")
    machine.succeed("grep -E '^Exec=/nix/store/.*/bin/chromium --incognito$' /run/current-system/sw/share/applications/chromium-browser.desktop")
    machine.succeed("grep -E '^Exec=/nix/store/.*/bin/keepassxc %f$' /run/current-system/sw/share/applications/org.keepassxc.KeePassXC.desktop")
    machine.succeed("grep -E '^TryExec=/nix/store/.*/bin/keepassxc$' /run/current-system/sw/share/applications/org.keepassxc.KeePassXC.desktop")
    machine.succeed("grep -E '^Exec=/nix/store/.*/bin/vlc ' /run/current-system/sw/share/applications/vlc.desktop")
    machine.succeed("grep -E '^Exec=/nix/store/.*/bin/flameshot' /run/current-system/sw/share/applications/org.flameshot.Flameshot.desktop")

    machine.succeed("test -e /run/current-system/sw/share/icons/hicolor/256x256/apps/chromium.png")
    machine.succeed("test -e /run/current-system/sw/share/icons/hicolor/scalable/apps/keepassxc.svg")
    machine.succeed("test -e /run/current-system/sw/share/icons/hicolor/128x128/apps/vlc.png")
    machine.succeed("test -e /run/current-system/sw/share/icons/hicolor/scalable/apps/org.flameshot.Flameshot.svg")
    machine.succeed("test -e /run/current-system/sw/share/icons/hicolor/scalable/apps/libreoffice-writer.svg")

    machine.succeed("${pkgs.desktop-file-utils}/bin/desktop-file-validate /run/current-system/sw/share/applications/writer.desktop /run/current-system/sw/share/applications/calc.desktop /run/current-system/sw/share/applications/impress.desktop /run/current-system/sw/share/applications/chromium-browser.desktop /run/current-system/sw/share/applications/org.keepassxc.KeePassXC.desktop /run/current-system/sw/share/applications/vlc.desktop /run/current-system/sw/share/applications/org.flameshot.Flameshot.desktop")
  '';
}
