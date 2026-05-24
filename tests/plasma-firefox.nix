{ nixpkgs, pkgs, commonDesktopModule, qemuDemoUserModule, stateVersion }:

nixpkgs.lib.nixos.runTest {
  name = "plasma-firefox";
  hostPkgs = pkgs;
  globalTimeout = 300;

  nodes.machine = {
    imports = [
      commonDesktopModule
      qemuDemoUserModule
    ];

    networking.hostName = "plasma-firefox-test";
    system.stateVersion = stateVersion;

    services.displayManager.defaultSession = "plasma";
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("graphical.target")
    machine.wait_until_succeeds("pgrep -u demo plasmashell")
    machine.wait_until_succeeds("pgrep -u demo kwin_wayland")
    machine.screenshot("plasma-desktop")

    machine.succeed("mkdir -p /tmp/site")
    machine.succeed("printf '%s\n' '<!doctype html><title>NixOS VM test</title><h1>Firefox started</h1>' > /tmp/site/index.html")
    machine.succeed("systemd-run --unit test-http-server --property WorkingDirectory=/tmp/site ${pkgs.python3}/bin/python3 -m http.server 8000")
    machine.wait_for_unit("test-http-server.service")
    machine.wait_until_succeeds("curl --fail --head http://127.0.0.1:8000/")

    machine.succeed("su - demo -c 'firefox --headless --screenshot /tmp/firefox-page.png http://127.0.0.1:8000/ >/tmp/firefox.log 2>&1'")
    machine.succeed("test -s /tmp/firefox-page.png")
    machine.copy_from_vm("/tmp/firefox-page.png")
  '';
}
