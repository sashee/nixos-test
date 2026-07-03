{ nixpkgs, pkgs, stateVersion, machineModule, keptAfterGc }:

# Behavioral test of GC retention: stage several system generations, run the host's
# automatic GC, and assert how many survive. Uses the real per-host config, so both
# the rpi (--delete-old -> keptAfterGc = 1) and the laptop (--delete-older-than 14d,
# which keeps all the freshly-staged gens -> keptAfterGc = 3) are exercised; a change
# to a host's gc policy makes its variant fail.
nixpkgs.lib.nixos.runTest {
  name = "nix-gc-retention";
  hostPkgs = pkgs;
  # rpi variant runs under slow TCG on the KVM-less aarch64 CI runner; give it room.
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

    def make_generations(indices):
        # Real generations via the same `nix-env --set` mechanism nixos-rebuild uses.
        # Each points at a distinct store path (created + imported in-VM) so --set
        # makes a new generation rather than deduplicating to one.
        for i in indices:
            path = machine.succeed(f"mkdir -p /tmp/gen{i} && echo {i} > /tmp/gen{i}/marker && nix-store --add /tmp/gen{i}").strip()
            machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {path}")

    # Test VMs register no system generations by default.
    assert generation_count() == "0", f"unexpected baseline: {generation_count()}"

    # Stage several generations, as repeated nixos-rebuild boot would.
    make_generations(range(1, 4))
    assert generation_count() == "3", f"expected 3 generations, got {generation_count()}"

    # Run the host's automatic GC, then check how many generations survive.
    machine.succeed("systemctl start nix-gc.service")
    machine.wait_until_succeeds("systemctl show nix-gc.service -p ActiveState --value | grep -Fqx inactive")
    machine.succeed("systemctl show nix-gc.service -p Result --value | grep -Fqx success")

    assert generation_count() == "${toString keptAfterGc}", f"expected ${toString keptAfterGc} generation(s) kept after GC, got {generation_count()}"
  '';
}
