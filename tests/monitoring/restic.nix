{ nixpkgs, pkgs, commonDesktopModule, stateVersion }:

let
  resticLib = import ../../lib/restic.nix { lib = nixpkgs.lib; };
  nixpkgsDate = nixpkgs.lastModifiedDate;
  testClockDate = "${builtins.substring 0 4 nixpkgsDate}-${builtins.substring 4 2 nixpkgsDate}-${builtins.substring 6 2 nixpkgsDate}";
  testClockBase = "${testClockDate}T23:00:00";

  monitoringPlatform = pkgs.writeText "monitoring-platform.py" ''
    from http.server import BaseHTTPRequestHandler, HTTPServer
    from pathlib import Path

    state_dir = Path("/var/lib/monitoring-platform")
    state_dir.mkdir(parents=True, exist_ok=True)

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length).decode("utf-8", errors="replace")

            with (state_dir / "events.log").open("a") as events:
                events.write(f"{self.command} {self.path}\n")

            with (state_dir / "bodies.log").open("a") as bodies:
                bodies.write(f"--- {self.command} {self.path} ---\n")
                bodies.write(body)
                bodies.write("\n")

            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"OK")

        def log_message(self, _format, *_args):
            return

    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
  '';

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

    system.activationScripts.monitoringResticCredentials = ''
      install -d -m 0700 /etc/credentials/monitoring /etc/credentials/restic/monitored
      install -d -m 0755 -o backup-user -g users /home/backup-user/monitored

      printf '%s' 'http://monitoring-platform:8080/${healthPath}' > /etc/credentials/monitoring/healthchecks-url
      printf '%s' 'repo-secret' > /etc/credentials/restic/monitored/repository-password
      printf '%s' 'test-user' > /etc/credentials/restic/monitored/backend-username
      printf '%s' '${backendPassword}' > /etc/credentials/restic/monitored/backend-password
      printf '%s\n' '${name} payload' > /home/backup-user/monitored/payload.txt

      chmod 0600 \
        /etc/credentials/monitoring/healthchecks-url \
        /etc/credentials/restic/monitored/repository-password \
        /etc/credentials/restic/monitored/backend-username \
        /etc/credentials/restic/monitored/backend-password
      chown backup-user:users /home/backup-user/monitored/payload.txt
    '';

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

    def restic_completion_timestamp(client):
        timestamp = client.succeed("systemctl show restic-backups-monitored.service -p ExecMainExitTimestamp --value").strip()
        if timestamp == "":
            timestamp = client.succeed("systemctl show restic-backups-monitored.service -p InactiveEnterTimestamp --value").strip()
        assert timestamp != "", "restic service has no completion timestamp"
        return timestamp

    def restic_state_timestamp(client):
        timestamp = client.succeed("systemctl show restic-backups-monitored.service -p StateChangeTimestamp --value").strip()
        assert timestamp != "", "restic service has no state-change timestamp"
        return timestamp

    def wait_for_restic_success(client):
        client.wait_until_succeeds("systemctl show restic-backups-monitored.service -p ActiveState --value | grep -F inactive && systemctl show restic-backups-monitored.service -p Result --value | grep -F success && journalctl -u restic-backups-monitored.service | grep -F 'snapshot '", timeout=120)

    def wait_for_restic_result(client, pattern):
        client.wait_until_succeeds(f"systemctl show restic-backups-monitored.service -p ActiveState --value | grep -E 'inactive|failed' && systemctl show restic-backups-monitored.service -p Result --value | grep -E '{pattern}'", timeout=120)

    def service_state_timestamp(client, unit):
        return client.succeed(f"systemctl show {unit} -p StateChangeTimestamp --value").strip()

    def wait_for_monitoring_result_after(client, previous_timestamp, pattern):
        client.wait_until_succeeds(f"test \"$(systemctl show common-monitoring.service -p StateChangeTimestamp --value)\" != \"{previous_timestamp}\" && systemctl show common-monitoring.service -p ActiveState --value | grep -E 'inactive|failed' && systemctl show common-monitoring.service -p Result --value | grep -E '{pattern}'", timeout=120)

    set_time(test_timestamp(1, "01:05:00"))
    wait_for_restic_success(good_client)
    wait_for_restic_result(bad_client, "exit-code|timeout|signal")

    good_monitoring_timestamp = service_state_timestamp(good_client, "common-monitoring.service")
    bad_monitoring_timestamp = service_state_timestamp(bad_client, "common-monitoring.service")
    set_time(test_timestamp(2, "00:15:00"))
    wait_for_monitoring_result_after(good_client, good_monitoring_timestamp, "success")
    wait_for_monitoring_result_after(bad_client, bad_monitoring_timestamp, "exit-code")

    last_good_restic_timestamp = restic_completion_timestamp(good_client)
    good_client.succeed("systemctl stop restic-backups-monitored.timer")
    stale_monitoring_timestamp = service_state_timestamp(good_client, "common-monitoring.service")
    set_time(test_timestamp(16, "00:15:00"), [good_client, platform])
    wait_for_monitoring_result_after(good_client, stale_monitoring_timestamp, "exit-code")
    good_client.succeed(f"test \"$(systemctl show restic-backups-monitored.service -p ExecMainExitTimestamp --value)\" = \"{last_good_restic_timestamp}\"")

    platform.wait_until_succeeds("test -f /var/lib/monitoring-platform/events.log && grep -F 'POST /good' /var/lib/monitoring-platform/events.log && grep -F 'POST /bad/fail' /var/lib/monitoring-platform/events.log", timeout=120)

    events = platform.succeed("cat /var/lib/monitoring-platform/events.log").strip().splitlines()
    good_events = [event for event in events if event.startswith("POST /good")]
    bad_events = [event for event in events if event.startswith("POST /bad")]
    expected_good_events = [
        "POST /good/start",
        "POST /good/log",
        "POST /good",
    ]
    expected_good_stale_events = [
        "POST /good/start",
        "POST /good/log",
        "POST /good/fail",
    ]
    expected_bad_events = [
        "POST /bad/start",
        "POST /bad/log",
        "POST /bad/fail",
    ]
    assert len(good_events) >= 3 and len(good_events) % 3 == 0, f"unexpected good monitoring events: {good_events}"
    assert len(bad_events) >= 3 and len(bad_events) % 3 == 0, f"unexpected bad monitoring events: {bad_events}"
    assert any(good_events[index:index + 3] == expected_good_events for index in range(0, len(good_events), 3)), f"missing good success monitoring events: {good_events}"
    assert good_events[-3:] == expected_good_stale_events, f"missing final stale good monitoring events: {good_events}"
    assert all(bad_events[index:index + 3] == expected_bad_events for index in range(0, len(bad_events), 3)), f"unexpected bad monitoring events: {bad_events}"

    platform.succeed("grep -F '[OK] restic monitored: restic-backups-monitored.service last succeeded' /var/lib/monitoring-platform/bodies.log")
    platform.succeed("grep -F '[FAIL] restic monitored: restic-backups-monitored.service result is' /var/lib/monitoring-platform/bodies.log")
    platform.succeed("grep -F '[FAIL] restic monitored: restic-backups-monitored.service last succeeded' /var/lib/monitoring-platform/bodies.log | grep -F 'older than 14d'")
    platform.succeed("grep -F 'status=ok' /var/lib/monitoring-platform/bodies.log")
    platform.succeed("grep -F 'status=failed' /var/lib/monitoring-platform/bodies.log")
  '';
}
