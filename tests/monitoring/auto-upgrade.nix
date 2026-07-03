{ nixpkgs, pkgs, stateVersion }:

let
  monitoringPlatform = import ./platform.nix { inherit pkgs; };

  nixpkgsDate = nixpkgs.lastModifiedDate;
  testClockDate = "${builtins.substring 0 4 nixpkgsDate}-${builtins.substring 4 2 nixpkgsDate}-${builtins.substring 6 2 nixpkgsDate}";
  testClockBase = "${testClockDate}T23:00:00";

  # A real NixOS upgrade can't run in a VM, so mock the upgrade command. It fails
  # on demand when /run/upgrade-status contains "fail" (default: succeed).
  fakeNixosRebuild = pkgs.runCommand "fake-nixos-rebuild" { } ''
    mkdir -p $out/bin
    cat > $out/bin/nixos-rebuild <<'EOF'
    #!${pkgs.runtimeShell}
    set -eu
    if [ "$(cat /run/upgrade-status 2>/dev/null || printf ok)" = fail ]; then
      printf 'fake nixos-rebuild failing\n' >&2
      exit 1
    fi
    exit 0
    EOF
    chmod +x $out/bin/nixos-rebuild
  '';

  # Satisfies the `nix flake update` preStart of nixos-upgrade.service.
  fakeNix = pkgs.writeShellScriptBin "nix" ''
    exit 0
  '';

  clockQemuOptions = [
    "-rtc"
    "base=${testClockBase},clock=vm"
    "-cpu"
    "host,kvmclock=off"
  ];
in
nixpkgs.lib.nixos.runTest {
  name = "monitoring-auto-upgrade";
  hostPkgs = pkgs;
  globalTimeout = 240;

  nodes.client = { lib, ... }: {
    imports = [
      ../../modules/restic.nix
      ../../modules/auto-upgrade.nix
      ../../modules/monitoring.nix
    ];

    networking.hostName = "monitoring-client";
    boot.initrd.availableKernelModules = [ "rtc_cmos" ];

    common.autoUpgrade.enable = true;
    common.autoUpgrade.flake = "/etc/nixos#laptop";

    common.monitoring = {
      enable = true;
      smart.enable = false;
      restic.enable = false;
      diskSpace.enable = false;
      generations.enable = false;
      autoUpgrade.enable = true;
      autoUpgrade.maxAge = "14d";
      report.credentialDirectory = "/etc/credentials/monitoring";
    };

    system.build.nixos-rebuild = lib.mkForce fakeNixosRebuild;
    systemd.services.nixos-upgrade.path = lib.mkBefore [ fakeNix ];

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

    virtualisation.qemu.options = clockQemuOptions;

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

    virtualisation.qemu.options = clockQemuOptions;

    system.stateVersion = stateVersion;
  };

  testScript = ''
    from datetime import datetime, timedelta

    start_all()

    client.wait_for_unit("multi-user.target")
    platform.wait_for_unit("multi-user.target")
    platform.wait_for_unit("monitoring-platform.service")
    platform.wait_for_open_port(8080)

    def reset_platform():
        platform.succeed("rm -f /var/lib/monitoring-platform/events.log /var/lib/monitoring-platform/bodies.log")

    def assert_paths(expected):
        events = platform.succeed("cat /var/lib/monitoring-platform/events.log").strip().splitlines()
        assert events == expected, f"unexpected events: {events}"

    test_clock_day = datetime.strptime("${testClockDate}", "%Y-%m-%d").date()

    def test_timestamp(days, time):
        return f"{test_clock_day + timedelta(days=days)} {time}"

    def set_time(timestamp, nodes=None):
        for node in (nodes or [client, platform]):
            node.succeed(f"date -s '{timestamp}'")

    marker = "/var/lib/common-monitoring/nixos-upgrade.service.last-success"

    # Warm up: a jump past nixos-upgrade.timer's 2h randomized-delay window fires
    # the overdue upgrade; the mocked rebuild succeeds (default) and records the
    # last-success marker. From here the test only jumps the clock and inspects —
    # it never starts/stops the client's units; it only flips the mock's outcome
    # via /run/upgrade-status (the fixture lever).
    set_time(test_timestamp(1, "02:05:00"))
    client.wait_until_succeeds(f"test -r {marker}", timeout=120)

    # Recent success -> monitoring OK.
    reset_platform()
    set_time(test_timestamp(2, "02:05:00"))
    platform.wait_until_succeeds("grep -Fxq 'POST /health' /var/lib/monitoring-platform/events.log", timeout=120)
    assert_paths(["POST /health/start", "POST /health/log", "POST /health"])
    platform.succeed("grep -F '[OK] auto-upgrade: nixos-upgrade.service last succeeded' /var/lib/monitoring-platform/bodies.log")
    platform.succeed("grep -F 'status=ok' /var/lib/monitoring-platform/bodies.log")
    platform.fail("grep -F 'status=failed' /var/lib/monitoring-platform/bodies.log")

    # Stale: make the upgrade start failing so no new success is recorded; its last
    # success then ages past maxAge (14d). Intervening failed runs don't matter.
    client.succeed("printf '%s' fail > /run/upgrade-status")
    reset_platform()
    set_time(test_timestamp(17, "02:05:00"))
    platform.wait_until_succeeds("grep -Fxq 'POST /health/fail' /var/lib/monitoring-platform/events.log", timeout=120)
    assert_paths(["POST /health/start", "POST /health/log", "POST /health/fail"])
    platform.succeed("grep -F '[FAIL] auto-upgrade: nixos-upgrade.service last succeeded' /var/lib/monitoring-platform/bodies.log | grep -F 'older than 14d'")
    platform.succeed("grep -F 'status=failed' /var/lib/monitoring-platform/bodies.log")
  '';
}
