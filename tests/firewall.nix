{ nixpkgs, pkgs, commonDesktopModule, stateVersion }:

nixpkgs.lib.nixos.runTest {
  name = "firewall";
  hostPkgs = pkgs;
  skipTypeCheck = true;

  nodes.machine = { pkgs, ... }: {
    imports = [ commonDesktopModule ];

    networking.hostName = "firewall-test";
    common.autoUpgrade.enable = false;
    system.stateVersion = stateVersion;
  };

  nodes.unfiltered = { pkgs, ... }: {
    imports = [ commonDesktopModule ];

    common = {
      autoUpgrade.enable = false;
      firewall.enable = false;
    };
    networking = {
      firewall.enable = false;
      hostName = "firewall-disabled";
    };
    system.stateVersion = stateVersion;
  };

  testScript = ''
    start_all()

    for node in machines:
        node.wait_for_unit("multi-user.target")

    def by_hostname(hostname):
        for node in machines:
            if node.succeed("hostname").strip() == hostname:
                return node
        raise Exception(f"No machine with hostname {hostname}")

    machine = by_hostname("firewall-test")
    unfiltered = by_hostname("firewall-disabled")

    machine.succeed("systemctl is-active nftables.service")
    machine.succeed("${pkgs.nftables}/bin/nft list table inet nixos-fw")
    machine.succeed("${pkgs.nftables}/bin/nft list table inet common-firewall-pre")
    machine.succeed("${pkgs.nftables}/bin/nft list table inet common-doh-egress")
    unfiltered.succeed("systemctl is-active nftables.service")
    unfiltered.succeed("${pkgs.nftables}/bin/nft list table inet common-doh-egress")
    unfiltered.fail("${pkgs.nftables}/bin/nft list table inet nixos-fw")
    unfiltered.fail("${pkgs.nftables}/bin/nft list table inet common-firewall-pre")

    machine.succeed("systemd-run --unit blocked-http-server ${pkgs.python3}/bin/python3 -m http.server 18080 --bind 0.0.0.0 --directory /tmp")
    machine.wait_for_unit("blocked-http-server.service")
    machine.succeed("${pkgs.coreutils}/bin/timeout 10 ${pkgs.bash}/bin/bash -c 'until ${pkgs.curl}/bin/curl --fail --max-time 3 http://127.0.0.1:18080/; do sleep 0.2; done'")
    unfiltered.fail("${pkgs.curl}/bin/curl --fail --connect-timeout 2 --max-time 3 http://firewall-test:18080/")

    unfiltered.succeed("systemd-run --unit unfiltered-http-server ${pkgs.python3}/bin/python3 -m http.server 18080 --bind 0.0.0.0 --directory /tmp")
    unfiltered.wait_for_unit("unfiltered-http-server.service")
    unfiltered.succeed("${pkgs.coreutils}/bin/timeout 10 ${pkgs.bash}/bin/bash -c 'until ${pkgs.curl}/bin/curl --fail --max-time 3 http://127.0.0.1:18080/; do sleep 0.2; done'")
    machine.succeed("${pkgs.coreutils}/bin/timeout 10 ${pkgs.bash}/bin/bash -c 'until ${pkgs.curl}/bin/curl --fail --max-time 3 http://firewall-disabled:18080/; do sleep 0.2; done'")

    machine.succeed("rm -f /tmp/inbound-udp-ready /tmp/inbound-udp-received")
    machine.succeed("systemd-run --unit blocked-udp-server ${pkgs.python3}/bin/python3 -c \"import pathlib,socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(('0.0.0.0', 18082)); pathlib.Path('/tmp/inbound-udp-ready').touch(); data, _ = s.recvfrom(4096); pathlib.Path('/tmp/inbound-udp-received').write_bytes(data)\"")
    machine.wait_for_unit("blocked-udp-server.service")
    machine.succeed("${pkgs.coreutils}/bin/timeout 10 ${pkgs.bash}/bin/bash -c 'until test -e /tmp/inbound-udp-ready; do sleep 0.2; done'")
    unfiltered.succeed("${pkgs.python3}/bin/python3 -c \"import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(1); s.sendto(b'blocked', ('firewall-test', 18082))\"")
    machine.succeed("sleep 2")
    machine.fail("test -e /tmp/inbound-udp-received")

    unfiltered.succeed("rm -f /tmp/unfiltered-udp-ready /tmp/unfiltered-udp-received")
    unfiltered.succeed("systemd-run --unit unfiltered-udp-server ${pkgs.python3}/bin/python3 -c \"import pathlib,socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(('0.0.0.0', 18082)); pathlib.Path('/tmp/unfiltered-udp-ready').touch(); data, _ = s.recvfrom(4096); pathlib.Path('/tmp/unfiltered-udp-received').write_bytes(data)\"")
    unfiltered.wait_for_unit("unfiltered-udp-server.service")
    unfiltered.succeed("${pkgs.coreutils}/bin/timeout 10 ${pkgs.bash}/bin/bash -c 'until test -e /tmp/unfiltered-udp-ready; do sleep 0.2; done'")
    machine.succeed("${pkgs.python3}/bin/python3 -c \"import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(1); s.sendto(b'unfiltered', ('firewall-disabled', 18082))\"")
    unfiltered.succeed("${pkgs.coreutils}/bin/timeout 10 ${pkgs.bash}/bin/bash -c 'until test -e /tmp/unfiltered-udp-received; do sleep 0.2; done'")

    unfiltered.fail("${pkgs.iputils}/bin/ping -4 -c 1 -W 2 firewall-test")
    unfiltered.fail("${pkgs.iputils}/bin/ping -6 -c 1 -W 2 firewall-test")
    machine.succeed("${pkgs.iputils}/bin/ping -4 -c 1 -W 2 firewall-disabled")
    machine.succeed("${pkgs.iputils}/bin/ping -6 -c 1 -W 2 firewall-disabled")
  '';
}
