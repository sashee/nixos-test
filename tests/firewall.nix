{ nixpkgs, pkgs, machineModule, stateVersion }:

nixpkgs.lib.nixos.runTest {
  name = "firewall";
  hostPkgs = pkgs;
  skipTypeCheck = true;

  # mkForce on the common.* toggles: the rpi host config enables them at
  # normal priority (the laptop module only defaults them).
  nodes.machine = { pkgs, lib, ... }: {
    imports = [ machineModule ];

    networking.hostName = "firewall-test";
    common.autoUpgrade.enable = lib.mkForce false;
    common.monitoring.enable = lib.mkForce false;
    common.irohSsh.enable = lib.mkForce false;
    system.stateVersion = stateVersion;
  };

  nodes.unfiltered = { pkgs, lib, ... }: {
    imports = [ machineModule ];

    common = {
      autoUpgrade.enable = lib.mkForce false;
      monitoring.enable = lib.mkForce false;
      irohSsh.enable = lib.mkForce false;
      firewall.enable = lib.mkForce false;
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

    # IPv6 inbound TCP/UDP is blocked too. The NixOS firewall uses the nftables
    # `inet` family, so its drop policy covers IPv6; mirror the IPv4 TCP+UDP
    # checks over IPv6 to prove it, not just assume it. Give both nodes an on-link
    # ULA on eth1 and use fresh ports so the IPv6 servers don't collide with the
    # IPv4 servers still bound on 18080/18082.
    machine.succeed("${pkgs.iproute2}/bin/ip -6 addr add fc00::1/64 dev eth1 nodad || true")
    unfiltered.succeed("${pkgs.iproute2}/bin/ip -6 addr add fc00::2/64 dev eth1 nodad || true")

    # Inbound IPv6 HTTP to the firewalled host is blocked; locally it serves.
    machine.succeed("systemd-run --unit blocked-http6-server ${pkgs.python3}/bin/python3 -m http.server 18084 --bind :: --directory /tmp")
    machine.wait_for_unit("blocked-http6-server.service")
    machine.succeed("${pkgs.coreutils}/bin/timeout 10 ${pkgs.bash}/bin/bash -c 'until ${pkgs.curl}/bin/curl --fail --max-time 3 http://[::1]:18084/; do sleep 0.2; done'")
    unfiltered.fail("${pkgs.curl}/bin/curl --fail --connect-timeout 2 --max-time 3 http://[fc00::1]:18084/")

    # The unfiltered host accepts inbound IPv6 HTTP.
    unfiltered.succeed("systemd-run --unit unfiltered-http6-server ${pkgs.python3}/bin/python3 -m http.server 18084 --bind :: --directory /tmp")
    unfiltered.wait_for_unit("unfiltered-http6-server.service")
    unfiltered.succeed("${pkgs.coreutils}/bin/timeout 10 ${pkgs.bash}/bin/bash -c 'until ${pkgs.curl}/bin/curl --fail --max-time 3 http://[::1]:18084/; do sleep 0.2; done'")
    machine.succeed("${pkgs.coreutils}/bin/timeout 10 ${pkgs.bash}/bin/bash -c 'until ${pkgs.curl}/bin/curl --fail --max-time 3 http://[fc00::2]:18084/; do sleep 0.2; done'")

    # Inbound IPv6 UDP to the firewalled host is blocked.
    machine.succeed("rm -f /tmp/inbound-udp6-ready /tmp/inbound-udp6-received")
    machine.succeed("systemd-run --unit blocked-udp6-server ${pkgs.python3}/bin/python3 -c \"import pathlib,socket; s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM); s.bind(('::', 18086)); pathlib.Path('/tmp/inbound-udp6-ready').touch(); data, _ = s.recvfrom(4096); pathlib.Path('/tmp/inbound-udp6-received').write_bytes(data)\"")
    machine.wait_for_unit("blocked-udp6-server.service")
    machine.succeed("${pkgs.coreutils}/bin/timeout 10 ${pkgs.bash}/bin/bash -c 'until test -e /tmp/inbound-udp6-ready; do sleep 0.2; done'")
    unfiltered.succeed("${pkgs.python3}/bin/python3 -c \"import socket; s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM); s.settimeout(1); s.sendto(b'blocked', ('fc00::1', 18086))\"")
    machine.succeed("sleep 2")
    machine.fail("test -e /tmp/inbound-udp6-received")

    # The unfiltered host accepts inbound IPv6 UDP.
    unfiltered.succeed("rm -f /tmp/unfiltered-udp6-ready /tmp/unfiltered-udp6-received")
    unfiltered.succeed("systemd-run --unit unfiltered-udp6-server ${pkgs.python3}/bin/python3 -c \"import pathlib,socket; s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM); s.bind(('::', 18086)); pathlib.Path('/tmp/unfiltered-udp6-ready').touch(); data, _ = s.recvfrom(4096); pathlib.Path('/tmp/unfiltered-udp6-received').write_bytes(data)\"")
    unfiltered.wait_for_unit("unfiltered-udp6-server.service")
    unfiltered.succeed("${pkgs.coreutils}/bin/timeout 10 ${pkgs.bash}/bin/bash -c 'until test -e /tmp/unfiltered-udp6-ready; do sleep 0.2; done'")
    machine.succeed("${pkgs.python3}/bin/python3 -c \"import socket; s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM); s.settimeout(1); s.sendto(b'unfiltered', ('fc00::2', 18086))\"")
    unfiltered.succeed("${pkgs.coreutils}/bin/timeout 10 ${pkgs.bash}/bin/bash -c 'until test -e /tmp/unfiltered-udp6-received; do sleep 0.2; done'")
  '';
}
