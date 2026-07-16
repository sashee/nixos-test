{ nixpkgs, pkgs, stateVersion }:

# Verifies the iroh-ssh monitoring check: FAIL while the tunnel unit is not
# active, OK when it is active with firewall port 22 closed, FAIL when the
# failsafe's port-22 rule is present. The unit is mocked (no relay here) so
# "active" is directly controllable; the real tunnel + failsafe behavior is
# covered end-to-end by tests/iroh-ssh.nix. Self-contained: report.enable =
# false, so the monitoring oneshot's own exit code and journal reflect the
# check result directly (no Healthchecks backend needed).
nixpkgs.lib.nixos.runTest {
  name = "monitoring-iroh-ssh";
  hostPkgs = pkgs;
  globalTimeout = 600;

  nodes.machine = { lib, ... }: {
    imports = [ ../../modules/monitoring.nix ../../modules/restic.nix ../../modules/iroh-ssh.nix ];

    # The check's port-22 half inspects the nftables firewall's chain.
    networking.nftables.enable = true;

    common.irohSsh.credentialDirectory = "/etc/credentials/iroh-ssh";
    # The watchdog would open port 22 for real mid-test (the mocked unit spends
    # time inactive) and race the rule assertions; the failsafe itself is
    # tested in tests/iroh-ssh.nix.
    common.irohSsh.failsafe.enable = false;

    # Mock the tunnel unit so its active state is controllable without a
    # relay: mkForce replaces the whole hardened serviceConfig (including the
    # credential load and Restart=always) and drops the ConditionPathExists
    # skip, leaving a plain oneshot that is active after start, inactive after
    # stop.
    systemd.services.iroh-ssh.serviceConfig = lib.mkForce {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/true";
    };
    systemd.services.iroh-ssh.unitConfig.ConditionPathExists = lib.mkForce [ ];

    common.monitoring = {
      enable = true;
      report.enable = false;
      smart.enable = false;
      restic.enable = false;
      diskSpace.enable = false;
      generations.enable = false;
      autoUpgrade.enable = false;
      nixGc.enable = false;
      # irohSsh.enable is left at its default: follows common.irohSsh.enable.
    };

    system.stateVersion = stateVersion;
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    def monitoring_log():
        return machine.succeed("journalctl -u common-monitoring.service -o cat --no-pager")

    with subtest("tunnel not active -> FAIL"):
        machine.succeed("systemctl stop iroh-ssh.service")
        machine.fail("systemctl start common-monitoring.service")
        assert "[FAIL] iroh-ssh: iroh-ssh.service is inactive" in monitoring_log()

    with subtest("service active, port 22 closed -> OK"):
        machine.succeed("systemctl start iroh-ssh.service")
        machine.succeed("systemctl start common-monitoring.service")
        assert "[OK] iroh-ssh: service running, port 22 closed" in monitoring_log()

    with subtest("service active but failsafe rule present -> FAIL"):
        machine.succeed(
            "${pkgs.nftables}/bin/nft insert rule inet nixos-fw input-allow"
            " tcp dport 22 accept comment '\"iroh-ssh-failsafe\"'"
        )
        machine.fail("systemctl start common-monitoring.service")
        assert "[FAIL] iroh-ssh: failsafe engaged, port 22 open" in monitoring_log()
  '';
}
