{ nixpkgs, pkgs, stateVersion, machineModule, globalTimeout ? 900 }:

# spec/features/gc.md, Auto build cleanup: the Nix build directory is cleaned after boot.
#
# Reproduces the real failure rather than asserting on config. Nix removes a build directory
# when a build ends normally, but not when the process is SIGKILLed -- so an OOM-killed or
# power-cut build leaves its whole tree behind, on a filesystem nothing else reclaims:
# nix-collect-garbage ignores it (build dirs are not store paths), which is how the Pi ended
# up holding 1.7 GB from a single OOM-killed kernel build, still there hours and several GCs
# later, on a 29 GB SD where a full disk has previously corrupted the nix database.
#
# Runs against the real per-host config, so a host that stopped importing the setting -- or
# force-overrode systemd.tmpfiles.rules -- fails its own variant.
#
# Three things this test does deliberately, because without them it would go green while
# proving nothing:
#
#   * it asserts the orphan EXISTS after the kill, before rebooting. Otherwise a future nix
#     that cleaned up on SIGKILL would satisfy the post-reboot assertion without the cleanup
#     under test ever running. This is not hypothetical: the first draft used a bare
#     `sleep 600`, which a raw derivation cannot resolve (no PATH, and sleep is not a bash
#     builtin), so the build failed instantly, nix tidied up correctly, and nothing was ever
#     orphaned -- this assertion is what caught it.
#
#   * it plants a control file next to the build directory -- outside it, so the cleanup must
#     not touch it -- and asserts that one SURVIVES the reboot. A VM test's /nix/store upper
#     layer is a tmpfs, so "it vanished after a reboot" is exactly what a non-persistent path
#     looks like; the control is what makes the orphan's disappearance attributable to the
#     cleanup rather than to the filesystem. (/nix/var is on the guest's persistent disk,
#     unlike /nix/store's overlay -- the same persistence tests/connectivity-watchdog.nix
#     relies on for /var/lib.)
#
#   * it learns the directory from the cleanup's own configuration and then confirms nix
#     really builds there, instead of hardcoding a path on both sides. A rule aimed at the
#     wrong directory would pass a hardcoded-path test while reclaiming nothing.
let
  # A derivation the GUEST evaluates, wrapping its builder paths in `builtins.storePath` so
  # they carry real Nix string context. That context is what makes nix record bash and
  # coreutils as inputSrcs and bind-mount them, so this runs under the host's real
  # `sandbox = true` rather than forcing sandboxing off.
  #
  # Two shapes that do NOT work, both tried:
  #   * naming the paths as plain strings -- no context, no inputSrcs, and the sandbox does
  #     not bind-mount them: "executing .../bin/bash: No such file or directory".
  #   * building the derivation on the host and passing `leaky.drvPath` to
  #     virtualisation.additionalPaths -- that makes the closure depend on the derivation's
  #     *output*, so the host tries to realise a builder that sleeps for 600s and never
  #     writes $out. It shows up as the test driver failing to build, with `leaky-build.drv`
  #     in the host's build plan.
  #
  # storePath is impure, which is fine here: this is evaluated with `--impure --file`, not as
  # a flake. The paths are put in the guest's store by additionalPaths below.
  leaky = pkgs.writeText "leaky.nix" ''
    let
      bash = builtins.storePath "${pkgs.bash}";
      coreutils = builtins.storePath "${pkgs.coreutils}";
    in
    derivation {
      name = "leaky-build";
      system = "${pkgs.stdenv.hostPlatform.system}";
      builder = "''${bash}/bin/bash";
      # `sleep` by absolute path: a raw derivation gets no PATH and sleep is not a bash
      # builtin, so a bare `sleep 600` exits 127 -- the build then *fails* and nix tidies the
      # directory away, leaving nothing orphaned and this test measuring nothing. The
      # precondition assertion below is what caught that.
      args = [ "-c" "''${coreutils}/bin/sleep 600" ];
    }
  '';
