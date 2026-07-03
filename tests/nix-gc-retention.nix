{ nixpkgs, pkgs, stateVersion, machineModule, keptAfterGc }:

# Behavioral test of GC retention across the 14-day window. It stages 20 system
# generations, one per simulated day (advancing the clock with *relative* bumps so
# no hardcoded date is used and we stay above systemd's lower clock bound), then
# runs the host's automatic GC:
#   - laptop (--delete-older-than 14d): keeps the generations inside the 14-day
#     window plus the most recent one just past it (a rollback base) -> keptAfterGc = 15
#   - rpi (--delete-old): keeps only the current generation           -> keptAfterGc = 1
# Uses the real per-host config, so changing a host's gc policy makes its variant fail.
nixpkgs.lib.nixos.runTest {
  name = "nix-gc-retention";
  hostPkgs = pkgs;
  globalTimeout = 1800;

  nodes.machine = { lib, ... }: {
    imports = [ machineModule ];

    networking.hostName = "nix-gc-retention";
    # Isolate GC behavior: keep the host's gc settings, but stop the (network-less,
    # always-failing in the sandbox) auto-upgrade from adding noise/new generations.
    common.autoUpgrade.enable = lib.mkForce false;

    system.stateVersion = stateVersion;
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    def generation_count():
        return machine.succeed("find /nix/var/nix/profiles -maxdepth 1 -name 'system-*-link' | wc -l").strip()

    def add_generation(i):
        # A real generation via the same `nix-env --set` mechanism nixos-rebuild uses;
        # a distinct in-VM store path so --set makes a new generation each time. The
        # generation's timestamp is the current (faked) wall clock.
        path = machine.succeed(f"mkdir -p /tmp/gen{i} && echo {i} > /tmp/gen{i}/marker && nix-store --add /tmp/gen{i}").strip()
        machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {path}")

    assert generation_count() == "0", f"unexpected baseline: {generation_count()}"

    # Stage 20 generations, one per day. Relative bumps only (no hardcoded dates):
    # each generation's timestamp ends up one day apart.
    for i in range(1, 21):
        machine.succeed("date -s '+1 day'")
        add_generation(i)
    assert generation_count() == "20", f"expected 20 staged generations, got {generation_count()}"

    # Nudge a half-day so the 14-day cutoff lands mid-gap, not exactly on a
    # generation's timestamp (which would make the boundary result flaky).
    machine.succeed("date -s '+12 hours'")

    # Run the host's automatic GC, then check how many generations survive.
    machine.succeed("systemctl start nix-gc.service")
    machine.wait_until_succeeds("systemctl show nix-gc.service -p ActiveState --value | grep -Fqx inactive")
    machine.succeed("systemctl show nix-gc.service -p Result --value | grep -Fqx success")

    assert generation_count() == "${toString keptAfterGc}", f"expected ${toString keptAfterGc} generation(s) after GC, got {generation_count()}"

    # Whatever the policy, the current generation must always survive.
    machine.succeed("nix-env -p /nix/var/nix/profiles/system --list-generations | grep -F '(current)'")
  '';
}
