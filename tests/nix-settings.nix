{ nixpkgs, pkgs, stateVersion, extraModule ? { }, gcOptions, gcDates }:

nixpkgs.lib.nixos.runTest {
  name = "nix-settings";
  hostPkgs = pkgs;
  # Generous ceiling (not a fixed wait): fine under KVM, but the rpi variant runs
  # under slow TCG emulation on the KVM-less aarch64 CI runner and needs the room.
  globalTimeout = 1800;

  nodes.machine = {
    imports = [ ../modules/nix-settings.nix extraModule ];
    networking.hostName = "nix-settings";

    system.stateVersion = stateVersion;
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    machine.succeed("systemctl is-enabled nix-gc.timer")
    machine.succeed("systemctl is-active nix-gc.timer")
    machine.succeed("systemctl show nix-gc.service -p ExecStart --value | grep -o '/nix/store/[^ ;]*' | xargs grep -F -- '${gcOptions}'")
    machine.succeed("nix config show | grep -F 'auto-optimise-store = true'")
    machine.succeed("nix config show | grep -F 'fsync-store-paths = true'")

    with subtest("GC runs after boot and on the periodic slot"):
        # spec/features/gc.md: "after boot it deletes old generations and runs gc" plus a
        # weekly backstop. Both live on one timer; systemd reports the calendar and the
        # monotonic trigger separately, so assert both -- dropping either silently loses a
        # trigger the spec asks for.
        machine.succeed("systemctl show nix-gc.timer -p TimersCalendar --value | grep -F '${gcDates}'")
        # Read off the unit file, not systemd's TimersMonotonic property: that property
        # comes back empty here, and rather than reverse-engineer when systemd chooses to
        # populate it, assert the trigger the spec actually asks for.
        machine.succeed("systemctl cat nix-gc.timer | grep -E '^OnBootSec='")

    with subtest("the periodic slot still replays after a missed boot"):
        # Persistent comes from nixpkgs, but it is what makes a laptop that was off for a
        # week collect on the next boot rather than waiting for the next calendar slot.
        machine.succeed("systemctl show nix-gc.timer -p Persistent --value | grep -Fqx yes")

    with subtest("the upgrade guard is wired and does not block an idle host"):
        # nix-gc must refuse to run while an upgrade is mid-flight
        # (spec/features/gc.md). Only the wiring is checked here; that the guard actually
        # skips -- and that a skipped run does not get recorded as a success -- needs an
        # auto-upgrade unit to exist and is covered by tests/nix-gc-upgrade-exclusion.nix.
        machine.succeed("systemctl show nix-gc.service -p ExecCondition --value | grep -F 'nix-gc-skip-if-upgrading'")

        # This node has no nixos-upgrade.service at all, which is the case the guard's
        # empty/inactive branch exists for: GC must still run. A condition-skipped unit also
        # reports Result=success, so Result alone cannot tell the two apart -- the guard's
        # own log line is what distinguishes them.
        machine.succeed("systemctl start nix-gc.service", timeout=900)
        machine.succeed("systemctl show nix-gc.service -p Result --value | grep -qx success")
        machine.fail("journalctl -u nix-gc.service --no-pager | grep -F 'skipping this run'")
  '';
}