in
nixpkgs.lib.nixos.runTest {
  name = "nix-build-dir-cleanup";
  hostPkgs = pkgs;
  inherit globalTimeout;

  nodes.machine = { lib, ... }: {
    imports = [ machineModule ];

    networking.hostName = "nix-build-dir-cleanup";

    # The (real, enabled) upgrade would fail in a VM and its Persistent catch-up could fire
    # across the reboot below; this test is about the build directory, not the upgrade.
    common.autoUpgrade.enable = lib.mkForce false;

    # The builder paths the guest's `builtins.storePath` resolves. Outputs, not a drvPath:
    # passing a drvPath here makes the closure require the derivation to be *built* on the
    # host, which for a 600s sleep that never writes $out means the test never starts.
    virtualisation.additionalPaths = [ pkgs.bash pkgs.coreutils ];

    # mkForce: substituters is a list option, so a plain [ ] merges with the host's value and
    # leaves cache.nixos.org in place -- ~5s of DNS failure per build in a network-less VM.
    nix.settings.substituters = lib.mkForce [ ];

    system.stateVersion = stateVersion;
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    # The post-boot GC would collect underneath the assertions; it has its own tests.
    machine.succeed("systemctl stop nix-gc.timer")

    # Every directory the boot cleanup clears, straight from the merged tmpfiles config. On
    # these hosts that is the nix build directory plus nixpkgs' own gcroots/tmp and
    # temproots, so which one nix actually builds in is discovered below rather than assumed.
    candidates = machine.succeed(
        "systemd-tmpfiles --cat-config | awk '/^R! \\/nix\\// { print $2 }'"
    ).split()
    assert candidates, "no boot-time cleanup is configured for anything under /nix"
    print(f"boot-cleaned paths: {candidates}")

    with subtest("a SIGKILLed build leaves its directory behind"):
        machine.succeed("systemd-run --unit=leaky --collect nix build --impure --file ${leaky} --no-link")

        # Discovered in one shell command rather than a Python helper returning Optionals:
        # the driver type-checks this script, and `root.rsplit(...)` on an Optional[str] is a
        # mypy error rather than a runtime one.
        probe = (
            "for c in " + " ".join(candidates) + "; do "
            "d=$(find \"$c\" -maxdepth 1 -mindepth 1 -type d -name 'nix-*' 2>/dev/null | head -1); "
            "[ -n \"$d\" ] && { echo \"$c $d\"; break; }; done"
        )
        machine.wait_until_succeeds(f"{probe} | grep -q .", timeout=180)
        found = machine.succeed(probe).split()
        # Ties the two halves together: the directory the rule clears is the directory nix
        # builds in.
        assert len(found) == 2, f"no build directory under any cleaned path: {candidates}"
        root, builddir = found
        print(f"nix builds in {root}, this build: {builddir}")

        machine.succeed("systemctl kill -s KILL leaky.service")
        machine.wait_until_succeeds(
            "systemctl show leaky.service -p ActiveState --value | grep -Fqvx activating"
        )

        # The precondition. If nix ever starts cleaning up on SIGKILL this fails loudly,
        # rather than the reboot assertion below passing for the wrong reason.
        machine.succeed(f"test -d {builddir}")

    with subtest("the orphan is gone after a reboot, and a neighbour is not"):
        control = root.rsplit("/", 1)[0] + "/leak-control"
        # Outside the cleaned directory, so the cleanup must leave it alone; its survival is
        # what proves the filesystem persisted and the orphan was actually removed.
        machine.succeed(f"touch {control}")

        machine.shutdown()
        machine.start()
        machine.wait_for_unit("multi-user.target")

        machine.succeed(f"test -e {control}")
        machine.fail(f"test -e {builddir}")

    with subtest("the build directory itself survives the cleanup"):
        # `R!` removes the directory itself, not just its contents, so the paired `d` rule is
        # what puts it back. Asserted as existence and writability rather than by building
        # again: a VM test's /nix/store upper layer is a tmpfs, so the .drv instantiated
        # before the reboot is gone afterwards while the (persistent) nix database still
        # references it -- `nix build` then fails with "opening file '...leaky-build.drv':
        # No such file or directory", which says nothing about the cleanup. That nix builds
        # in this directory is already established pre-reboot, above.
        machine.succeed(f"test -d {root}")
        machine.succeed(f"touch {root}/.writable && rm {root}/.writable")

    with subtest("the cleanup is ordered before anything can build"):
        # Transitive today (tmpfiles-setup is Before=sysinit.target, nix-daemon.socket is
        # After=sysinit.target) -- nothing declares it, so assert the outcome. Monotonic
        # timestamps are comparable within a boot.
        cleaned = int(machine.succeed(
            "systemctl show systemd-tmpfiles-setup.service -p InactiveEnterTimestampMonotonic --value"
        ).strip())
        daemon = int(machine.succeed(
            "systemctl show nix-daemon.socket -p ActiveEnterTimestampMonotonic --value"
        ).strip())
        assert cleaned > 0 and daemon > 0, f"timestamps unset: cleaned={cleaned} daemon={daemon}"
        assert cleaned < daemon, (
            f"tmpfiles finished at {cleaned} but nix-daemon.socket was already up at {daemon}: "
            "a build could start before the build directory is cleaned"
        )
  '';
}
