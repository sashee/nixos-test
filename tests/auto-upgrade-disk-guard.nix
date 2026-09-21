{ nixpkgs, pkgs, stateVersion, globalTimeout ? 2400 }:

# The disk guard on the prebuild loop of modules/auto-upgrade.nix: a build that would exhaust
# the nix store filesystem must be killed while there is still room, not left to run into
# ENOSPC.
#
# Why this exists. On 2026-09-21 a nixpkgs bump landed the Pi on a nixos-26.05 rev for which
# aarch64 dotnet 9.0.20 had not been published, so `marksman` -- a markdown LSP that drags the
# whole .NET SDK in behind it -- was source-built instead of substituted. The upgrade ran 4h52m,
# filled the 29 GB SD to 100%, and died with "No space left on device" mid-VMR-bootstrap. The
# collateral is the point: 18 failed runs each of thingspeak, bms-monitoring and
# inverter-monitoring while the card thrashed, and both measurements.db and the nix database
# were being written at the instant the filesystem hit zero. A full store filesystem has
# corrupted this host's nix database before (see tests/nix-build-dir-cleanup.nix).
#
# Built on the tests/auto-upgrade-prebuild.nix harness -- a hand-made flake of raw `derivation`
# calls, driven through the real unit -- for the same reason given there: the subject is the
# loop, and a real NixOS closure would make this test about kernel compiles.
#
# Three things make it measure what it claims:
#
#   * `virtualisation.writableStoreUseTmpfs = false`. The default writable store in a test VM
#     is RAM-backed, so a build that filled it would OOM rather than run out of disk, and the
#     sizes below would be read off a tmpfs sized from memory. The Pi's store is on the SD
#     card; this test's must be on a disk too.
#
#   * a ballast file, not a small disk. Sizing the guest disk to leave a known amount
#     available would couple this test to the node's closure size. Writing ballast until
#     available space sits at a chosen figure is independent of both, and the write is
#     verified to land on the same filesystem `df /nix/store` reports -- if it did not, every
#     threshold here would be measuring one filesystem and the guard another, and the test
#     would pass while proving nothing.
#
#   * a control run that must NOT trip. Without it, an implementation that simply failed the
#     upgrade whenever free space was under the threshold at startup -- or that failed always
#     -- would satisfy the greedy subtest. The control keeps the ballast in place, so the guard
#     is armed and close to its floor, and still requires a clean upgrade.
let
  system = pkgs.stdenv.hostPlatform.system;
  builder = "${pkgs.bash}/bin/bash";
  cu = "${pkgs.coreutils}/bin";

  # The floor under test, and where the ballast leaves available space before each run. The
  # gap between them is what the greedy derivation has to eat through, so it also bounds the
  # runtime: ~400 MiB written synchronously, about half a minute.
  #
  # Far below the deployed 1 GiB default on purpose. The floor and the disk are both scaled
  # down together here; what is under test is that the guard fires at whatever floor it is
  # given, not the specific production number.
  minFreeMb = 400;
  startFreeMb = 800;

  # Writes zeros until the filesystem is gone, and no further: dd stops at ENOSPC and exits
  # non-zero, so unguarded this reproduces 2026-09-21 exactly -- a build that ends in "No space
  # left on device" -- without needing an unbounded loop that could wedge the guest.
  #
  # Deliberately NOT sized from a `df` at build time. The first draft did exactly that
  # (`count=$((avail + 128))`) and the build *succeeded*: whatever the builder measured, it was
  # enough under the real free space that dd finished with room to spare, and the subtest below
  # failed for the wrong reason. Letting dd discover the end of the filesystem itself removes
  # the measurement, and with it that entire class of silent mis-sizing.
  #
  # oflag=dsync keeps it honest: each block is synced, so the write proceeds at roughly
  # SD-card speed (~12 MB/s measured here) instead of filling the page cache in one burst and
  # leaving the guard's poller nothing to see.
  greedyBuild = "${cu}/dd if=/dev/zero of=$out bs=1M oflag=dsync";

  # Raw derivations get no PATH, so builders use bash builtins and absolute store paths, and
  # dependencies are declared by putting a derivation in an env var (`dep`) -- which orders the
  # builds without anything needing to read the file. Same shape as
  # tests/auto-upgrade-prebuild.nix, including the single total order.
  mkFlake = { greedy ? false }: pkgs.writeText "flake.nix" ''
    {
      inputs.common.url = "path:/etc/common-src";
      outputs = { self, common }:
        let
          small = derivation {
            name = "guard-small";
            system = "${system}";
            builder = "${builder}";
            args = [ "-c" "echo small > $out" ];
          };
          mid = derivation {
            name = "guard-mid";
            system = "${system}";
            builder = "${builder}";
            dep = small;
            args = [ "-c" "${if greedy then greedyBuild else "echo mid > $out"}" ];
          };
          top = derivation {
            name = "guard-top";
            system = "${system}";
            builder = "${builder}";
            dep = mid;
            args = [ "-c" "echo top $dep > $out" ];
          };
        in {
          nixosConfigurations.testhost.config.system.build.toplevel = top;
        };
    }
  '';

  flakeSmall = mkFlake { };
  flakeGreedy = mkFlake { greedy = true; };

  fakeNixosRebuild = pkgs.writeShellScriptBin "nixos-rebuild" ''
    echo "fake nixos-rebuild: $*"
  '';

  # Small on purpose: the greedy derivation writes synchronously at roughly SD-card speed, so
  # the run time of this test is essentially "how much free space is there". 2 GiB leaves
  # ~800 MiB free after ballast -- about a minute to fill, and a ~25s window between crossing
  # the floor and hitting zero for the guard's poller to notice. The guest only needs the disk
  # for writes: the base store is the host's, mounted read-only under the overlay.
  diskSizeMb = 2048;
