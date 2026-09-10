{ nixpkgs, pkgs, stateVersion, machineModule, keptAfterGc }:

# Behavioral test of GC retention, modelling real daily use. Each "day" it creates a
# system generation, advances the clock one day, and runs a GC. Over 20 days the host's
# real gc policy converges:
#   - laptop (--delete-older-than 14d): GC prunes one generation per day as it ages out,
#     leaving ~14 days of history (the boundary generation just past the cutoff is kept as
#     the rollback base)                                              -> keptAfterGc = 14
#   - rpi (--delete-old): only the current generation                 -> keptAfterGc = 1
# Uses the real per-host config, so changing a host's gc policy makes its variant fail.
#
# Drives nix-gc.service directly rather than warping the clock onto a timer slot. The GC
# schedule is no longer a daily calendar: spec/features/gc.md moved it to "after boot" plus
# a weekly backstop, so a one-day jump crosses a firing only one day in seven. Retention is
# a property of the gc *options*, not of what triggers them, so triggering by hand keeps
# this test measuring the thing it is named after -- and `systemctl start` on a oneshot is
# synchronous, which removes the staging/GC race the timer version had to dance around.
nixpkgs.lib.nixos.runTest {
  name = "nix-gc-retention";
  hostPkgs = pkgs;
  globalTimeout = 1800;

  nodes.machine = { lib, config, ... }: {
    imports = [ machineModule ];

    networking.hostName = "nix-gc-retention";
    # Isolate GC behavior: keep the host's gc settings, but stop the (network-less,
    # always-failing in the sandbox) auto-upgrade from adding noise/new generations.
    # This also leaves nix-gc's upgrade guard permanently satisfied -- with no
    # nixos-upgrade.service on the host, it reads idle and never skips.
    common.autoUpgrade.enable = lib.mkForce false;

    # This test starts nix-gc ~20 times within seconds; in reality it runs weekly. Lift
    # systemd's start rate limit so the rapid re-triggers don't trip 'start-limit-hit'.
    # Does not change what the GC does.
    systemd.services.nix-gc.startLimitIntervalSec = lib.mkForce 0;

    # Bound the store-sweep phase. The VM 9p-mounts the whole host /nix/store, so a
    # full collection scales with the developer's store size and can exceed the
    # timeout on large stores. Appending --max-freed caps the sweep to ~one path;
    # the host's real gc options (config.nix.gc.options) still run first and prune
    # generations in full, so retention counts are unaffected -- only the (here
    # irrelevant) bulk deletion is short-circuited.
    systemd.services.nix-gc.script =
      lib.mkForce "exec ${config.nix.package.out}/bin/nix-collect-garbage ${config.nix.gc.options} --max-freed 1";

    system.stateVersion = stateVersion;
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    def generation_count():
        return machine.succeed("find /nix/var/nix/profiles -maxdepth 1 -name 'system-*-link' | wc -l").strip()

    def add_generation(i):
        # A real generation via the same `nix-env --set` mechanism nixos-rebuild uses;
        # a distinct in-VM store path so --set makes a new generation each time.
        path = machine.succeed(f"mkdir -p /tmp/gen{i} && echo {i} > /tmp/gen{i}/marker && nix-store --add /tmp/gen{i}").strip()
        machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {path}")

    def run_gc(timeout=120):
        machine.succeed("systemctl reset-failed nix-gc.service || true")
        machine.succeed("systemctl start nix-gc.service", timeout=timeout)
        machine.succeed("systemctl show nix-gc.service -p Result --value | grep -qx success")
        # The guard must not have skipped: a skipped run is indistinguishable from a
        # successful one by Result alone, and would silently prune nothing -- turning every
        # retention assertion below into a no-op that still passes.
        machine.fail("journalctl -u nix-gc.service --no-pager | grep -F 'skipping this run'")

    assert generation_count() == "0", f"unexpected baseline: {generation_count()}"

    # Take the schedule out of play entirely: the post-boot trigger and the Persistent
    # weekly slot would both fire on their own once the clock starts jumping days.
    machine.succeed("systemctl stop nix-gc.timer")
    machine.wait_until_succeeds("systemctl show nix-gc.service -p ActiveState --value | grep -Fqx inactive")

    # The VM's store image ships with many paths unreferenced by the runtime closure
    # (build-time deps). Drain that bulk garbage once, with a generous timeout, before
    # the day loop: under TCG this initial sweep alone can exceed the per-day timeout,
    # which is sized for the incremental one-generation-aged-out runs below.
    run_gc(timeout=900)

    # 20 days of use: create a generation, advance one day, collect.
    for i in range(1, 21):
        add_generation(i)
        machine.succeed("date -s '+1 day'")
        run_gc()

    assert generation_count() == "${toString keptAfterGc}", f"expected ${toString keptAfterGc} generation(s), got {generation_count()}"

    # Whatever the policy, the current generation must always survive.
    machine.succeed("nix-env -p /nix/var/nix/profiles/system --list-generations | grep -F '(current)'")
  '';
}
