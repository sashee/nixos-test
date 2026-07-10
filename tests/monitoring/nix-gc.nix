{ nixpkgs, pkgs, stateVersion }:

# Verifies the nix-gc monitoring check: FAIL when no successful GC is recorded within
# maxAge, OK right after a successful GC, FAIL again once that success ages past maxAge.
# Self-contained: report.enable = false, so the monitoring oneshot's own exit code and
# journal reflect the check result directly (no Healthchecks backend needed).
nixpkgs.lib.nixos.runTest {
  name = "monitoring-nix-gc";
  hostPkgs = pkgs;
  globalTimeout = 600;

  nodes.machine = { ... }: {
    imports = [ ../../modules/monitoring.nix ../../modules/restic.nix ];

    nix.gc.automatic = true;
    # nix-gc.service runs `nix-collect-garbage <options>`. In a VM test the guest
    # sees the host's whole /nix/store over 9p, so an unbounded collection sweeps
    # the entire host store (minutes, host-size-dependent -> flaky timeout). This
    # check only needs a GC to succeed once and record its marker, so cap the
    # work: stop after freeing a trivial amount. It still exits 0 and fires
    # OnSuccess, so all three subtests behave the same, just fast.
    nix.gc.options = "--max-freed 1";

    common.monitoring = {
      enable = true;
      report.enable = false;
      smart.enable = false;
      restic.enable = false;
      diskSpace.enable = false;
      generations.enable = false;
      autoUpgrade.enable = false;
      nixGc.enable = true;
      nixGc.maxAge = "3d";
    };

    system.stateVersion = stateVersion;
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    # Drive checks by hand; stop the timers so no catch-up GC or monitoring run races the
    # assertions (the clock jump below would otherwise wake the Persistent nix-gc.timer).
    machine.succeed("systemctl stop common-monitoring.timer nix-gc.timer")

    marker = "/var/lib/common-monitoring/nix-gc.service.last-success"

    def monitoring_log():
        return machine.succeed("journalctl -u common-monitoring.service -o cat --no-pager")

    with subtest("no successful GC recorded yet -> FAIL"):
        machine.succeed("test ! -e " + marker)
        machine.fail("systemctl start common-monitoring.service")
        assert "[FAIL] nix-gc:" in monitoring_log()

    with subtest("after a successful GC -> OK"):
        machine.succeed("systemctl start nix-gc.service")
        machine.wait_until_succeeds("test -r " + marker)
        machine.succeed("systemctl start common-monitoring.service")
        assert "[OK] nix-gc:" in monitoring_log()

    with subtest("stale success (older than maxAge) -> FAIL"):
        machine.succeed("date -s '+5 days'")
        machine.fail("systemctl start common-monitoring.service")
        journal = monitoring_log()
        assert "[FAIL] nix-gc:" in journal and "older than 3d" in journal, journal
  '';
}
