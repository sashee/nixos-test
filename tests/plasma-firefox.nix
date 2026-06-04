{ nixpkgs, pkgs, commonDesktopModule, qemuDemoUserModule, stateVersion }:

let
  testHttpServer = pkgs.writeText "plasma-firefox-http-server.py" ''
    import http.server
    import pathlib
    import socketserver


    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            markers = {
                "/firefox.html": "/tmp/request-firefox",
                "/lo-real.html": "/tmp/request-lo-real",
                "/lo-wrapped.html": "/tmp/request-lo-wrapped",
                "/lo-desktop.html": "/tmp/request-lo-desktop",
            }
            if self.path in markers:
                pathlib.Path(markers[self.path]).touch()

            body = b"<!doctype html><title>NixOS VM test</title><h1>HTTP request received</h1>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format, *args):
            pass


    class Server(socketserver.TCPServer):
        allow_reuse_address = True


    with Server(("127.0.0.1", 8000), Handler) as server:
        pathlib.Path("/tmp/test-http-ready").touch()
        server.serve_forever()
  '';
in
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

    machine.succeed("rm -f /tmp/test-http-ready /tmp/request-firefox /tmp/request-lo-real /tmp/request-lo-wrapped /tmp/request-lo-desktop")
    machine.succeed("systemd-run --unit test-http-server ${pkgs.python3}/bin/python3 ${testHttpServer}")
    machine.wait_for_unit("test-http-server.service")
    machine.wait_until_succeeds("test -e /tmp/test-http-ready")
    machine.succeed("curl --fail http://127.0.0.1:8000/firefox.html")

    machine.succeed("su - demo -c 'firefox --headless --screenshot /tmp/firefox-page.png http://127.0.0.1:8000/firefox.html >/tmp/firefox.log 2>&1'")
    machine.succeed("test -s /tmp/firefox-page.png")
    machine.copy_from_vm("/tmp/firefox-page.png")

    machine.succeed("rm -rf /tmp/lo-real-profile /tmp/lo-wrapped-profile /tmp/lo-real-out /tmp/lo-wrapped-out")
    machine.succeed("mkdir -p /tmp/lo-real-out /tmp/lo-wrapped-out")
    machine.succeed("${pkgs.coreutils}/bin/timeout 60 ${pkgs.libreoffice-qt6-still}/bin/libreoffice --headless -env:UserInstallation=file:///tmp/lo-real-profile --convert-to pdf --outdir /tmp/lo-real-out http://127.0.0.1:8000/lo-real.html || true")
    machine.wait_until_succeeds("test -e /tmp/request-lo-real")

    machine.succeed("su - demo -c 'XDG_RUNTIME_DIR=/run/user/1000 ${pkgs.coreutils}/bin/timeout 30 /run/current-system/sw/bin/libreoffice --headless -env:UserInstallation=file:///tmp/lo-wrapped-profile --convert-to pdf --outdir /tmp/lo-wrapped-out http://127.0.0.1:8000/lo-wrapped.html || true'")
    machine.succeed("sleep 2")
    machine.fail("test -e /tmp/request-lo-wrapped")

    machine.succeed("pkill -u demo -f libreoffice || true")
    machine.succeed("rm -f /tmp/lo-desktop.log")
    machine.succeed("su - demo -c '(${pkgs.coreutils}/bin/env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus XDG_DATA_DIRS=/run/current-system/sw/share WAYLAND_DISPLAY=wayland-0 ${pkgs.coreutils}/bin/timeout 45 ${pkgs.gtk3}/bin/gtk-launch writer http://127.0.0.1:8000/lo-desktop.html >/tmp/lo-desktop.log 2>&1 || true) &'")
    machine.wait_until_succeeds("grep -F 'lo-desktop.html' /tmp/lo-desktop.log")
    machine.fail("test -e /tmp/request-lo-desktop")
    machine.succeed("pkill -u demo -f libreoffice || true")
  '';
}
