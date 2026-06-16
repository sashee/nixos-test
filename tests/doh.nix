{ nixpkgs, pkgs, commonDesktopModule, stateVersion }:

nixpkgs.lib.nixos.runTest {
  name = "doh";
  hostPkgs = pkgs;
  skipTypeCheck = true;

  nodes.machine = { pkgs, ... }: {
    imports = [ commonDesktopModule ];

    networking.hostName = "doh-test";
    common.autoUpgrade.enable = false;
    common.monitoring.enable = false;
    system.stateVersion = stateVersion;
  };

  nodes.dnsPeer = { pkgs, ... }: {
    imports = [ commonDesktopModule ];

    common = {
      autoUpgrade.enable = false;
      monitoring.enable = false;
      doh.enable = false;
      firewall.enable = false;
    };
    networking = {
      firewall.enable = false;
      hostName = "dns-peer";
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

    machine = by_hostname("doh-test")
    dns_peer = by_hostname("dns-peer")

    machine.succeed("systemctl is-active dnscrypt-proxy.service")
    machine.succeed("systemctl is-active nftables.service")
    machine.succeed("${pkgs.nftables}/bin/nft list table inet common-doh-egress")
    machine.succeed("grep -E '^nameserver 127\\.0\\.0\\.1$' /etc/resolv.conf")
    machine.succeed("grep -E '^nameserver ::1$' /etc/resolv.conf")
    machine.succeed("${pkgs.gnugrep}/bin/grep cloudflare-ipv4 /nix/store/*-dnscrypt-proxy.toml")
    machine.succeed("${pkgs.gnugrep}/bin/grep cloudflare-ipv6 /nix/store/*-dnscrypt-proxy.toml")
    machine.succeed("${pkgs.gnugrep}/bin/grep mullvad-ipv4 /nix/store/*-dnscrypt-proxy.toml")
    machine.succeed("${pkgs.gnugrep}/bin/grep mullvad-ipv6 /nix/store/*-dnscrypt-proxy.toml")
    machine.succeed("${pkgs.gnugrep}/bin/grep quad9-ipv4 /nix/store/*-dnscrypt-proxy.toml")
    machine.succeed("${pkgs.gnugrep}/bin/grep quad9-ipv6 /nix/store/*-dnscrypt-proxy.toml")
    machine.succeed("${pkgs.gnugrep}/bin/grep google-ipv4 /nix/store/*-dnscrypt-proxy.toml")
    machine.succeed("${pkgs.gnugrep}/bin/grep google-ipv6 /nix/store/*-dnscrypt-proxy.toml")

    dns_peer.succeed("rm -f /tmp/plain-dns-udp-ready /tmp/plain-dns-udp-received /tmp/plain-dns-tcp-ready /tmp/plain-dns-tcp-received")
    dns_peer.succeed("systemd-run --unit plain-dns-udp-server ${pkgs.python3}/bin/python3 -c \"import pathlib,socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(('0.0.0.0', 53)); pathlib.Path('/tmp/plain-dns-udp-ready').touch(); data, _ = s.recvfrom(4096); pathlib.Path('/tmp/plain-dns-udp-received').write_bytes(data)\"")
    dns_peer.wait_for_unit("plain-dns-udp-server.service")
    dns_peer.succeed("${pkgs.coreutils}/bin/timeout 10 ${pkgs.bash}/bin/bash -c 'until test -e /tmp/plain-dns-udp-ready; do sleep 0.2; done'")

    machine.fail("${pkgs.dig}/bin/dig @dns-peer example.test A +time=1 +tries=1")
    dns_peer.succeed("sleep 2")
    dns_peer.fail("test -e /tmp/plain-dns-udp-received")

    dns_peer.succeed("systemd-run --unit plain-dns-tcp-server ${pkgs.python3}/bin/python3 -c \"import pathlib,socket; s = socket.socket(socket.AF_INET, socket.SOCK_STREAM); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('0.0.0.0', 53)); s.listen(1); pathlib.Path('/tmp/plain-dns-tcp-ready').touch(); conn, _ = s.accept(); pathlib.Path('/tmp/plain-dns-tcp-received').touch(); conn.close()\"")
    dns_peer.wait_for_unit("plain-dns-tcp-server.service")
    dns_peer.succeed("${pkgs.coreutils}/bin/timeout 10 ${pkgs.bash}/bin/bash -c 'until test -e /tmp/plain-dns-tcp-ready; do sleep 0.2; done'")

    machine.fail("${pkgs.python3}/bin/python3 -c \"import socket; s = socket.create_connection(('dns-peer', 53), timeout=2); s.close()\"")
    dns_peer.succeed("sleep 2")
    dns_peer.fail("test -e /tmp/plain-dns-tcp-received")

    machine.succeed("${pkgs.python3}/bin/python3 -c \"import socket; s = socket.create_connection(('127.0.0.1', 53), timeout=2); s.close()\"")
    machine.succeed("${pkgs.python3}/bin/python3 -c \"import socket; s = socket.create_connection(('::1', 53), timeout=2); s.close()\"")
  '';
}