in
nixpkgs.lib.nixos.runTest {
  name = "auto-upgrade-disk-guard";
  hostPkgs = pkgs;
  inherit globalTimeout;

  nodes.machine = { lib, ... }: {
    imports = [
      ../modules/nix-settings.nix
      ../modules/auto-upgrade.nix
    ];

    networking.hostName = "auto-upgrade-disk-guard";

    common.autoUpgrade = {
      enable = true;
      flake = "/etc/nixos#testhost";
      minFreeBytes = minFreeMb * 1024 * 1024;
      # One second, not the deployed default of five. The guest writes far faster than an SD
      # card even with oflag=dsync, so the window between crossing the floor and hitting zero
      # is short here; sampling every second keeps the test about whether the guard fires at
      # all rather than about whether it is quick enough on this particular disk.
      diskCheckSeconds = 1;
    };

    # The writable store must be on the disk, not RAM -- see the header. Without this the
    # greedy derivation exhausts memory instead of the filesystem.
    virtualisation.writableStoreUseTmpfs = false;
    virtualisation.diskSize = diskSizeMb;

    # The upgrade drags a GC in ahead of itself; make it a complete no-op. Nothing roots the
    # derivations built here, so a real GC would delete them between runs and the control
    # subtest would be measuring a rebuild. (tests/nix-gc-upgrade-exclusion.nix owns that
    # behaviour.)
    systemd.services.nix-gc.script = lib.mkForce "${pkgs.coreutils}/bin/true";

    # Only the rebuild is mocked: the prebuild under test is the real one.
    system.build.nixos-rebuild = lib.mkForce fakeNixosRebuild;

    environment.systemPackages = [ pkgs.git ];

    # The fake derivations' builders. A VM test's store holds the node's closure, and a store
    # path named only inside the flake *text* is not part of it.
    virtualisation.additionalPaths = [ pkgs.bash pkgs.coreutils ];

    # The flake is written as text, so the builder paths in it are bare strings with no Nix
    # string context: the guest's evaluator records no inputSrcs and the sandbox does not
    # bind-mount them. `builtins.storePath` would attach the context but is impure, and flake
    # evaluation is pure. Dropping the sandbox is the simple way out, as in
    # tests/auto-upgrade-prebuild.nix.
    nix.settings.sandbox = lib.mkForce false;

    # mkForce because substituters is a list option -- a plain [ ] merges with nixpkgs'
    # default and leaves cache.nixos.org in place, which in a network-less VM costs ~5s of DNS
    # failure per `nix build`.
    nix.settings.substituters = lib.mkForce [ ];

    system.stateVersion = stateVersion;
  };

  testScript = ''
    min_free_mb = ${toString minFreeMb}
    start_free_mb = ${toString startFreeMb}
    disk_size = ${toString diskSizeMb}

    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("systemctl stop nixos-upgrade.timer nix-gc.timer")

    def store_df():
        """(total, available) for the nix store filesystem, in MiB."""
        out = machine.succeed("df -m --output=size,avail /nix/store | tail -1").split()
        return int(out[0]), int(out[1])

    def install_flake(path):
        machine.succeed(
            "mkdir -p /etc/nixos /etc/common-src",
            # A minimal flake for the `common` input; a path: input keeps this offline.
            "printf '{ outputs = _: { }; }\\n' > /etc/common-src/flake.nix",
            f"cp {path} /etc/nixos/flake.nix",
            "chmod u+w /etc/nixos/flake.nix",
        )
        machine.succeed(
            "cd /etc/nixos && git init -q 2>/dev/null || true",
            "cd /etc/nixos && git add -A",
            "cd /etc/nixos && git -c user.email=t@t -c user.name=t commit -q -m flake || true",
        )

    def run_upgrade():
        # reset-failed first: back-to-back `systemctl start` of a oneshot that just failed
        # trips systemd's start rate limit, which would report as a spurious failure here.
        machine.succeed("systemctl reset-failed nixos-upgrade.service || true")
        return machine.execute("systemctl start nixos-upgrade.service")[0]

    def upgrade_log():
        # Scoped to the latest invocation: this test runs the upgrade more than once and every
        # assertion is about the run that just happened.
        inv = machine.succeed(
            "systemctl show nixos-upgrade.service -p InvocationID --value"
        ).strip()
        return machine.succeed(f"journalctl _SYSTEMD_INVOCATION_ID={inv} -o cat --no-pager")

    def built_names():
        """Derivation names the loop attempted, in order."""
        return [
            line.split("] ", 1)[1].split("-", 1)[1]
            for line in upgrade_log().splitlines()
            if "auto-upgrade: [" in line and "] " in line
        ]

    with subtest("the store filesystem is the disk, and the ballast lands on it"):
        # Preconditions, both of which would otherwise let every assertion below pass while
        # measuring the wrong thing.
        total, avail = store_df()

        # A tmpfs writable store would be sized from RAM, not from virtualisation.diskSize.
        assert abs(total - disk_size) < disk_size // 5, (
            f"nix store filesystem is {total} MiB but the guest disk is {disk_size} MiB; "
            "the store is probably not on the disk (writableStoreUseTmpfs?), so this test "
            "would fill something other than the filesystem the guard watches"
        )

        want_avail = start_free_mb
        ballast = avail - want_avail
        assert ballast > 0, (
            f"only {avail} MiB available of {total} MiB, already at or below the "
            f"{start_free_mb} MiB start point; nothing to ballast"
        )
        machine.succeed(f"dd if=/dev/zero of=/ballast bs=1M count={ballast} status=none")

        total, avail = store_df()
        assert avail <= want_avail + 64, (
            f"after writing {ballast} MiB of ballast the nix store filesystem still reports "
            f"{avail} MiB available; the ballast and the store are on different filesystems, "
            "so the guard would be watching a filesystem this test never fills"
        )
        print(f"store filesystem {total} MiB, {avail} MiB available, floor {min_free_mb} MiB")

    with subtest("the guard does not fire when the build fits"):
        # The control. Ballast stays in place, so free space sits just above the floor and the
        # guard is armed -- but these derivations write a few bytes, so a correct guard must
        # let them through. Without this an implementation that always failed, or that only
        # checked free space once at startup, would pass the greedy subtest below.
        install_flake("${flakeSmall}")
        assert run_upgrade() == 0, upgrade_log()
        log = upgrade_log()
        assert "all 3 derivations built" in log, log
        assert built_names() == ["guard-small", "guard-mid", "guard-top"], built_names()

    with subtest("a build that would exhaust the disk is killed before ENOSPC"):
        # Printed rather than asserted: if this subtest ever fails confusingly, the first
        # question is how much room the greedy build actually had to eat through.
        total, avail = store_df()
        print(f"before the greedy build: {avail} MiB available of {total} MiB, "
              f"floor is {min_free_mb} MiB")

        install_flake("${flakeGreedy}")
        assert run_upgrade() != 0, (
            "the upgrade should fail when a derivation would exhaust the store filesystem"
        )
        log = upgrade_log()

        # The assertion that distinguishes the guard from the status quo. Today the greedy
        # build runs until the filesystem is gone and nix reports ENOSPC; the whole point of
        # the guard is that the build dies while there is still room, so this string must not
        # appear.
        assert "No space left on device" not in log, (
            "the build ran to ENOSPC -- the guard must kill it before the filesystem fills:\n"
            + log
        )

        # ...and it must say so, naming the derivation, or a night like 2026-09-21 is
        # indistinguishable in the journal from any other failed upgrade.
        assert "disk guard" in log and "guard-mid" in log, log

    with subtest("the killed build aborts the loop and blocks the rebuild"):
        # guard-small is byte-identical between the two flakes, so it is already built and
        # correctly excluded; guard-mid is killed, so guard-top -- which depends on it -- must
        # never be attempted, and the rebuild must not run on a half-built system.
        assert built_names() == ["guard-mid"], built_names()
        assert "fake nixos-rebuild" not in upgrade_log(), upgrade_log()

    with subtest("the killed build's partial output is reclaimed"):
        # The floor is a trigger, not a barrier: the build keeps writing until the daemon
        # finishes tearing it down, so available space dips slightly past it (396 MiB
        # against a 400 MiB floor when this was written -- the overshoot is the teardown,
        # not the sampling). Asserting "still above the floor" would therefore be asserting
        # that the kill is instantaneous, which it is not.
        #
        # What matters instead is that the space comes back. keep-failed is false, so the
        # daemon deletes the partial output once the client is gone -- but asynchronously,
        # which is why this waits rather than sampling immediately. A guard that left its
        # partial output behind on every trip would depress the disk a little further every
        # night, and the next trip would come sooner: the wipe-loop shape, arrived at from
        # the other side.
        probe = f"test $(df -m --output=avail /nix/store | tail -1) -ge {start_free_mb - 64}"
        machine.wait_until_succeeds(probe, timeout=120)
        total, avail = store_df()
        print(f"after reclamation: {avail} MiB available of {total} MiB")
  '';
}
