{ nixpkgs, pkgs, stateVersion, machineModule }:

# Clock-driven monitoring test on the REAL Raspberry Pi 5 config (hosts/rpi5), booted
# on the Pi kernel. The x86 monitoring tests already cover module behavior; this one
# proves the deployed Pi config integrates monitoring correctly and does it the way the
# host does: it never starts a unit by hand -- it warps the clock so the timers fire on
# their own (monitoring every 30 min; restic/upgrade Persistent daily), then inspects reports.
#
# On top of the real config it layers three test-only things:
#   - one restic backup (the Pi has none yet, but will) so the restic check reports for real,
#   - a mocked nixos-rebuild so the (real, enabled) auto-upgrade succeeds in a VM, and
#   - nix.gc.automatic off, so a warp-triggered catch-up GC can't starve the monitoring run.
# smart stays [SKIP] (the Pi's real setting, untouched).

let
  resticLib = import ../../lib/restic.nix { lib = nixpkgs.lib; };
  monitoringPlatform = import ./platform.nix { inherit pkgs; };

  # A real NixOS upgrade can't run in a VM, so mock the upgrade command. It fails on
  # demand when /run/upgrade-status contains "fail" (default: succeed).
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
in
nixpkgs.lib.nixos.runTest {
  name = "monitoring-rpi";
  hostPkgs = pkgs;
  globalTimeout = 2400;
  # The rpi (nixos-raspberrypi) test driver is an older nixpkgs whose static checks
  # (mypy + pyflakes) don't recognize multi-node globals like `client`/`platform` --
  # every other rpi test uses a single `machine` node. The names are still injected at
  # runtime, so skip the static passes (tests/doh.nix already skips the type check).
  skipTypeCheck = true;
  skipLint = true;

  nodes.client = { lib, ... }: {
    imports = [ machineModule ];

    # Plain value beats the Pi config's mkDefault "nixos-rpi5"; connectivity to the
    # platform is by its node name, so the client's own hostname is cosmetic here.
    networking.hostName = "monitoring-client";

    users.users.backup-user = {
      isNormalUser = true;
      home = "/home/backup-user";
    };

    # Add a restic backup on top of the real config so the restic check has something to
    # report. Repo/backend secrets are provisioned as encrypted creds in the boot oneshot.
    common.restic.backups.test = resticLib.rest {
      user = "backup-user";
      credentialDirectory = "/etc/credentials/restic/test";
      url = "http://monitoring-platform:8000";
      repository = "test";
      paths = [ "/home/backup-user/test" ];
      prune.opts = [ "--keep-last 2" ];
    };

    # Mock the upgrade so the real, enabled nixos-upgrade.timer succeeds when the clock
    # wakes it and records its last-success marker via the module's OnSuccess hook.
    system.build.nixos-rebuild = lib.mkForce fakeNixosRebuild;
    systemd.services.nixos-upgrade.path = lib.mkBefore [ fakeNix ];
    # Test-only safety: a "successful" mocked upgrade must never reboot mid-test (it
    # changes no system, so it wouldn't anyway, but pin both reboot paths off to be sure).
    system.autoUpgrade.allowReboot = lib.mkForce false;
    common.autoUpgrade.rebootOnChange = lib.mkForce false;

    # Warping the clock past midnight would otherwise wake the Persistent nix-gc.timer,
    # and its catch-up GC starves the monitoring run under slow TCG emulation.
    nix.gc.automatic = lib.mkForce false;

    # Keep the Pi's real 85% disk-space threshold satisfied by giving the VM root fs
    # headroom -- avoids overriding the monitoring config just to make the check pass.
    virtualisation.diskSize = 8192;

    # Fabricate the deployed lock the report reads (default flakeLock.path). A VM test
    # node has no /etc/nixos deployment flake, so without this the report would show
    # "not readable". No original.ref -- mirrors the real Pi (github input, no pinned
    # branch), which exercises the no-branch rendering of the common line.
    environment.etc."nixos/flake.lock".text = builtins.toJSON {
      nodes.common = {
        locked = {
          type = "github";
          owner = "sashee";
          repo = "nixos-test";
          rev = "cafe1234cafe1234cafe1234cafe1234cafe1234";
          narHash = "sha256-TESTHASH";
          lastModified = 1700000000;
        };
        original = {
          type = "github";
          owner = "sashee";
          repo = "nixos-test";
        };
      };
    };

    # All secrets are systemd-creds-encrypted blobs (LoadCredentialEncrypted); provision
    # them at boot runtime (the host key isn't set up during activation), before the
    # monitoring and restic services run. The payload/home dir need no encryption.
    systemd.services.test-monitoring-credential = {
      wantedBy = [ "multi-user.target" ];
      before = [ "common-monitoring.service" "restic-backups-test.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        install -d -m 0700 /etc/credentials/monitoring /etc/credentials/restic/test
        install -d -m 0755 -o backup-user -g users /home/backup-user/test

        printf '%s' 'http://monitoring-platform:8080/health' | ${pkgs.systemd}/bin/systemd-creds encrypt --name=healthchecks-url - /etc/credentials/monitoring/healthchecks-url
        printf '%s' 'repo-secret'    | ${pkgs.systemd}/bin/systemd-creds encrypt --name=repository-password - /etc/credentials/restic/test/repository-password
        printf '%s' 'test-user'      | ${pkgs.systemd}/bin/systemd-creds encrypt --name=backend-username - /etc/credentials/restic/test/backend-username
        printf '%s' 'backend-secret' | ${pkgs.systemd}/bin/systemd-creds encrypt --name=backend-password - /etc/credentials/restic/test/backend-password
        printf '%s\n' 'rpi payload' > /home/backup-user/test/payload.txt

        chmod 0600 \
          /etc/credentials/monitoring/healthchecks-url \
          /etc/credentials/restic/test/repository-password \
          /etc/credentials/restic/test/backend-username \
          /etc/credentials/restic/test/backend-password
        chown backup-user:users /home/backup-user/test/payload.txt
      '';
    };

    system.stateVersion = stateVersion;
  };

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

    system.stateVersion = stateVersion;
  };

  testScript = ''
    # This rpi test driver derives each machine's symbol from its hostname (monitoring-*),
    # not the node attr, so bind by substring rather than relying on `client`/`platform`.
    client = next(m for m in machines if "client" in m.name)
    platform = next(m for m in machines if "platform" in m.name)

    start_all()

    for node in machines:
        node.wait_for_unit("multi-user.target")

    platform.wait_for_unit("restic-rest-auth.socket")
    platform.wait_for_unit("monitoring-platform.service")
    platform.wait_for_open_port(8000)
    platform.wait_for_open_port(8080)

    # --- config-shape: the real Pi config wires monitoring + restic with encrypted creds ---
    client.succeed("systemctl show common-monitoring.timer -p TimersCalendar --value | grep -F '*-*-* *:00/30:00'")
    client.succeed("systemctl show common-monitoring.timer -p Persistent --value | grep -F no")
    client.succeed("systemctl is-active --quiet common-monitoring.timer")
    client.succeed("systemctl cat common-monitoring.service | grep -F 'LoadCredentialEncrypted=healthchecks-url:/etc/credentials/monitoring/healthchecks-url'")
    client.fail("systemctl cat common-monitoring.service | grep -F 'http://monitoring-platform:8080/health'")
    client.succeed("systemctl cat restic-backups-test.service | grep -F 'LoadCredentialEncrypted=repository-password:/etc/credentials/restic/test/repository-password'")
    client.succeed("systemctl show restic-backups-test.timer -p Persistent --value | grep -F yes")

    def quiesce_monitoring():
        # Pause the timer and drain any in-flight run before touching the platform log, so a
        # reset can't straddle a run (its /start pre-reset, its body post-reset) and so the next
        # clock warp can't spawn systemd's immediate catch-up run: a *running* OnCalendar timer
        # fires once right away on a forward jump, on top of the next-boundary run -- two runs
        # per warp, which corrupted the exact-events asserts under slow (KVM-less) emulation.
        client.succeed("systemctl stop common-monitoring.timer")
        # oneshot: while running it is "activating" (is-active is unreliable); wait for a settled state.
        client.wait_until_succeeds(
            "systemctl show common-monitoring.service -p ActiveState --value | grep -qxE 'inactive|failed'"
        )

    def arm_monitoring():
        # Start the timer only AFTER the clock warp. Arming a timer whose OnCalendar already elapsed
        # fires one run immediately; since we landed clear of :00/:30, the next scheduled boundary is
        # ~15 min out (never reached in a phase), so exactly that one run fires.
        client.succeed("systemctl start common-monitoring.timer")

    def reset_platform():
        quiesce_monitoring()
        platform.succeed("rm -f /var/lib/monitoring-platform/events.log /var/lib/monitoring-platform/bodies.log")

    def assert_events(expected):
        events = platform.succeed("cat /var/lib/monitoring-platform/events.log").strip().splitlines()
        assert events == expected, f"unexpected events: {events}"

    # Advance the client ~one day forward, landing clear of any :00/:30 boundary. The Persistent
    # daily timers (restic 1h, upgrade 2h randomized-delay) are overdue after the midnight
    # crossing and, since 05:29 is past their delay windows, catch up and fire promptly. But
    # common-monitoring.timer is now OnCalendar=*:0/30 with Persistent=no: a non-persistent
    # calendar timer, if left running across the jump, ALSO fires an immediate catch-up run on top
    # of the boundary run. So we pause it across every warp (quiesce_monitoring) and arm it just
    # after (arm_monitoring), making exactly one run fire per cycle -- keeping the asserts valid.
    def next_day():
        client.succeed("date -s \"$(date -d 'tomorrow 05:15:00')\"")
        arm_monitoring()

    upgrade_marker = "/var/lib/common-monitoring/nixos-upgrade.service.last-success"
    restic_marker = "/var/lib/common-monitoring/restic-backups-test.service.last-success"

    # Warm up: one day forward wakes the daily timers on their own. The mocked upgrade
    # succeeds and the real restic backup to the REST server succeeds, each recording its
    # last-success marker via the module's OnSuccess. No unit is ever started by hand.
    # Reset first so the terminal-ping wait below tracks the warm-up run's own posts, not
    # any earlier (e.g. boot-time) monitoring run's leftovers.
    reset_platform()
    next_day()
    client.wait_until_succeeds(f"test -r {upgrade_marker}", timeout=600)
    client.wait_until_succeeds(f"test -r {restic_marker}", timeout=600)
    # Let the warm-up monitoring run (also fired by the jump) finish so its POSTs can't
    # leak into the next run's log after we reset it. `! systemctl is-active` is unreliable
    # here: common-monitoring.service is Type=oneshot, so while it runs it is in state
    # "activating" (is-active returns non-zero) and the guard would pass mid-run. Instead
    # wait for the run's terminal ping -- its final POST is /health on success or /health/fail
    # if it lost the race with the marker writes -- after which it will not POST again, so the
    # reset below can't be straddled.
    platform.wait_until_succeeds("grep -Eq '^POST /health(/fail)?$' /var/lib/monitoring-platform/events.log", timeout=600)

    # OK run: another day forward fires common-monitoring.timer with both markers fresh
    # (<14d). smart stays [SKIP] (the Pi's real setting); everything else is [OK].
    reset_platform()
    next_day()
    platform.wait_until_succeeds("grep -Fxq 'POST /health' /var/lib/monitoring-platform/events.log", timeout=600)
    assert_events(["POST /health/start", "POST /health/log", "POST /health"])
    platform.succeed("grep -F '[SKIP] smart: disabled' /var/lib/monitoring-platform/bodies.log")
    platform.succeed("grep -F '[OK] restic test: restic-backups-test.service last succeeded' /var/lib/monitoring-platform/bodies.log")
    platform.succeed("grep -F '[OK] auto-upgrade: nixos-upgrade.service last succeeded' /var/lib/monitoring-platform/bodies.log")
    platform.succeed("grep -F '[OK] disk-space:' /var/lib/monitoring-platform/bodies.log")
    platform.succeed("grep -F '[OK] generations:' /var/lib/monitoring-platform/bodies.log")
    platform.succeed("grep -F 'status=ok' /var/lib/monitoring-platform/bodies.log")
    platform.fail("grep -F 'status=failed' /var/lib/monitoring-platform/bodies.log")
    # Informational lines rendered from the fabricated flake.lock: kernel, boot time, and
    # the common source (repo + rev + lastModified). No original.ref -> no branch=, and
    # narHash is intentionally dropped from the report.
    platform.succeed("grep -F '[INFO] kernel:' /var/lib/monitoring-platform/bodies.log")
    platform.succeed(r"grep -E '\[INFO\] booted: [0-9]{4}-[0-9]{2}-[0-9]{2}T' /var/lib/monitoring-platform/bodies.log")
    platform.succeed("grep -F '[INFO] common: repo=https://github.com/sashee/nixos-test rev=cafe1234cafe1234cafe1234cafe1234cafe1234 lastModified=2023-11-14T22:13:20Z' /var/lib/monitoring-platform/bodies.log")
    platform.fail("grep -F 'branch=' /var/lib/monitoring-platform/bodies.log")
    platform.fail("grep -F 'narHash' /var/lib/monitoring-platform/bodies.log")

    # FAIL run: break both success sources (mock upgrade now fails; REST backend down),
    # then jump 15 days so both markers age past maxAge (14d) with no new success recorded.
    # Land clear of :00/:30 (same reason as next_day) so arming fires exactly one run;
    # 15 days minus 15 s is still > 14d, so both markers read as stale.
    client.succeed("printf '%s' fail > /run/upgrade-status")
    platform.succeed("systemctl stop restic-rest-auth.socket restic-rest-auth.service")
    reset_platform()
    client.succeed("date -s \"$(date -d '+15 days' +%Y-%m-%d) 05:15:00\"")
    arm_monitoring()
    platform.wait_until_succeeds("grep -Fxq 'POST /health/fail' /var/lib/monitoring-platform/events.log", timeout=600)
    assert_events(["POST /health/start", "POST /health/log", "POST /health/fail"])
    platform.succeed("grep -F '[FAIL] auto-upgrade: nixos-upgrade.service last succeeded' /var/lib/monitoring-platform/bodies.log | grep -F 'older than 14d'")
    platform.succeed("grep -F '[FAIL] restic test: restic-backups-test.service last succeeded' /var/lib/monitoring-platform/bodies.log | grep -F 'older than 14d'")
    platform.succeed("grep -F 'status=failed' /var/lib/monitoring-platform/bodies.log")
  '';
}
