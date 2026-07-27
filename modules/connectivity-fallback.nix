{ config, lib, pkgs, ... }:

let
  cfg = config.common.connectivityFallback;

  # The host's own DoH upstreams, as components (see lib/doh-stamps.nix). Same source of
  # truth dnscrypt-proxy's stamps are generated from, so the probe cannot drift from the
  # resolvers actually in use. mapAttrsToList orders by attribute name, which puts each
  # provider's IPv4 entry before its IPv6 one -- worth keeping, because the rpi5 has no
  # global IPv6 and a v6 attempt is a wasted timeout there.
  doh = import ../lib/doh-stamps.nix { inherit lib; };
  dohEndpoints = lib.mapAttrsToList (_: e: { inherit (e) hostname addr; }) doh.endpoints;

  # Whether this host runs the nftables-backed NixOS firewall whose nixos-fw
  # table the setup script must open the AP service ports in.
  firewallManaged = config.networking.firewall.enable && config.networking.nftables.enable;

  apProfileName = cfg.ap.ssid;

  # iwd AP profile. WPA2 with passphrase == SSID ("open in practice": the password is
  # the visible network name), pinned to a legal 2.4GHz channel. Verified on the rpi5
  # brcmfmac: iwd's auto channel selection picks regulatory-restricted channels and the
  # firmware rejects them (START_AP -52), so the channel MUST be pinned; and iwd's HT40
  # width is also rejected (chspec ch8/40MHz -> -52), so DisableHT forces the 20MHz that
  # the firmware accepts. No [IPv4] group -> iwd runs no DHCP; the setup service assigns
  # the gateway IP and dnsmasq serves DHCP.
  apProfile = pkgs.writeText "${apProfileName}.ap" ''
    [Security]
    Passphrase=${cfg.ap.ssid}

    [General]
    Channel=${toString cfg.ap.channel}
    DisableHT=true
  '';

  leaseFile = "/run/connectivity-fallback-dnsmasq/dnsmasq.leases";

  dnsmasqConf = pkgs.writeText "connectivity-fallback-dnsmasq.conf" ''
    interface=${cfg.interface}
    bind-interfaces
    except-interface=lo
    dhcp-authoritative
    dhcp-leasefile=${leaseFile}
    dhcp-range=${cfg.subnet.poolFrom},${cfg.subnet.poolTo},${cfg.subnet.netmask},${cfg.subnet.leaseTime}
    dhcp-option=option:router,${cfg.subnet.gateway}
    dhcp-option=option:dns-server,${cfg.subnet.gateway}
    address=/#/${cfg.subnet.gateway}
    no-resolv
    no-hosts
  '';

  portalPy = pkgs.writeText "connectivity-fallback-portal.py" ''
    import os, re, html, subprocess, threading, http.server, urllib.parse, pathlib

    GATEWAY = os.environ.get("CF_GATEWAY", "10.42.0.1")
    PORT = int(os.environ.get("CF_PORT", "80"))
    TITLE = os.environ.get("CF_TITLE", "Wi-Fi setup")
    IWD_DIR = pathlib.Path("/var/lib/iwd")

    PAGE = """<!doctype html><html><head><meta name=viewport content="width=device-width,initial-scale=1"><title>%s</title></head><body style="font-family:sans-serif;max-width:28rem;margin:2rem auto;padding:0 1rem">%s</body></html>"""

    FORM = """<h1>%s</h1><p>Enter the Wi-Fi network for this device to join.</p><form method=POST action="/submit"><p><label>Network name (SSID)<br><input name=ssid required style="width:100%%;padding:.5rem"></label></p><p><label>Password<br><input name=psk type=password style="width:100%%;padding:.5rem" placeholder="leave blank for open network"></label></p><p><button type=submit style="padding:.6rem 1.2rem">Connect and reboot</button></p></form>"""

    def encode_path(ssid, ext):
        if re.fullmatch(r"[A-Za-z0-9 _.-]+", ssid):
            name = ssid
        else:
            name = "=" + ssid.encode("utf-8").hex()
        return IWD_DIR / (name + "." + ext)

    def write_credentials(ssid, psk):
        if psk:
            path = encode_path(ssid, "psk")
            content = "[Security]\nPassphrase=" + psk + "\n"
        else:
            path = encode_path(ssid, "open")
            content = "[Settings]\nAutoConnect=true\n"
        tmp = path.with_name(path.name + ".tmp")
        tmp.write_text(content)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)

    def reboot_soon():
        subprocess.run(["systemctl", "reboot"], check=False)

    class H(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def log_message(self, *a):
            return
        def _send(self, code, body, headers=None):
            data = body.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            if headers:
                for k, v in headers.items():
                    self.send_header(k, v)
            self.end_headers()
            self.wfile.write(data)
        def do_GET(self):
            path = urllib.parse.urlparse(self.path).path
            if path == "/":
                self._send(200, PAGE % (TITLE, FORM % TITLE))
            else:
                self._send(302, "", {"Location": "http://" + GATEWAY + "/"})
        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length).decode("utf-8")
            form = urllib.parse.parse_qs(raw)
            ssid = form.get("ssid", [""])[0].strip()
            psk = form.get("psk", [""])[0]
            if not (1 <= len(ssid.encode("utf-8")) <= 32):
                self._send(400, PAGE % (TITLE, "<p>Invalid SSID (1..32 bytes).</p>"))
                return
            if psk and not (8 <= len(psk) <= 63):
                self._send(400, PAGE % (TITLE, "<p>Invalid password (8..63 chars, or blank).</p>"))
                return
            write_credentials(ssid, psk)
            body = "<h1>Saved</h1><p>Connecting to <b>" + html.escape(ssid) + "</b> and rebooting. If it cannot join, this setup network reappears shortly.</p>"
            self._send(200, PAGE % (TITLE, body))
            try:
                self.wfile.flush()
            except Exception:
                pass
            threading.Timer(2.0, reboot_soon).start()

    http.server.ThreadingHTTPServer(("", PORT), H).serve_forever()
  '';

  gatewayCidr = "${cfg.subnet.gateway}/${toString cfg.subnet.prefix}";

  setupScript = pkgs.writeShellApplication {
    name = "connectivity-fallback-setup";
    runtimeInputs = [ cfg.tools.iwd cfg.tools.iw cfg.tools.iproute2 cfg.tools.systemd cfg.tools.coreutils ]
      ++ lib.optional firewallManaged cfg.tools.nftables;
    text = ''
      set -x
      ${lib.optionalString firewallManaged ''
        # Open the AP service ports (DNS, DHCP, portal) for this setup session only, so
        # they stay closed in normal (station-mode) operation. The rules must go into the
        # NixOS firewall's own input-allow chain: an accept in a separate nftables table
        # would not bypass its drop policy (every hook chain sees the packet; any drop
        # wins). Emitted only when this host runs the nftables firewall (eval-time gate);
        # the unit is also ordered After=nftables.service, because a mid-boot trigger
        # can otherwise run before the nixos-fw table exists -- a runtime existence
        # check would silently skip the openings and leave the portal unreachable for
        # the whole session (seen on a slow TCG boot in CI). If nft fails here, the
        # unit fails loudly instead. No teardown is needed: every setup session ends
        # in a reboot (portal submit or the setupTimeout safety net below), and runtime
        # rules do not survive it. Caveat: a firewall reload mid-setup wipes them for
        # the rest of the session.
        nft insert rule inet nixos-fw input-allow iifname "${cfg.interface}" udp dport "{ 53, 67 }" accept
        nft insert rule inet nixos-fw input-allow iifname "${cfg.interface}" tcp dport "{ 53, ${toString cfg.portal.listenPort} }" accept
      ''}
      # Regulatory domain: required so the firmware permits beaconing in AP mode.
      iw reg set ${cfg.regulatoryCountry} || true
      # Materialize the AP profile where iwd expects it (regenerated from the store).
      install -d -m 0700 /var/lib/iwd/ap
      install -m 0600 ${apProfile} /var/lib/iwd/ap/${apProfileName}.ap
      # Switch the radio to AP mode and start the WPA2 (open-in-practice) AP.
      iwctl device ${cfg.interface} set-property Mode ap
      sleep 1
      iwctl ap ${cfg.interface} start-profile ${apProfileName}
      sleep 2
      # We own IP config (profile has no [IPv4]); assign the gateway address.
      ip addr flush dev ${cfg.interface} || true
      ip addr add ${gatewayCidr} dev ${cfg.interface} || true
      ip link set ${cfg.interface} up || true
      # Bring up DHCP/DNS and the captive portal (started explicitly, ordering owned here).
      systemctl start --no-block connectivity-fallback-dnsmasq.service
      systemctl start --no-block connectivity-fallback-portal.service
      # Safety net: reboot after the timeout so a transient outage self-heals and known
      # networks are retried on the fresh boot.
      systemd-run --on-active=${cfg.setupTimeout} --unit=connectivity-fallback-reboot ${cfg.tools.systemd}/bin/systemctl reboot
    '';
  };

  # One "host|port|addr|path" record per probe target, fed to the loop below on stdin.
  # Generated rather than looped in Nix so the script stays readable in the journal.
  endpointRecords = lib.concatMapStrings (
    e: "${e.hostname}|${toString e.port}|${e.addr}|${e.path}\n"
  ) cfg.connectivityCheck.endpoints;

  checkScript = pkgs.writeShellApplication {
    name = "connectivity-fallback-check";
    runtimeInputs = [ cfg.tools.curl cfg.tools.iproute2 cfg.tools.systemd cfg.tools.coreutils ];
    text = ''
      # Probe general internet reachability; do NOT bind to the wifi interface.
      #
      # The targets are this host's own DoH resolvers (see connectivityCheck.endpoints).
      # Three properties matter, and a plain HTTP canary has none of them:
      #
      #  * --resolve pins the address from the stamp, so the probe needs no DNS at all:
      #    it cannot be answered from lib/captive-portals.txt, and it still works when
      #    dnscrypt-proxy itself is wedged.
      #  * TLS certificate validation *is* the captive-portal test. A portal cannot
      #    present a valid cert for these hostnames, so interception fails closed and
      #    reads as offline -- which is correct, since a portal means not-online.
      #  * There are four independent operators, so one provider's outage cannot make
      #    this host tear down its own network.
      #
      # Requiring HTTP 200 (not merely "something answered") means a real DNS answer came
      # back, so this proves the whole path the box depends on: TCP 443, TLS, and a
      # working upstream resolver.
      query=${lib.escapeShellArg cfg.connectivityCheck.dnsQuery}
      timeout=${toString cfg.connectivityCheck.timeoutSeconds}
      code=""

      probe() {
        code="$(curl -s -m "$timeout" -o /dev/null -w '%{http_code}' \
          --resolve "$1:$2:$3" \
          -H 'accept: application/dns-message' \
          "https://$1:$2$4?dns=$query" || true)"
        [ "$code" = "200" ]
      }

      while IFS='|' read -r host port addr path; do
        [ -n "$host" ] || continue
        if probe "$host" "$port" "$addr" "$path"; then
          echo "connectivity-fallback: online (via $host at $addr), nothing to do"
          exit 0
        fi
        echo "connectivity-fallback: probe failed for $host at $addr (HTTP $code)"
      done <<'CONNECTIVITY_FALLBACK_ENDPOINTS'
      ${endpointRecords}CONNECTIVITY_FALLBACK_ENDPOINTS

      echo "connectivity-fallback: no connectivity; entering setup mode"
      systemctl start --no-block connectivity-fallback-setup.service
    '';
  };
