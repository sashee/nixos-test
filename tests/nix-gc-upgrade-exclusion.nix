{ nixpkgs, pkgs, stateVersion }:

# spec/features/gc.md: "it does not run if the nixos-upgrade script is running", and
# spec/features/auto-upgrade.md: the upgrade "run[s] the nix-gc first".
#
# Those two pull in opposite directions, and the interesting failures are both silent:
#
#   * the guard skipping the GC that the upgrade itself asked for. nix-gc's ExecCondition
#     refuses to run whenever nixos-upgrade is not idle, and a unit executing its
#     ExecStartPre is `activating` -- so a GC invoked from inside the prebuild would be
#     skipped by the upgrade's own guard, and the upgrade would build with no space
#     reclaimed. Pulling the GC in with Wants=/After= avoids that (the upgrade is still
#     `inactive` while its dependency runs); this test is what stops that wiring from
#     regressing to a `systemctl start` inside the script.
#
#   * a skipped GC being recorded as a successful one. Once a guard exists, "the unit
#     finished without failing" stops implying "a collection happened", so a last-success
#     marker hung off the wrong hook would report healthy GCs that never ran -- store
#     filling up, check staying green. modules/monitoring.nix records nix-gc's marker from
#     ExecStartPost, which cannot run unless ExecStart did; the subtest below is what
#     actually holds that property in place.
#
# The first failure is invisible in Result/ActiveState -- the guard's own log line is what
# distinguishes a skip from a run -- and the second is invisible in both, since the marker
# is the only thing that records a collection.
let
  fakeNixosRebuild = pkgs.writeShellScriptBin "nixos-rebuild" ''
    echo "fake nixos-rebuild: $*"
  '';
