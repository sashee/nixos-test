{ nixpkgs, pkgs, commonDesktopModule, stateVersion }:

let
  # Fake captive.apple.com endpoint. Switches behaviour on /tmp/portal-mode so a
  # single long-running server can play both the "open network" and the
  # "captive portal" roles without a restart.
  portalServer = pkgs.writeText "portal-server.py" ''
    import http.server
    import pathlib

    ready_path = pathlib.Path("/tmp/portal-ready")
    mode_path = pathlib.Path("/tmp/portal-mode")
    success = b"<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"
    login = b"<html><body>Login required</body></html>"

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            return

        def do_GET(self):
            mode = mode_path.read_text().strip() if mode_path.exists() else "open"
            if mode == "open":
                # Matches the connectivity check's expected body -> NM: full.
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", str(len(success)))
                self.end_headers()
                self.wfile.write(success)
            else:
                # A redirect to a login page -> NM: portal.
                self.send_response(302)
                self.send_header("Location", "http://login.portal.test/")
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", str(len(login)))
                self.end_headers()
                self.wfile.write(login)

    httpd = http.server.ThreadingHTTPServer(("0.0.0.0", 80), Handler)
    ready_path.touch()
    httpd.serve_forever()
  '';
in

nixpkgs.lib.nixos.runTest {
  name = "nm-captive-portal";
  hostPkgs = pkgs;
  skipTypeCheck = true;

  # Fake captive.apple.com: owns the IP that the dnscrypt map points the
  # connectivity-check name at, and serves HTTP on it.
  nodes.portal = { pkgs, ... }: {
    networking.firewall.enable = false;
    networking.hostName = "nm-portal";
    system.stateVersion = stateVersion;
  };

  # Real config under test. commonDesktopModule carries the dnscrypt map and the
  # NetworkManager [connectivity] settings; the extra config hands eth1 to NM so
  # it actually manages a device and therefore evaluates connectivity.
  nodes.client = { lib, pkgs, ... }: {
    imports = [ commonDesktopModule ];

    networking.hostName = "nm-client";
    common.autoUpgrade.enable = false;
    common.monitoring.enable = false;
    system.stateVersion = stateVersion;

    networking.useDHCP = false;
    networking.interfaces = lib.mkForce { eth1 = { }; };
    networking.networkmanager.settings.main.no-auto-default = "*";
    networking.networkmanager.ensureProfiles.profiles.default = {
      connection = {
        id = "default";
        type = "ethernet";
        interface-name = "eth1";
        autoconnect = true;
      };
      ipv4 = {
        method = "manual";
        addresses = "192.168.1.42/24";
        gateway = "192.168.1.1";
      };
    };
  };

  testScript = ''
    start_all()

    portal.wait_for_unit("multi-user.target")
    client.wait_for_unit("multi-user.target")
    client.wait_for_unit("NetworkManager.service")
    client.wait_for_unit("dnscrypt-proxy.service")

    # Stand up the fake portal: it owns the client's gateway address and the
    # impersonated captive.apple.com address, and serves HTTP on both.
    portal.succeed("${pkgs.iproute2}/bin/ip addr add 192.168.1.1/24 dev eth1 || true")
    portal.succeed("${pkgs.iproute2}/bin/ip addr add 17.253.109.201/32 dev eth1 || true")
    portal.succeed("echo open > /tmp/portal-mode")
    portal.succeed("systemd-run --unit portal-http ${pkgs.python3}/bin/python3 ${portalServer}")
    portal.wait_for_unit("portal-http.service")
    portal.succeed("${pkgs.coreutils}/bin/timeout 10 ${pkgs.bash}/bin/bash -c 'until test -e /tmp/portal-ready; do sleep 0.2; done'")

    # NetworkManager brings eth1 up with the static address.
    client.wait_until_succeeds("${pkgs.iproute2}/bin/ip addr show dev eth1 | grep -q 192.168.1.42")

    # Sanity gates: the dnscrypt map resolves the name and the peer is reachable.
    # These isolate any later failure to NM's connectivity logic rather than DNS
    # or routing.
    client.wait_until_succeeds("${pkgs.dig}/bin/dig @127.0.0.1 captive.apple.com +short 2>/dev/null | grep -q 17.253.109.201")
    client.wait_until_succeeds("${pkgs.curl}/bin/curl -s http://captive.apple.com/hotspot-detect.html | grep -q Success")

    # Open network: the success body matches the configured response -> full.
    client.wait_until_succeeds("nmcli networking connectivity check | grep -qx full")

    # Captive portal: the server now redirects -> NM reports portal.
    portal.succeed("echo portal > /tmp/portal-mode")
    client.wait_until_succeeds("nmcli networking connectivity check | grep -qx portal")
  '';
}
