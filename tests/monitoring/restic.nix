{ nixpkgs, pkgs, commonDesktopModule, stateVersion }:

let
  resticLib = import ../../lib/restic.nix { lib = nixpkgs.lib; };
  nixpkgsDate = nixpkgs.lastModifiedDate;
  testClockDate = "${builtins.substring 0 4 nixpkgsDate}-${builtins.substring 4 2 nixpkgsDate}-${builtins.substring 6 2 nixpkgsDate}";
  testClockBase = "${testClockDate}T23:00:00";

  monitoringPlatform = import ./platform.nix { inherit pkgs; };

  clientModule = name: healthPath: restUrl: backendPassword: { ... }: {
    imports = [
      commonDesktopModule
    ];

    networking.hostName = name;
    boot.initrd.availableKernelModules = [ "rtc_cmos" ];
    common.autoUpgrade.enable = false;

    users.users.backup-user = {
      isNormalUser = true;
      home = "/home/backup-user";
    };

    # Restic creds stay plaintext (restic uses LoadCredential); fine to write at activation.
    system.activationScripts.monitoringResticCredentials = ''
      install -d -m 0700 /etc/credentials/monitoring /etc/credentials/restic/monitored
      install -d -m 0755 -o backup-user -g users /home/backup-user/monitored

      printf '%s' 'repo-secret' > /etc/credentials/restic/monitored/repository-password
      printf '%s' 'test-user' > /etc/credentials/restic/monitored/backend-username
      printf '%s' '${backendPassword}' > /etc/credentials/restic/monitored/backend-password
      printf '%s\n' '${name} payload' > /home/backup-user/monitored/payload.txt

      chmod 0600 \
        /etc/credentials/restic/monitored/repository-password \
        /etc/credentials/restic/monitored/backend-username \
        /etc/credentials/restic/monitored/backend-password
      chown backup-user:users /home/backup-user/monitored/payload.txt
    '';

    # The monitoring report URL must be a systemd-creds-encrypted blob; encrypt it at
    # boot runtime (the host key isn't available during activation).
    systemd.services.test-monitoring-credential = {
      wantedBy = [ "multi-user.target" ];
      before = [ "common-monitoring.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        install -d -m 0700 /etc/credentials/monitoring
        printf '%s' 'http://monitoring-platform:8080/${healthPath}' | ${pkgs.systemd}/bin/systemd-creds encrypt --name=healthchecks-url - /etc/credentials/monitoring/healthchecks-url
        chmod 0600 /etc/credentials/monitoring/healthchecks-url
      '';
    };

    common.restic.backups.monitored = resticLib.rest {
      user = "backup-user";
      credentialDirectory = "/etc/credentials/restic/monitored";
      url = restUrl;
      repository = name;
      paths = [ "/home/backup-user/monitored" ];
      prune.opts = [ "--keep-last 2" ];
    };

    common.monitoring = {
      enable = true;
      smart.enable = false;
      restic.enable = true;
      autoUpgrade.enable = false;
      diskSpace.maxUsedPercent = 99;
      generations.maxCount = 999;
      report.credentialDirectory = "/etc/credentials/monitoring";
    };

    virtualisation.qemu.options = [
      "-rtc"
      "base=${testClockBase},clock=vm"
      "-cpu"
      "host,kvmclock=off"
    ];

    # This test warps the clock past 14 days; the Persistent nix-gc.timer would
    # otherwise fire a catch-up collect mid-test and starve the monitoring run.
    nix.gc.automatic = nixpkgs.lib.mkForce false;

    system.stateVersion = stateVersion;
  };
in
nixpkgs.lib.nixos.runTest {
  name = "monitoring-restic";
  hostPkgs = pkgs;
  globalTimeout = 240;

  nodes.good-client = clientModule "good-client" "good" "http://monitoring-platform:8000" "backend-secret";
  nodes.bad-client = clientModule "bad-client" "bad" "http://monitoring-platform:8000" "wrong-backend-secret";

  nodes.platform = { ... }: {
    networking = {
      hostName = "monitoring-platform";
      firewall.allowedTCPPorts = [ 8000 8080 ];
    };

    systemd.sockets.restic-rest-auth = {
      listenStreams = [ "8000" ];
      wantedBy = [ "sockets.target" ];
    };

    systemd.services.restic-rest-auth = {
      description = "Authenticated Restic REST Server";
      after = [ "network.target" "restic-rest-auth.socket" ];
      requires = [ "restic-rest-auth.socket" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = pkgs.writeShellScript "restic-rest-auth" ''
          set -eu
          if [ ! -e /var/lib/restic/.htpasswd ]; then
            ${pkgs.apacheHttpd}/bin/htpasswd -Bbc /var/lib/restic/.htpasswd test-user backend-secret
          fi
          exec ${pkgs.restic-rest-server}/bin/rest-server --path /var/lib/restic
        '';
        Type = "simple";
      };
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/restic 0755 root root -"
    ];

    systemd.services.monitoring-platform = {
      description = "Fake Healthchecks-compatible monitoring platform";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python ${monitoringPlatform}";
        StateDirectory = "monitoring-platform";
      };
    };

    virtualisation.qemu.options = [
      "-rtc"
      "base=${testClockBase},clock=vm"
      "-cpu"
      "host,kvmclock=off"
    ];

    system.stateVersion = stateVersion;
  };

  testScript = ''
    from datetime import datetime, timedelta

    start_all()

    for node in machines:
        node.wait_for_unit("multi-user.target")

    platform.wait_for_unit("restic-rest-auth.socket")
    platform.wait_for_unit("monitoring-platform.service")
    platform.wait_for_open_port(8000)
    platform.wait_for_open_port(8080)

    for client in [good_client, bad_client]:
        client.succeed("systemctl show restic-backups-monitored.timer -p TimersCalendar --value | grep -F '*-*-* 00:00:00'")
        client.succeed("systemctl show restic-backups-monitored.timer -p Persistent --value | grep -F yes")
        client.succeed("systemctl show restic-backups-monitored.timer -p RandomizedDelayUSec --value | grep -F '1h'")
        client.succeed("systemctl is-active --quiet restic-backups-monitored.timer")
        client.succeed("systemctl show common-monitoring.timer -p TimersCalendar --value | grep -F '*-*-* 00:00:00'")
        client.succeed("systemctl show common-monitoring.timer -p Persistent --value | grep -F yes")
        client.succeed("systemctl show common-monitoring.timer -p RandomizedDelayUSec --value | grep -F '10min'")
        client.succeed("systemctl is-active --quiet common-monitoring.timer")

    def set_time(timestamp, nodes=None):
        for node in (nodes or [good_client, bad_client, platform]):
            node.succeed(f"date -s '{timestamp}'")

    test_clock_day = datetime.strptime("${testClockDate}", "%Y-%m-%d").date()

    def test_timestamp(days, time):
        return f"{test_clock_day + timedelta(days=days)} {time}"

    marker = "/var/lib/common-monitoring/restic-backups-monitored.service.last-success"

    def reset_platform():
        platform.succeed("rm -f /var/lib/monitoring-platform/events.log /var/lib/monitoring-platform/bodies.log")

    def assert_events(prefix, expected):
        events = platform.succeed("cat /var/lib/monitoring-platform/events.log").strip().splitlines()
        got = [event for event in events if event.startswith(f"POST /{prefix}")]
        assert got == expected, f"unexpected {prefix} events: {got}"

    # Warm up: a jump past the backup timer's 1h randomized-delay window fires the
    # overdue backup. good-client succeeds and records its last-success marker;
    # bad-client (wrong backend auth) fails and records nothing. From here the test
    # only jumps the clock and inspects the recorded reports — it never touches the
    # clients' units.
    set_time(test_timestamp(1, "01:05:00"))
    good_client.wait_until_succeeds(f"test -r {marker}", timeout=120)
    bad_client.fail(f"test -e {marker}")

    # Recent success: good reports OK (last success within maxAge); bad has never
    # succeeded, so it reports "no successful run". A bare "POST /good" is the
    # success ping; "POST /bad/fail" is the failure ping.
    reset_platform()
    set_time(test_timestamp(2, "01:05:00"))
    platform.wait_until_succeeds("grep -Fxq 'POST /good' /var/lib/monitoring-platform/events.log && grep -Fxq 'POST /bad/fail' /var/lib/monitoring-platform/events.log", timeout=120)
    assert_events("good", ["POST /good/start", "POST /good/log", "POST /good"])
    assert_events("bad", ["POST /bad/start", "POST /bad/log", "POST /bad/fail"])
    platform.succeed("grep -F '[OK] restic monitored: restic-backups-monitored.service last succeeded' /var/lib/monitoring-platform/bodies.log")
    platform.succeed("grep -F '[FAIL] restic monitored: restic-backups-monitored.service has no successful run recorded' /var/lib/monitoring-platform/bodies.log")
    platform.succeed("grep -F 'status=ok' /var/lib/monitoring-platform/bodies.log")
    platform.succeed("grep -F 'status=failed' /var/lib/monitoring-platform/bodies.log")

    # Stale: stop the backend so good can no longer succeed; its last success then
    # ages past maxAge (14d). Intervening failed backups don't matter — only the
    # absence of a recent *success* does.
    platform.succeed("systemctl stop restic-rest-auth.socket restic-rest-auth.service")
    reset_platform()
    set_time(test_timestamp(17, "01:05:00"), [good_client, platform])
    platform.wait_until_succeeds("grep -Fxq 'POST /good/fail' /var/lib/monitoring-platform/events.log", timeout=120)
    assert_events("good", ["POST /good/start", "POST /good/log", "POST /good/fail"])
    platform.succeed("grep -F '[FAIL] restic monitored: restic-backups-monitored.service last succeeded' /var/lib/monitoring-platform/bodies.log | grep -F 'older than 14d'")
    platform.succeed("grep -F 'status=failed' /var/lib/monitoring-platform/bodies.log")
  '';
}
