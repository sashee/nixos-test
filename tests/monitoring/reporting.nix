{ nixpkgs, pkgs, commonDesktopModule, stateVersion }:

let
  fakeSmartmontools = pkgs.writeShellScriptBin "smartctl" ''
    set -eu

    case "$*" in
      "--scan-open --json")
        cat <<'JSON'
    {"devices":[{"name":"/dev/testdisk","type":"sat"}]}
    JSON
        ;;
      "--json --health --all -d sat /dev/testdisk")
        if [ "$(cat /run/smart-status 2>/dev/null || printf healthy)" = healthy ]; then
          cat <<'JSON'
    {"smart_status":{"passed":true}}
    JSON
        else
          cat <<'JSON'
    {"smart_status":{"passed":false}}
    JSON
        fi
        ;;
      *)
        printf 'unexpected smartctl arguments: %s\n' "$*" >&2
        exit 2
        ;;
    esac
  '';

  monitoringPlatform = import ./platform.nix { inherit pkgs; };
in
nixpkgs.lib.nixos.runTest {
  name = "monitoring-reporting";
  hostPkgs = pkgs;
  globalTimeout = 180;

  # Exercise monitoring within the full laptop module (commonDesktopModule = the real
  # laptop base), overriding only what isolates the smart + reporting behavior.
  nodes.client = { ... }: {
    imports = [ commonDesktopModule ];

    networking.hostName = "monitoring-client";
    common.autoUpgrade.enable = false;

    common.monitoring = {
      enable = true;
      tools.smartmontools = fakeSmartmontools;
      restic.enable = false;
      autoUpgrade.enable = false;
      diskSpace.maxUsedPercent = 99;
      generations.maxCount = 999;
      report.credentialDirectory = "/etc/credentials/monitoring";
      timerConfig = {
        OnCalendar = "hourly";
        Persistent = true;
        RandomizedDelaySec = "10m";
      };
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

    client.succeed("systemctl show common-monitoring.timer -p TimersCalendar --value | grep -F '*-*-* *:00:00'")
    client.succeed("systemctl show common-monitoring.timer -p Persistent --value | grep -F yes")
    client.succeed("systemctl show common-monitoring.timer -p RandomizedDelayUSec --value | grep -F '10min'")
    client.succeed("systemctl is-active --quiet common-monitoring.timer")
    client.succeed("systemctl cat common-monitoring.service | grep -F 'LoadCredentialEncrypted=healthchecks-url:/etc/credentials/monitoring/healthchecks-url'")
    client.fail("systemctl cat common-monitoring.service | grep -F 'http://monitoring-platform:8080/health'")

    def reset_platform():
        platform.succeed("rm -f /var/lib/monitoring-platform/events.log /var/lib/monitoring-platform/bodies.log")

    def assert_paths(expected):
        platform.wait_until_succeeds("test -f /var/lib/monitoring-platform/events.log", timeout=30)
        events = platform.succeed("cat /var/lib/monitoring-platform/events.log").strip().splitlines()
        assert events == expected, f"unexpected events: {events}"

    reset_platform()
    client.succeed("printf '%s' healthy > /run/smart-status")
    client.succeed("systemctl start common-monitoring.service")
    assert_paths([
        "POST /health/start",
        "POST /health/log",
        "POST /health",
    ])
    platform.succeed("grep -F '[OK] smart: /dev/testdisk reports healthy' /var/lib/monitoring-platform/bodies.log")
    platform.succeed("grep -F 'status=ok' /var/lib/monitoring-platform/bodies.log")
    platform.fail("grep -F 'status=failed' /var/lib/monitoring-platform/bodies.log")

    reset_platform()
    client.succeed("printf '%s' failing > /run/smart-status")
    client.fail("systemctl start common-monitoring.service")
    assert_paths([
        "POST /health/start",
        "POST /health/log",
        "POST /health/fail",
    ])
    platform.succeed("grep -F '[FAIL] smart: /dev/testdisk does not report healthy SMART status' /var/lib/monitoring-platform/bodies.log")
    platform.succeed("grep -F 'status=failed' /var/lib/monitoring-platform/bodies.log")
  '';
}
