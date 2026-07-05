{ nixpkgs, pkgs, stateVersion, moduleUnderTest }:

# QEMU cannot emulate the brcmfmac radio, so the AP/station path is not exercised here
# (that is validated on real hardware). This test covers the module's LOGIC with the
# radio-side effects mocked: offline-detection -> setup trigger, the captive portal
# (form + probe redirect), wildcard DNS, credential writing, and the .ap profile
# rendering (SSID-named file + Channel + DisableHT -- the bits the firmware needs).
let
  fakeIwctl = pkgs.writeShellScriptBin "iwctl" ''
    echo "iwctl $*" >> /tmp/iwctl.log
    exit 0
  '';
  fakeIw = pkgs.writeShellScriptBin "iw" ''
    echo "iw $*" >> /tmp/iw.log
    exit 0
  '';
  # Intercept the portal's `systemctl reboot` so the test VM does not actually reboot;
  # everything else still goes to the real systemctl.
  fakeSystemctl = pkgs.writeShellScriptBin "systemctl" ''
    if [ "$1" = "reboot" ]; then
      echo reboot >> /tmp/reboot.log
      exit 0
    fi
    exec /run/current-system/sw/bin/systemctl "$@"
  '';
in
nixpkgs.lib.nixos.runTest {
  name = "connectivity-fallback";
  hostPkgs = pkgs;

  nodes.machine = { config, lib, pkgs, ... }: {
    imports = [ moduleUnderTest ];

    networking.hostName = "nixos-rpi5";
    # The module layers on iwd (assertion). No wifi device exists in the VM, so keep
    # iwd.service from starting -- its failure would be irrelevant noise.
    networking.wireless.iwd.enable = true;
    systemd.services.iwd.wantedBy = lib.mkForce [ ];
    # A dummy interface stands in for the wifi radio so IP + dnsmasq bring-up works.
    boot.kernelModules = [ "dummy" ];

    common.connectivityFallback = {
      enable = true;
      # A local server the test toggles stands in for "the internet".
      connectivityCheck.url = "http://127.0.0.1:8080/health";
      # Push the safety-net reboot far away so it cannot fire mid-test.
      setupTimeout = "1h";
      tools.iwd = fakeIwctl;
      tools.iw = fakeIw;
    };
    # Neutralize the portal's reboot (fires ~2s after a successful submit).
    systemd.services.connectivity-fallback-portal.path = lib.mkForce [ fakeSystemctl ];

    environment.systemPackages = [ pkgs.curl pkgs.dnsutils ];
    system.stateVersion = stateVersion;
  };

  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")

    with subtest("online: check does not enter setup mode"):
        machine.succeed(
            "systemd-run --unit=fakehealth ${pkgs.python3}/bin/python3 "
            "-m http.server 8080 --bind 127.0.0.1"
        )
        machine.wait_until_succeeds("curl -s -o /dev/null http://127.0.0.1:8080/")
        machine.succeed("systemctl start connectivity-fallback-check.service")
        machine.succeed(
            '[ "$(systemctl is-active connectivity-fallback-setup.service)" = inactive ]'
        )
        machine.succeed("systemctl stop fakehealth")

    with subtest("offline: check enters setup mode and brings up AP services"):
        machine.succeed("ip link add wlan0 type dummy && ip link set wlan0 up")
        machine.succeed("systemctl start connectivity-fallback-check.service")
        machine.wait_for_unit("connectivity-fallback-setup.service")
        machine.wait_for_unit("connectivity-fallback-dnsmasq.service")
        machine.wait_for_unit("connectivity-fallback-portal.service")

    with subtest("AP profile pins the SSID/channel/width the firmware needs"):
        prof = "/var/lib/iwd/ap/nixos-rpi5-setup.ap"
        machine.succeed(f"grep -qx 'Passphrase=nixos-rpi5-setup' {prof}")
        machine.succeed(f"grep -qx 'Channel=6' {prof}")
        machine.succeed(f"grep -qx 'DisableHT=true' {prof}")
        machine.succeed("grep -q 'set-property Mode ap' /tmp/iwctl.log")
        machine.succeed("grep -q 'start-profile nixos-rpi5-setup' /tmp/iwctl.log")

    with subtest("captive portal serves the form and redirects probes"):
        machine.wait_until_succeeds(
            "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/ | grep -qx 200"
        )
        machine.succeed(
            "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/generate_204 | grep -qx 302"
        )

    with subtest("wildcard DNS answers every A query with the gateway"):
        machine.wait_until_succeeds(
            "host -t A whatever.example 10.42.0.1 | grep -q '10.42.0.1'"
        )

    with subtest("submitting credentials writes the psk and triggers reboot"):
        machine.succeed(
            "curl -s -o /dev/null -X POST --data 'ssid=MyNet&psk=secret12345' "
            "http://127.0.0.1/submit"
        )
        machine.wait_until_succeeds("test -f /var/lib/iwd/MyNet.psk")
        machine.succeed("grep -qx 'Passphrase=secret12345' /var/lib/iwd/MyNet.psk")
        machine.succeed('[ "$(stat -c %a /var/lib/iwd/MyNet.psk)" = 600 ]')
        machine.wait_until_succeeds("test -f /tmp/reboot.log")

    with subtest("invalid submission is rejected and writes nothing"):
        machine.succeed(
            "curl -s -o /dev/null -w '%{http_code}' -X POST --data 'ssid=Valid&psk=short' "
            "http://127.0.0.1/submit | grep -qx 400"
        )
        machine.succeed("! test -e /var/lib/iwd/Valid.psk")
  '';
}
