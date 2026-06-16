{ nixpkgs, pkgs, stateVersion }:

let
  monitoringPlatform = import ./platform.nix { inherit pkgs; };
in
nixpkgs.lib.nixos.runTest {
  name = "monitoring-disk-space";
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
    boot.kernelModules = [ "loop" ];
    environment.systemPackages = [ pkgs.e2fsprogs ];

    common.monitoring = {
      enable = true;
      smart.enable = false;
      restic.enable = false;
      autoUpgrade.enable = false;
      generations.maxCount = 999;
      diskSpace.enable = true;
      diskSpace.maxUsedPercent = 90;
      report.credentialDirectory = "/etc/credentials/monitoring";
    };

    system.activationScripts.monitoringCredentials = ''
      install -d -m 0700 /etc/credentials/monitoring
      printf '%s' 'http://monitoring-platform:8080/health' > /etc/credentials/monitoring/healthchecks-url
      chmod 0600 /etc/credentials/monitoring/healthchecks-url
    '';

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

    # Controlled, non-excluded local filesystem whose fill level drives the check result.
    client.succeed("truncate -s 20M /test.img")
    client.succeed("mkfs.ext4 -q -m 0 /test.img")
    client.succeed("mkdir -p /mnt/testfs")
    client.succeed("mount -o loop /test.img /mnt/testfs")

    # Near-full tmpfs to prove the excludeFsTypes skip path (tmpfs is excluded).
    client.succeed("mkdir -p /mnt/excluded")
    client.succeed("mount -t tmpfs -o size=2M tmpfs /mnt/excluded")
    client.succeed("dd if=/dev/zero of=/mnt/excluded/fill bs=1M count=2 || true")

    # Run A: controlled fs under threshold -> OK, and excluded tmpfs is skipped.
    reset_platform()
    client.succeed("systemctl start common-monitoring.service")
    assert_paths([
        "POST /health/start",
        "POST /health/log",
        "POST /health",
    ])
    platform.succeed("grep -F '[OK] disk-space: /mnt/testfs is' /var/lib/monitoring-platform/bodies.log")
    platform.succeed("grep -F 'status=ok' /var/lib/monitoring-platform/bodies.log")
    platform.fail("grep -F 'status=failed' /var/lib/monitoring-platform/bodies.log")
    platform.fail("grep -F 'disk-space: /mnt/excluded' /var/lib/monitoring-platform/bodies.log")

    # Run B: controlled fs over threshold -> FAIL. Fill it to capacity; dd hitting
    # ENOSPC (non-zero exit) is the intended ~100%-full state, so tolerate it.
    client.succeed("dd if=/dev/zero of=/mnt/testfs/fill bs=1M count=19 || true")
    reset_platform()
    client.fail("systemctl start common-monitoring.service")
    assert_paths([
        "POST /health/start",
        "POST /health/log",
        "POST /health/fail",
    ])
    platform.succeed("grep -F '[FAIL] disk-space: /mnt/testfs is' /var/lib/monitoring-platform/bodies.log | grep -F 'above 90%'")
    platform.succeed("grep -F 'status=failed' /var/lib/monitoring-platform/bodies.log")
  '';
}
