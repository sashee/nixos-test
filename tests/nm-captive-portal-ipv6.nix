{ nixpkgs, pkgs, commonDesktopModule, stateVersion }:

let
  # Fake detectportal.firefox.com endpoint, IPv6 only. Switches behaviour on
  # /tmp/portal-mode so a single long-running server plays both the "open network"
  # and the "captive portal" roles without a restart. Binds an AF_INET6 socket so
  # it serves over IPv6 (the IPv4 variant of this test lives in
  # nm-captive-portal.nix).
  portalServer = pkgs.writeText "portal-server-ipv6.py" ''
    import http.server
    import pathlib
    import socket

    ready_path = pathlib.Path("/tmp/portal-ready")
    mode_path = pathlib.Path("/tmp/portal-mode")
    success = b"success\n"
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
                self.send_header("Content-Type", "text/plain")
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

    class Server(http.server.ThreadingHTTPServer):
        address_family = socket.AF_INET6

    httpd = Server(("::", 80), Handler)
    ready_path.touch()
    httpd.serve_forever()
  '';
in

nixpkgs.lib.nixos.runTest {
  name = "nm-captive-portal-ipv6";
  hostPkgs = pkgs;
  skipTypeCheck = true;

  # Fake detectportal.firefox.com: owns the IPv6 address that the dnscrypt map
  # points the connectivity-check name at, and serves HTTP on it.
  nodes.portal = { pkgs, ... }: {
    networking.firewall.enable = false;
    networking.hostName = "nm-portal";
    system.stateVersion = stateVersion;
  };

  # Real config under test, on an IPv6-only link. commonDesktopModule carries the
  # dnscrypt map and the NetworkManager [connectivity] settings; the extra config
  # hands eth1 to NM with IPv4 disabled so the connectivity check has nothing but
  # IPv6 to work with.
  nodes.client = { lib, pkgs, ... }: {
    imports = [ commonDesktopModule ];

    networking.hostName = "nm-client";
    common.autoUpgrade.enable = false;
    common.monitoring.enable = false;
    common.irohSsh.enable = false;
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
      ipv4.method = "disabled";
      ipv6 = {
        method = "manual";
        addresses = "fd00::42/64";
        gateway = "fd00::1";
      };
    };
  };

  testScript = ''
    start_all()

    portal.wait_for_unit("multi-user.target")
    client.wait_for_unit("multi-user.target")
    client.wait_for_unit("NetworkManager.service")
    client.wait_for_unit("dnscrypt-proxy.service")

    # Stand up the fake portal: it owns the client's IPv6 gateway address and the
    # impersonated detectportal.firefox.com IPv6 address, and serves HTTP on both.
    portal.succeed("${pkgs.iproute2}/bin/ip -6 addr add fd00::1/64 dev eth1 nodad || true")
    portal.succeed("${pkgs.iproute2}/bin/ip -6 addr add 2600:1901:0:38d7::/128 dev eth1 nodad || true")
    portal.succeed("echo open > /tmp/portal-mode")
    portal.succeed("systemd-run --unit portal-http ${pkgs.python3}/bin/python3 ${portalServer}")
    portal.wait_for_unit("portal-http.service")
    portal.succeed("${pkgs.coreutils}/bin/timeout 10 ${pkgs.bash}/bin/bash -c 'until test -e /tmp/portal-ready; do sleep 0.2; done'")

    # NetworkManager brings eth1 up with the static IPv6 address and no IPv4.
    client.wait_until_succeeds("${pkgs.iproute2}/bin/ip -6 addr show dev eth1 | grep -q 'fd00::42'")
    client.fail("${pkgs.iproute2}/bin/ip -4 addr show dev eth1 | grep -q 'inet '")

    # Sanity gates: the dnscrypt map resolves the AAAA over IPv6 and the peer is
    # reachable over IPv6. These isolate any later failure to NM's connectivity
    # logic rather than DNS or routing.
    client.wait_until_succeeds("${pkgs.dig}/bin/dig @::1 detectportal.firefox.com AAAA +short 2>/dev/null | grep -q '2600:1901:0:38d7::'")
    client.wait_until_succeeds("${pkgs.curl}/bin/curl -6 -s http://detectportal.firefox.com/success.txt | grep -q success")

    # Open network: the success body matches the configured response -> full.
    client.wait_until_succeeds("nmcli networking connectivity check | grep -qx full")

    # Captive portal: the server now redirects -> NM reports portal.
    portal.succeed("echo portal > /tmp/portal-mode")
    client.wait_until_succeeds("nmcli networking connectivity check | grep -qx portal")
  '';
}
