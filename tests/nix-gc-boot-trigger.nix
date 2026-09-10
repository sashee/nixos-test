{ nixpkgs, pkgs, stateVersion, globalTimeout ? 600 }:

# spec/features/gc.md: "after boot it deletes old generations and runs gc".
#
# tests/nix-settings.nix asserts the trigger is *configured* (OnBootSec= is in the timer
# unit), which is not the same as a collection actually happening -- and on a host that is
# off most of the time this is the trigger that does nearly all the work, since the weekly
# calendar slot is usually missed. So run it for real, with the delay turned down to
# something a test can wait for.
#
# The distinction that makes this test meaningful: a nix-gc.service that never ran and one
# that ran successfully both report Result=success, so Result proves nothing here. What
# separates them is the journal -- systemd logs "Starting Nix Garbage Collector..." only when
# the unit is actually triggered, and the guard logs "skipping this run" only when its
# ExecCondition declines.
nixpkgs.lib.nixos.runTest {
  name = "nix-gc-boot-trigger";
  hostPkgs = pkgs;
  inherit globalTimeout;

  nodes.machine = { ... }: {
    imports = [ ../modules/nix-settings.nix ];

    networking.hostName = "nix-gc-boot-trigger";

    # Short enough for a test to observe. On real hosts this is 15min, deliberately longer
    # than a VM test's guest runtime so the boot GC does not gatecrash unrelated tests --
    # which is exactly why the behaviour needs a test that opts into it.
    common.nixSettings.gcOnBootDelay = "5s";

    # The guest sees the host's whole /nix/store over 9p; an unbounded collect would scale
    # with the developer's store size. The trigger is what is under test, not the sweep.
    common.nixSettings.gcOptions = "--max-freed 1";

    system.stateVersion = stateVersion;
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    with subtest("the boot trigger collects without anything starting it by hand"):
        # Never touches nix-gc.service or its timer: if OnBootSec is dropped or the guard
        # wrongly declines on a host with no upgrade unit, this wait is what fails.
        machine.wait_until_succeeds(
            "journalctl -u nix-gc.service --no-pager | grep -F 'Starting Nix Garbage Collector'",
            timeout=180,
        )
        machine.wait_until_succeeds(
            "systemctl show nix-gc.service -p ActiveState --value | grep -Fqx inactive"
        )
        machine.succeed("systemctl show nix-gc.service -p Result --value | grep -qx success")

        # This node has no nixos-upgrade.service, which is the guard's idle case: it must let
        # the collection through rather than skip it.
        machine.fail("journalctl -u nix-gc.service --no-pager | grep -F 'skipping this run'")
  '';
}
