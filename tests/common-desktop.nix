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
  '';
}
