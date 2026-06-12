{ nixpkgs, pkgs, commonDesktopModule, qemuDemoUserModule, stateVersion }:

let
  testHttpServer = pkgs.writeText "locale-firefox-http-server.py" ''
    import http.server
    import pathlib
    import socketserver


    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/firefox.html":
                pathlib.Path("/tmp/request-firefox").touch()

            body = b"<!doctype html><title>Locale test</title><h1>Firefox locale test</h1>"
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

  firefoxGuiCommand = "env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus MOZ_ENABLE_WAYLAND=1 firefox http://127.0.0.1:8000/firefox.html >/tmp/firefox-gui.log 2>&1 &";
in
nixpkgs.lib.nixos.runTest {
  name = "locale-firefox";
  hostPkgs = pkgs;
  globalTimeout = 420;

  nodes.english = {
    imports = [
      commonDesktopModule
      qemuDemoUserModule
    ];

    networking.hostName = "locale-english-test";
    common.autoUpgrade.enable = false;
    system.stateVersion = stateVersion;
  };

  nodes.hungarian = {
    imports = [
      commonDesktopModule
      qemuDemoUserModule
    ];

    common.locale.default = "hu_HU.UTF-8";
    common.autoUpgrade.enable = false;
    networking.hostName = "locale-hungarian-test";
    system.stateVersion = stateVersion;
  };

  testScript = ''
    start_all()

    def by_hostname(hostname):
        for node in machines:
            if node.succeed("hostname").strip() == hostname:
                return node
        raise Exception(f"No machine with hostname {hostname}")

    english = by_hostname("locale-english-test")
    hungarian = by_hostname("locale-hungarian-test")

    def wait_for_desktop(node):
        node.wait_for_unit("graphical.target")
        node.wait_until_succeeds("pgrep -u demo plasmashell")
        node.wait_until_succeeds("pgrep -u demo kwin_wayland")

    def assert_locale(node, system_locale, firefox_locale, expected_langpack):
        node.succeed(f"grep -Fx 'LANG={system_locale}' /etc/locale.conf")
        node.succeed(f"su - demo -c 'locale' | grep -Fx 'LANG={system_locale}'")
        node.succeed(
            "${pkgs.python3}/bin/python3 -c '"
            "import json; "
            "policies = json.load(open(\"/etc/firefox/policies/policies.json\"))[\"policies\"]; "
            f"assert policies[\"Preferences\"][\"intl.locale.requested\"][\"Value\"] == \"{firefox_locale}\""
            "'"
        )
        if expected_langpack is None:
            node.fail("grep -F 'langpack-' /etc/firefox/policies/policies.json")
        else:
            node.succeed(f"grep -F '{expected_langpack}' /etc/firefox/policies/policies.json")

    def start_http_server(node):
        node.succeed("rm -f /tmp/test-http-ready /tmp/request-firefox")
        node.succeed("systemd-run --unit test-http-server ${pkgs.python3}/bin/python3 ${testHttpServer}")
        node.wait_for_unit("test-http-server.service")
        node.wait_until_succeeds("test -e /tmp/test-http-ready")

    def open_firefox_and_screenshot(node, name):
        node.succeed("su - demo -c '${firefoxGuiCommand}'")
        node.wait_until_succeeds("test -e /tmp/request-firefox")
        node.wait_until_succeeds("pgrep -u demo firefox")
        node.succeed("sleep 5")
        node.screenshot(f"{name}-desktop")

    for node in [english, hungarian]:
        wait_for_desktop(node)
        start_http_server(node)

    assert_locale(english, "en_US.UTF-8", "en", None)
    assert_locale(hungarian, "hu_HU.UTF-8", "hu", "langpack-hu@firefox.mozilla.org")

    open_firefox_and_screenshot(english, "english")
    open_firefox_and_screenshot(hungarian, "hungarian")
  '';
}