in
nixpkgs.lib.nixos.runTest {
  name = "nix-gc-upgrade-exclusion";
  hostPkgs = pkgs;
  globalTimeout = 900;

  nodes.machine = { lib, config, ... }: {
    imports = [
      ../modules/monitoring.nix
      ../modules/restic.nix
      ../modules/nix-settings.nix
      ../modules/auto-upgrade.nix
    ];

    networking.hostName = "nix-gc-upgrade-exclusion";

    common.autoUpgrade = {
      enable = true;
      flake = "/etc/nixos#testhost";
    };

    # The guest sees the host's whole /nix/store over 9p, so an unbounded collection sweeps
    # the developer's entire store (minutes, host-size-dependent -> flaky). This test only
    # needs GC runs to be distinguishable from skipped ones, so cap the sweep.
    common.nixSettings.gcOptions = "--max-freed 1";

    # Same collection as nixpkgs would run, plus an on-demand failure so the test can prove
    # a broken GC does not stop the upgrade. Keeps the real ExecCondition and ExecStartPost
    # (only `script` is replaced), which is what makes the marker assertions meaningful.
    systemd.services.nix-gc.script = lib.mkForce ''
      if [ -e /run/gc-should-fail ]; then
        echo "nix-gc: failing on purpose" >&2
        exit 1
      fi
      exec ${config.nix.package.out}/bin/nix-collect-garbage ${config.nix.gc.options}
    '';

    # This test is about the exclusion, not about what the upgrade builds. Replace the real
    # prebuild (lock update, eval, one-by-one loop -- covered by
    # tests/auto-upgrade-prebuild.nix) with a sleep whose length the test controls, so the
    # upgrade can be parked in `activating` while a GC is triggered against it.
    systemd.services.nixos-upgrade.preStart = lib.mkForce ''
      secs="$(${pkgs.coreutils}/bin/cat /run/prebuild-seconds 2>/dev/null || echo 1)"
      echo "fake prebuild: sleeping $secs"
      ${pkgs.coreutils}/bin/sleep "$secs"
    '';
    system.build.nixos-rebuild = lib.mkForce fakeNixosRebuild;

    common.monitoring = {
      enable = true;
      report.enable = false;
      smart.enable = false;
      restic.enable = false;
      diskSpace.enable = false;
      generations.enable = false;
      autoUpgrade.enable = false;
      nixGc.enable = true;
    };

    system.stateVersion = stateVersion;
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    # Drive everything by hand: the post-boot GC trigger would otherwise collect
    # underneath the assertions.
    machine.succeed("systemctl stop common-monitoring.timer nix-gc.timer nixos-upgrade.timer")
    machine.wait_until_succeeds("systemctl show nix-gc.service -p ActiveState --value | grep -Fqx inactive")

    marker = "/var/lib/common-monitoring/nix-gc.service.last-success"

    def marker_value():
        return machine.succeed(f"cat {marker}").strip()

    def gc_skipped_count():
        return int(machine.succeed(
            "journalctl -u nix-gc.service --no-pager | grep -c 'skipping this run' || true"
        ).strip())

    with subtest("the upgrade pulls in a GC, and the guard does not skip it"):
        machine.succeed("test ! -e " + marker)
        machine.succeed("echo 120 > /run/prebuild-seconds")
        machine.succeed("systemctl start --no-block nixos-upgrade.service")

        # After=nix-gc.service means the GC runs while nixos-upgrade is still merely queued
        # (measured: a unit waiting on an After= dependency reads `inactive`), so the guard
        # sees an idle upgrade and lets it through. The marker appearing is the proof it
        # really ran rather than being skipped.
        machine.wait_until_succeeds(f"test -r {marker}", timeout=300)
        assert gc_skipped_count() == 0, "the upgrade's own GC was skipped by the guard"
        after_upgrade_gc = marker_value()

    with subtest("a GC triggered while the upgrade runs is skipped"):
        machine.wait_until_succeeds(
            "systemctl show nixos-upgrade.service -p ActiveState --value | grep -Fqx activating"
        )
        # Starting a unit whose ExecCondition declines is not an error, so this must not
        # fail. What it must also not do is leave the unit *failed*: nix-gc is monitored,
        # and a skip is a deliberate no-op rather than a fault.
        machine.succeed("systemctl start nix-gc.service")
        result = machine.succeed("systemctl show nix-gc.service -p Result --value").strip()
        print(f"nix-gc Result after an ExecCondition skip: {result!r}")
        machine.fail("systemctl is-failed --quiet nix-gc.service")
        assert gc_skipped_count() >= 1, "GC ran during an upgrade instead of skipping"

    with subtest("the skipped run is NOT recorded as a successful GC"):
        # The regression this guards: OnSuccess fires for condition-skipped runs, so
        # recording the marker that way would advance it here and report a healthy GC.
        assert marker_value() == after_upgrade_gc, (
            "a skipped GC advanced the last-success marker; monitoring would report a "
            "collection that never happened"
        )

    with subtest("nix-gc records success via ExecStartPost, not OnSuccess"):
        machine.succeed("systemctl show nix-gc.service -p ExecStartPost --value | grep -F 'common-monitoring-record-success'")
        machine.fail("systemctl show nix-gc.service -p OnSuccess --value | grep -F 'common-monitoring-record'")

    with subtest("a GC the timer fires during an upgrade is skipped too"):
        # The realistic path, and the one that motivated the guard: a host that was off for
        # days boots, and systemd replays *both* missed Persistent slots -- the upgrade
        # catch-up and the GC -- so the GC lands inside the build loop with nobody having
        # typed anything. Simulated by ageing the timer's stamp file and re-arming it, which
        # is what a multi-day gap looks like to systemd.
        before_timer_skips = gc_skipped_count()
        machine.succeed("mkdir -p /var/lib/systemd/timers")
        machine.succeed("touch -d '2020-01-01 00:00:00' /var/lib/systemd/timers/stamp-nix-gc.timer")
        machine.succeed("systemctl restart nix-gc.timer")
        machine.wait_until_succeeds(
            "journalctl -u nix-gc.service --no-pager | "
            f"grep -c 'skipping this run' | grep -qvx {before_timer_skips}",
            timeout=120,
        )
        machine.succeed("systemctl stop nix-gc.timer")

    with subtest("the upgrade survives the skipped GCs"):
        # The whole point of skipping rather than letting the GC run: no pinning means a
        # concurrent collect would delete the loop's freshly built outputs and fail the
        # upgrade. So the upgrade must come out the other side *successful*, not merely
        # finished.
        machine.succeed("echo 1 > /run/prebuild-seconds")
        machine.wait_until_succeeds(
            "systemctl show nixos-upgrade.service -p ActiveState --value | grep -Fqx inactive",
            timeout=300,
        )
        machine.succeed("systemctl show nixos-upgrade.service -p Result --value | grep -qx success")

    with subtest("GC works again once the upgrade is done"):
        before = marker_value()
        # Back-to-back starts of a oneshot trip systemd's start rate limit.
        machine.succeed("systemctl reset-failed nix-gc.service || true")
        machine.succeed("systemctl start nix-gc.service")
        machine.wait_until_succeeds(f'test "$(cat {marker})" != "{before}"')

    with subtest("a failing GC does not block the upgrade"):
        # Wants=, not Requires=. This host has had a corrupted nix DB before, and "GC is
        # broken" must not also mean "no security updates" -- a one-word change in
        # modules/auto-upgrade.nix would silently turn the upgrade into collateral damage.
        machine.succeed("touch /run/gc-should-fail")
        machine.succeed("systemctl reset-failed nix-gc.service nixos-upgrade.service || true")
        before = marker_value()

        machine.succeed("systemctl start nixos-upgrade.service")
        machine.succeed("systemctl show nixos-upgrade.service -p Result --value | grep -qx success")
        machine.succeed("systemctl is-failed --quiet nix-gc.service")
        # A failed collection must not look like a successful one to monitoring either.
        assert marker_value() == before, "a failed GC advanced the last-success marker"
  '';
}
