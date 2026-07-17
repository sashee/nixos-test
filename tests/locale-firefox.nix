# `user` (required): the already-configured desktop user whose session is
# exercised — "demo" for the generic stack (with qemuDemoUserModule), or the
# host's real user when commonDesktopModule is a host config (then
# qemuDemoUserModule stays null; the host provides its own autologin).
{ nixpkgs, pkgs, commonDesktopModule, qemuDemoUserModule ? null, stateVersion, user }:

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

in
nixpkgs.lib.nixos.runTest {
  name = "locale-firefox";
  hostPkgs = pkgs;
  globalTimeout = 420;

  nodes.english = { lib, ... }: {
    imports = [ commonDesktopModule ]
      ++ nixpkgs.lib.optional (qemuDemoUserModule != null) qemuDemoUserModule;

    networking.hostName = "locale-english-test";
    # mkForce: a host config passed as commonDesktopModule may set its own
    # locale (anya: hu_HU); this node tests the English mapping regardless.
    common.locale.default = lib.mkForce "en_US.UTF-8";
    common.autoUpgrade.enable = false;
    common.monitoring.enable = false;
    common.irohSsh.enable = false;
    system.stateVersion = stateVersion;
  };

  nodes.hungarian = {
    imports = [ commonDesktopModule ]
      ++ nixpkgs.lib.optional (qemuDemoUserModule != null) qemuDemoUserModule;

    common.locale.default = "hu_HU.UTF-8";
    common.autoUpgrade.enable = false;
    common.monitoring.enable = false;
    common.irohSsh.enable = false;
    networking.hostName = "locale-hungarian-test";
    system.stateVersion = stateVersion;
  };

  testScript = ''
    def wait_for_desktop(node):
        node.wait_for_unit("graphical.target")
        node.wait_until_succeeds("pgrep -u ${user} plasmashell")
        node.wait_until_succeeds("pgrep -u ${user} kwin_wayland")

    def firefox_gui_command(uid):
        return f"env XDG_RUNTIME_DIR=/run/user/{uid} WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{uid}/bus MOZ_ENABLE_WAYLAND=1 firefox http://127.0.0.1:8000/firefox.html >/tmp/firefox-gui.log 2>&1 &"

    def assert_locale(node, system_locale, firefox_locale, expected_langpack):
        node.succeed(f"grep -Fx 'LANG={system_locale}' /etc/locale.conf")
        node.succeed(f"su - ${user} -c 'locale' | grep -Fx 'LANG={system_locale}'")
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
        uid = node.succeed("id -u ${user}").strip()
        node.succeed(f"su - ${user} -c '{firefox_gui_command(uid)}'")
        node.wait_until_succeeds("test -e /tmp/request-firefox")
        node.wait_until_succeeds("pgrep -u ${user} firefox")
        node.succeed("sleep 5")
        node.screenshot(f"{name}-desktop")

    # Run one desktop VM at a time: two Plasma + Firefox guests booted in
    # parallel oversubscribe the 2-vCPU CI runner (2:1) and soft-lock the guest
    # kernel. Shutting each node down before starting the next keeps it 1:1.
    def run_locale(node, name, system_locale, firefox_locale, expected_langpack):
        node.start()
        wait_for_desktop(node)
        start_http_server(node)
        assert_locale(node, system_locale, firefox_locale, expected_langpack)
        open_firefox_and_screenshot(node, name)
        node.shutdown()

    run_locale(english, "english", "en_US.UTF-8", "en", None)
    run_locale(hungarian, "hungarian", "hu_HU.UTF-8", "hu", "langpack-hu@firefox.mozilla.org")
  '';
}