in
{
  options.common.connectivityFallback = {
    enable = lib.mkEnableOption "WiFi connectivity fallback captive-portal provisioning";

    interface = lib.mkOption {
      type = lib.types.str;
      default = "wlan0";
      description = "Wireless interface used for both station and AP mode.";
    };

    regulatoryCountry = lib.mkOption {
      type = lib.types.str;
      default = "HU";
      description = "ISO alpha-2 regulatory country. Required for AP beaconing.";
    };

    ap = {
      ssid = lib.mkOption {
        type = lib.types.str;
        default = "${config.networking.hostName}-setup";
        description = "Setup AP SSID. Reused verbatim as the WPA2 passphrase.";
      };
      channel = lib.mkOption {
        type = lib.types.ints.between 1 11;
        default = 6;
        description = "2.4GHz AP channel. Must be pinned (auto-select fails on brcmfmac).";
      };
    };

    subnet = {
      gateway = lib.mkOption { type = lib.types.str; default = "10.42.0.1"; description = "AP gateway/portal IP."; };
      prefix = lib.mkOption { type = lib.types.ints.between 8 30; default = 24; description = "AP subnet prefix length."; };
      netmask = lib.mkOption { type = lib.types.str; default = "255.255.255.0"; description = "AP subnet netmask (for dnsmasq)."; };
      poolFrom = lib.mkOption { type = lib.types.str; default = "10.42.0.10"; description = "DHCP pool start."; };
      poolTo = lib.mkOption { type = lib.types.str; default = "10.42.0.100"; description = "DHCP pool end."; };
      leaseTime = lib.mkOption { type = lib.types.str; default = "1h"; description = "DHCP lease time."; };
    };

    bootGrace = lib.mkOption {
      type = lib.types.str;
      default = "5min";
      description = "Delay after boot before the connectivity check runs (OnBootSec).";
    };

    setupTimeout = lib.mkOption {
      type = lib.types.str;
      default = "10min";
      description = "How long setup mode stays up before an automatic reboot.";
    };

    portal = {
      listenPort = lib.mkOption { type = lib.types.port; default = 80; description = "Captive-portal HTTP port."; };
      title = lib.mkOption { type = lib.types.str; default = "Wi-Fi setup"; description = "Portal page title."; };
    };

    connectivityCheck = {
      endpoints = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              hostname = lib.mkOption {
                type = lib.types.str;
                description = "Hostname used for TLS validation and the Host header.";
              };
              addr = lib.mkOption {
                type = lib.types.str;
                description = ''
                  Literal address to dial, passed to `curl --resolve`, so no DNS lookup
                  happens. IPv6 must be bracketed, e.g. "[2606:4700:4700::1111]".
                '';
              };
              port = lib.mkOption {
                type = lib.types.port;
                default = 443;
                description = "Port to dial. Must match the URL's port for --resolve to apply.";
              };
              path = lib.mkOption {
                type = lib.types.str;
                default = "/dns-query";
                description = "Request path; the DoH query is appended as ?dns=...";
              };
            };
          }
        );
        default = dohEndpoints;
        defaultText = lib.literalExpression "the host's DoH upstreams from lib/doh-stamps.nix";
        description = ''
          Endpoints probed to decide whether the device is online. The device is online as
          soon as any one of them answers HTTP 200; setup mode is entered only when every
          one fails.

          These default to the host's own DoH resolvers rather than a third-party HTTP
          canary. On 2026-07-27 the previous default
          (`http://detectportal.firefox.com/success.txt`) rebooted the rpi5 every 15m23s
          for ~16 hours: Mozilla migrated that host to Fastly, the pinned address in
          lib/captive-portals.txt went stale, and because that map answers at all times the
          box could never learn otherwise -- so a single rotted third-party pin was able to
          make a healthy machine tear down its own network. A DoH upstream cannot rot
          unnoticed, because if it does this host has no DNS at all.
        '';
      };

      dnsQuery = lib.mkOption {
        type = lib.types.str;
        # See lib/doh-stamps.nix for the byte-level decoding; it lives there so the VM
        # tests, which build their own probe curl commands, can send the identical query
        # instead of copying the literal.
        default = doh.dnsQuery;
        defaultText = lib.literalExpression "dnsQuery from lib/doh-stamps.nix";
        description = "base64url-encoded DNS query sent to each endpoint.";
      };

      timeoutSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5;
        description = ''
          Per-endpoint curl timeout.

          Worst case the check takes this times the number of endpoints -- 40s at the
          defaults. Two ceilings sit above that, and the tighter one is not the obvious
          one: TimeoutStartSec on the check service (120s), past which the probe loop is
          killed before it reaches the line that starts setup mode, so an offline host
          would silently stay offline. That is set explicitly rather than left to inherit
          systemd's 90s default precisely because the consequence is invisible.
          setupTimeout (10min) is the other ceiling and is never binding.
          tests/connectivity-fallback-timing.nix runs the real endpoint list under icount
          and asserts the loop stays inside 60s (42s measured worst case).
        '';
      };
    };

    tools = {
      iwd = lib.mkPackageOption pkgs "iwd" { };
      iw = lib.mkPackageOption pkgs "iw" { };
      dnsmasq = lib.mkPackageOption pkgs "dnsmasq" { };
      python3 = lib.mkPackageOption pkgs "python3" { };
      iproute2 = lib.mkPackageOption pkgs "iproute2" { };
      nftables = lib.mkPackageOption pkgs "nftables" { };
      curl = lib.mkPackageOption pkgs "curl" { };
      coreutils = lib.mkPackageOption pkgs "coreutils" { };
      systemd = lib.mkPackageOption pkgs "systemd" { };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      { assertion = config.networking.wireless.iwd.enable;
        message = "common.connectivityFallback requires networking.wireless.iwd.enable."; }
      { assertion = !config.networking.networkmanager.enable;
        message = "common.connectivityFallback manages the radio via iwd; disable NetworkManager."; }
      { assertion = builtins.stringLength cfg.ap.ssid >= 8;
        message = "common.connectivityFallback.ap.ssid must be >= 8 chars (reused as WPA2 passphrase)."; }
      # An empty list makes every check conclude "offline", which means an AP and a reboot
      # every bootGrace+setupTimeout, forever -- the exact failure this module caused on
      # 2026-07-27. Fail the build instead.
      { assertion = cfg.connectivityCheck.endpoints != [ ];
        message = "common.connectivityFallback.connectivityCheck.endpoints must not be empty: with no endpoints the check always reports offline and the host reboots in a loop."; }
    ];

    environment.systemPackages = [ cfg.tools.iw ];

    networking.wireless.iwd.settings.General.Country = cfg.regulatoryCountry;

    # No static firewall openings: the setup script inserts session-scoped accepts for
    # the AP service ports into the running nixos-fw ruleset, so in normal (station
    # mode) operation the ports are closed like everything else.

    systemd.services.connectivity-fallback-check = {
      description = "Check internet connectivity; enter WiFi setup mode if offline";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe checkScript;
        # Explicit rather than inheriting DefaultTimeoutStartSec (90s), because the
        # consequence of hitting it is silent: the probe loop would be killed before
        # `systemctl start ... setup.service`, so an offline host would never raise the
        # setup AP. Must stay comfortably above timeoutSeconds x length endpoints (40s at
        # the defaults) -- see the timeoutSeconds description.
        TimeoutStartSec = "120s";
      };
    };

    systemd.timers.connectivity-fallback-check = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = cfg.bootGrace; AccuracySec = "1s"; Unit = "connectivity-fallback-check.service"; };
    };

    # Started only by the check service; never wanted by a boot target. Ordered
    # after iwd (the script drives it via iwctl) and after the firewall (the
    # nixos-fw table must exist for the port openings), so a trigger that lands
    # mid-boot (slow boot + short bootGrace) waits instead of racing either.
    systemd.services.connectivity-fallback-setup = {
      description = "WiFi setup mode: AP + captive portal";
      after = [ "iwd.service" ] ++ lib.optional firewallManaged "nftables.service";
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; ExecStart = lib.getExe setupScript; };
    };

    systemd.services.connectivity-fallback-dnsmasq = {
      description = "DHCP + wildcard DNS for the WiFi setup AP";
      serviceConfig = {
        RuntimeDirectory = "connectivity-fallback-dnsmasq";
        ExecStart = "${cfg.tools.dnsmasq}/bin/dnsmasq -k --conf-file=${dnsmasqConf}";
        Restart = "on-failure";
      };
    };

    systemd.services.connectivity-fallback-portal = {
      description = "Captive portal web server for WiFi setup";
      path = [ cfg.tools.systemd ];
      environment = {
        CF_GATEWAY = cfg.subnet.gateway;
        CF_PORT = toString cfg.portal.listenPort;
        CF_TITLE = cfg.portal.title;
      };
      serviceConfig = {
        ExecStart = "${cfg.tools.python3}/bin/python3 ${portalPy}";
        Restart = "on-failure";
      };
    };
  };
}
