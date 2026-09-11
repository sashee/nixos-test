{ nixpkgs, pkgs, stateVersion, machineModule, globalTimeout ? 900 }:

# spec/features/gc.md: "nix build directories are cleaned up automatically".
#
# Nix removes a build directory when a build ends normally, but not when the process is
# SIGKILLed -- so an OOM-killed or power-cut build leaks its whole tree. On the Pi one
# OOM-killed kernel build left 1.7 GB behind, on a 29 GB SD where a full disk has previously
# corrupted the nix database. `nix-collect-garbage` never touches these (they are not store
# paths), so it is easy to assume nothing reclaims them.
#
# It does: nixpkgs ships `d /nix/var/nix/builds 0755 <daemonUser> <daemonGroup> 7d -`
# (nixos/modules/services/system/nix-daemon.nix) and systemd-tmpfiles-clean.timer applies
# that age daily. This test asserts the deployed hosts actually have that property, which is
# worth pinning for two reasons: an ageless rule of our own for the same path silently wins
# the duplicate-line conflict and disables it (we shipped exactly that bug), and a future
# nixpkgs could drop the rule.
#
# Behavioural on purpose. The obvious cheap version --
# `systemd-tmpfiles --cat-config | grep 7d` -- would NOT have caught the shadowing bug:
# --cat-config prints every matching line including the ignored one, so the grep passes while
# the rule is dead. Only running the cleanup distinguishes them.
#
# Two further deliberate choices, without which this would go green while proving nothing:
#
#   * it asserts the orphan EXISTS after the kill, before advancing the clock. Otherwise a
#     future nix that cleaned up on SIGKILL would satisfy the assertion below without the
#     cleanup under test ever running. Not hypothetical: the first draft used a bare
#     `sleep 600`, which a raw derivation cannot resolve (no PATH, and sleep is not a bash
#     builtin), so the build failed instantly, nix tidied up correctly, and nothing was
#     orphaned -- this assertion is what caught it.
#
#   * it plants a *fresh* control directory alongside the orphan and asserts that one
#     SURVIVES. That is what makes the removal attributable to the age rule rather than to
#     something clearing the directory wholesale -- and it pins the age semantics, not just
#     the deletion.
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
      # `sleep` by absolute path -- see the note about bash builtins above.
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

    # The (real, enabled) upgrade would fail in a VM, and the clock jump below would wake its
    # Persistent timer; this test is about the build directory, not the upgrade.
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

    # Both would fire on the clock jump below and collect underneath the assertions. Each has
    # its own tests.
    machine.succeed("systemctl stop nix-gc.timer systemd-tmpfiles-clean.timer")

    # The build directory and its configured age, read from the merged tmpfiles config rather
    # than hardcoded -- the spec deliberately does not name either.
    #
    # Takes the last matching line, which is nixpkgs' own. Note systemd honours the *first*
    # line for a duplicated path, which is precisely the shadowing hazard this test exists to
    # catch -- so what is read here is only used to locate the directory and size the clock
    # jump. The assertions below, not this line, are what establish the behaviour: with a
    # shadowing rule present this still reports 7d while the effective rule has no age at
    # all, and the test fails on the orphan surviving (verified by reintroducing the bug).
    rule = machine.succeed(
        "systemd-tmpfiles --cat-config | awk '$1 == \"d\" && $2 ~ /nix\\/var\\/nix\\/builds/ { line = $0 } END { print line }'"
    ).split()
    assert len(rule) >= 6, f"no aged rule for the nix build directory: {rule}"
    root, age = rule[1], rule[5]
    print(f"build directory {root}, cleaned at age {age}")
    assert age.endswith("d"), f"expected a day-granularity age, got {age!r}"
    age_days = int(age[:-1])

    with subtest("a SIGKILLed build leaves its directory behind"):
        machine.succeed("systemd-run --unit=leaky --collect nix build --impure --file ${leaky} --no-link")

        # Discovered in one shell command rather than a Python helper returning Optionals:
        # the driver type-checks this script, and indexing an Optional[str] is a mypy error.
        probe = f"find {root} -maxdepth 1 -mindepth 1 -type d -name 'nix-*' | head -1"
        machine.wait_until_succeeds(f"{probe} | grep -q .", timeout=180)
        builddir = machine.succeed(probe).strip()
        # Ties the two halves together: the directory the rule ages out is the directory nix
        # actually builds in.
        assert builddir.startswith(root), f"{builddir} is not under {root}"
        print(f"orphan-to-be: {builddir}")

        machine.succeed("systemctl kill -s KILL leaky.service")
        machine.wait_until_succeeds(
            "systemctl show leaky.service -p ActiveState --value | grep -Fqvx activating"
        )

        # The precondition: nix really does leave the tree behind on SIGKILL.
        machine.succeed(f"test -d {builddir}")

    with subtest("the orphan ages out, and a fresh neighbour does not"):
        # Jumping the clock rather than waiting: systemd-tmpfiles takes the newest of
        # atime/mtime/ctime, and ctime cannot be backdated with touch (which is how an
        # earlier probe of this fooled itself). Moving `now` forward instead leaves all three
        # genuinely older than the age.
        machine.succeed(f"date -s '+{age_days + 1} days'")

        # Created *after* the jump, so it is younger than the age and must be kept. Its
        # survival is what proves the age is being honoured rather than the directory being
        # emptied wholesale.
        control = f"{root}/nix-fresh-control"
        machine.succeed(f"mkdir -p {control} && touch {control}/marker")

        machine.succeed("systemctl start systemd-tmpfiles-clean.service")
        machine.succeed("systemctl show systemd-tmpfiles-clean.service -p Result --value | grep -qx success")

        machine.fail(f"test -e {builddir}")
        machine.succeed(f"test -e {control}/marker")

    with subtest("the build directory itself is left in place"):
        # The rule ages out the *contents*; the directory must remain, or the next build has
        # nowhere to go.
        machine.succeed(f"test -d {root}")
        machine.succeed(f"touch {root}/.writable && rm {root}/.writable")
  '';
}
