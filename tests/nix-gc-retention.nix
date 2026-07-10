{ nixpkgs, pkgs, stateVersion, machineModule, keptAfterGc }:

# Behavioral test of GC retention, modelling real daily use. Each "day" it creates a
# system generation, then advances the clock one day so the host's Persistent
# nix-gc.timer fires, and waits for that GC run to finish before the next day. Over
# 20 days the host's real gc policy converges:
#   - laptop (--delete-older-than 14d): daily GC prunes one generation per day as it
#     ages out, leaving ~14 days of history (the boundary generation just past the
#     cutoff is kept as the rollback base)                            -> keptAfterGc = 14
#   - rpi (--delete-old): only the current generation                 -> keptAfterGc = 1
# Uses the real per-host config, so changing a host's gc policy makes its variant fail.
# Creating the generation *before* the clock jump, and only proceeding once the GC has
# completed, keeps the GC from ever running concurrently with `nix-env --set` -- the
# staging/GC race that otherwise makes this flaky under slow TCG emulation.
nixpkgs.lib.nixos.runTest {
  name = "nix-gc-retention";
  hostPkgs = pkgs;
  globalTimeout = 1800;

  nodes.machine = { lib, config, ... }: {
    imports = [ machineModule ];

    networking.hostName = "nix-gc-retention";
    # Isolate GC behavior: keep the host's gc settings, but stop the (network-less,
    # always-failing in the sandbox) auto-upgrade from adding noise/new generations.
    common.autoUpgrade.enable = lib.mkForce false;

    # This test fires the (daily) nix-gc.timer ~20 times within seconds; in reality it
    # runs once a day. Lift systemd's start rate limit so the rapid re-triggers don't
    # trip 'start-limit-hit'. Does not change what the GC does.
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

    def gc_invocation():
        return machine.succeed("systemctl show nix-gc.service -p InvocationID --value").strip()

    def add_generation(i):
        # A real generation via the same `nix-env --set` mechanism nixos-rebuild uses;
        # a distinct in-VM store path so --set makes a new generation each time.
        path = machine.succeed(f"mkdir -p /tmp/gen{i} && echo {i} > /tmp/gen{i}/marker && nix-store --add /tmp/gen{i}").strip()
        machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {path}")

    assert generation_count() == "0", f"unexpected baseline: {generation_count()}"

    # Let any boot-time (Persistent catch-up) GC run settle before we start.
    machine.wait_until_succeeds("systemctl show nix-gc.service -p ActiveState --value | grep -Fqx inactive")

    # The VM's store image ships with many paths unreferenced by the runtime closure
    # (build-time deps). Drain that bulk garbage once, with a generous timeout, before
    # the day loop: under TCG this initial sweep alone can exceed the per-day timeout,
    # which is sized for the incremental one-generation-aged-out runs below.
    machine.succeed("systemctl start nix-gc.service", timeout=900)

    # 20 days of use: create a generation, advance one day so nix-gc.timer fires, then
    # wait for that GC run to complete before the next day. GC never overlaps staging.
    for i in range(1, 21):
        add_generation(i)
        prev = gc_invocation()
        machine.succeed("date -s '+1 day'")   # crosses 03:15 -> wakes the Persistent nix-gc.timer
        machine.wait_until_succeeds(
            f'id=$(systemctl show nix-gc.service -p InvocationID --value); '
            f'[ "$id" != "{prev}" ] && '
            f'[ "$(systemctl show nix-gc.service -p ActiveState --value)" = inactive ] && '
            f'[ "$(systemctl show nix-gc.service -p Result --value)" = success ]',
            timeout=120,
        )

    assert generation_count() == "${toString keptAfterGc}", f"expected ${toString keptAfterGc} generation(s), got {generation_count()}"

    # Whatever the policy, the current generation must always survive.
    machine.succeed("nix-env -p /nix/var/nix/profiles/system --list-generations | grep -F '(current)'")
  '';
}
