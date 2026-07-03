{ nixpkgs, pkgs, stateVersion }:

let
  monitoringPlatform = import ./platform.nix { inherit pkgs; };
in
nixpkgs.lib.nixos.runTest {
  name = "monitoring-generations";
  hostPkgs = pkgs;
  globalTimeout = 180;

  nodes.client = { ... }: {
    imports = [
      ../../modules/restic.nix
      ../../modules/auto-upgrade.nix
      ../../modules/monitoring.nix
    ];

    networking.hostName = "monitoring-client";
    common.autoUpgrade.enable = false;

    common.monitoring = {
      enable = true;
      smart.enable = false;
      restic.enable = false;
      autoUpgrade.enable = false;
      diskSpace.enable = false;
      generations.enable = true;
      generations.maxCount = 3;
      report.credentialDirectory = "/etc/credentials/monitoring";
    };

    # Provision the report URL as a systemd-creds-encrypted blob at boot runtime
    # (encryption needs the host key, which isn't set up yet during activation).
    systemd.services.test-monitoring-credential = {
      wantedBy = [ "multi-user.target" ];
      before = [ "common-monitoring.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        install -d -m 0700 /etc/credentials/monitoring
        printf '%s' 'http://monitoring-platform:8080/health' | ${pkgs.systemd}/bin/systemd-creds encrypt --name=healthchecks-url - /etc/credentials/monitoring/healthchecks-url
        chmod 0600 /etc/credentials/monitoring/healthchecks-url
      '';
    };

    system.stateVersion = stateVersion;
  };

  nodes.platform = { ... }: {
    networking = {
      hostName = "monitoring-platform";
      firewall.allowedTCPPorts = [ 8080 ];
    };

    systemd.services.monitoring-platform = {
      description = "Fake Healthchecks-compatible monitoring platform";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python ${monitoringPlatform}";
        StateDirectory = "monitoring-platform";
      };
    };

    system.stateVersion = stateVersion;
  };

  testScript = ''
    start_all()

    client.wait_for_unit("multi-user.target")
    platform.wait_for_unit("multi-user.target")
    platform.wait_for_unit("monitoring-platform.service")
    platform.wait_for_open_port(8080)

    def reset_platform():
        platform.succeed("rm -f /var/lib/monitoring-platform/events.log /var/lib/monitoring-platform/bodies.log")

    def assert_paths(expected):
        platform.wait_until_succeeds("test -f /var/lib/monitoring-platform/events.log", timeout=30)
        events = platform.succeed("cat /var/lib/monitoring-platform/events.log").strip().splitlines()
        assert events == expected, f"unexpected events: {events}"

    def generation_count():
        return client.succeed("find /nix/var/nix/profiles -maxdepth 1 -name 'system-*-link' | wc -l").strip()

    def make_generations(indices):
        # Real generations via the same `nix-env --set` mechanism nixos-rebuild uses.
        # Each generation points at a distinct store path so --set creates a new
        # generation (setting the same path repeatedly is deduplicated to one).
        for i in indices:
            path = client.succeed(f"mkdir -p /tmp/gen{i} && echo {i} > /tmp/gen{i}/marker && nix-store --add /tmp/gen{i}").strip()
            client.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {path}")

    # Test VMs register no system generations by default.
    assert generation_count() == "0", f"unexpected baseline generation count: {generation_count()}"

    # Run A: count == maxCount (3) -> OK (check uses -gt).
    make_generations(range(1, 4))
    assert generation_count() == "3", f"expected 3 generations, got {generation_count()}"
    reset_platform()
    client.succeed("systemctl start common-monitoring.service")
    assert_paths([
        "POST /health/start",
        "POST /health/log",
        "POST /health",
    ])
    platform.succeed("grep -F '[OK] generations: 3 system generations' /var/lib/monitoring-platform/bodies.log")
    platform.succeed("grep -F 'status=ok' /var/lib/monitoring-platform/bodies.log")
    platform.fail("grep -F 'status=failed' /var/lib/monitoring-platform/bodies.log")

    # Run B: count > maxCount -> FAIL.
    make_generations(range(4, 6))
    assert generation_count() == "5", f"expected 5 generations, got {generation_count()}"
    reset_platform()
    client.fail("systemctl start common-monitoring.service")
    assert_paths([
        "POST /health/start",
        "POST /health/log",
        "POST /health/fail",
    ])
    platform.succeed("grep -F '[FAIL] generations: 5 system generations, above 3' /var/lib/monitoring-platform/bodies.log")
    platform.succeed("grep -F 'status=failed' /var/lib/monitoring-platform/bodies.log")
  '';
}
