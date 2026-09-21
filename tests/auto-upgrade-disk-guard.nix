{ nixpkgs, pkgs, stateVersion, nodeModule, flakeRef, globalTimeout ? 2400 }:

# The disk guard on the prebuild loop of modules/auto-upgrade.nix: a build that would exhaust
# the nix store filesystem must be killed while there is still room, not left to run into
# ENOSPC -- and the guard must not fall over quietly when it cannot take a reading.
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
# The node is the deployed host configuration (nodeModule), not a hand-built one. The guard
# reads `df /nix/store`, so the store's filesystem, its nix.settings -- fsync-store-paths in
# particular -- and the services competing for the same card are all part of what it measures;
# a synthetic node would put every one of those variables outside the test. Only the flake it
# upgrades is fake: a hand-made flake of raw `derivation` calls, for the reason
# tests/auto-upgrade-prebuild.nix gives -- the subject is the loop, and a real NixOS closure
# would make this test about kernel compiles.
#
# Four things make it measure what it claims:
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
#
#   * a `df` that fails mid-build. The watchdog runs in a background subshell under the
#     errexit+pipefail writeShellApplication imposes, and the parent never reads its exit
#     status -- so a failed reading used to kill the guard outright and leave the rest of the
#     build unmonitored, indistinguishably from a guard that simply had nothing to report.
#     Both halves of the fix are pinned below: a transient failure must be survived and
#     logged, a persistent one must terminate the upgrade rather than let it run on blind.
let
  system = pkgs.stdenv.hostPlatform.system;
  builder = "${pkgs.bash}/bin/bash";
  cu = "${pkgs.coreutils}/bin";

  # The attribute the fake flake has to expose, taken from the same ref the deployed config
  # points `nixos-rebuild` at -- the prebuild instantiates
  # `<root>#nixosConfigurations."<attr>"`, so a flake built under any other name would make
  # every run here fail at eval instead of at the guard.
  flakeAttr = builtins.elemAt (nixpkgs.lib.splitString "#" flakeRef) 1;

  # Where the builders signal and the test injects. 0777 because a builder writes here and
  # nix runs it as a nixbld user, not as root.
  guardDir = "/run/df-guard";

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

  # Long enough for the watchdog to take several samples, and it announces itself first so the
  # test can inject a df failure at a point where the build is provably already running --
  # after the per-derivation pre-check, which is a separate code path with its own subtest.
  # Writes nothing: these runs are about readings, not about space.
  slowBuild = "${cu}/touch ${guardDir}/building; ${cu}/sleep 15; echo mid > $out";

  # Raw derivations get no PATH, so builders use bash builtins and absolute store paths, and
  # dependencies are declared by putting a derivation in an env var (`dep`) -- which orders the
  # builds without anything needing to read the file. Same shape as
  # tests/auto-upgrade-prebuild.nix, including the single total order.
  mkFlake = { midBuild }: pkgs.writeText "flake.nix" ''
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
            args = [ "-c" "${midBuild}" ];
          };
          top = derivation {
            name = "guard-top";
            system = "${system}";
            builder = "${builder}";
            dep = mid;
            args = [ "-c" "echo top $dep > $out" ];
          };
        in {
          nixosConfigurations."${flakeAttr}".config.system.build.toplevel = top;
        };
    }
  '';

  flakeSmall = mkFlake { midBuild = "echo mid > $out"; };
  flakeGreedy = mkFlake { midBuild = greedyBuild; };
  flakeSlow = mkFlake { midBuild = slowBuild; };

  fakeNixosRebuild = pkgs.writeShellScriptBin "nixos-rebuild" ''
    echo "fake nixos-rebuild: $*"
  '';

  # Small on purpose: the greedy derivation writes synchronously at roughly SD-card speed, so
  # the run time of this test is essentially "how much free space is there". 2 GiB leaves
  # ~800 MiB free after ballast -- about a minute to fill, and a ~25s window between crossing
  # the floor and hitting zero for the guard's poller to notice. The guest only needs the disk
  # for writes: the base store is the host's, mounted read-only under the overlay, so the real
  # host config's closure costs nothing here.
  diskSizeMb = 2048;
in
nixpkgs.lib.nixos.runTest {
  name = "auto-upgrade-disk-guard";
  hostPkgs = pkgs;
  inherit globalTimeout;

  nodes.machine = { lib, pkgs, ... }: {
    imports = [ nodeModule ];

    # Stands in for df inside the unit's mount namespace; see install_df_stub below for why a
    # bind mount rather than PATH, and why it has to dispatch on $0 instead of just being df.
    #
    # Uses shell builtins only, so it works with no PATH at all -- which matters, because
    # every coreutils command the prebuild runs arrives here.
    #
    # The df branch cannot fall through to the real df: the copy under /run is the same
    # multicall binary this stub has replaced, and asking it for `df` would report the
    # unstubbed truth. A constant well above the floor is honest enough for the subtests that
    # install it -- their builds write nothing, and what they exercise is how the guard
    # handles a reading it cannot get, not the reading itself.
    environment.etc."auto-upgrade-test/df-stub".source = pkgs.writeShellScript "df-stub" ''
      prog="''${0##*/}"
      if [ "$prog" = df ]; then
        if [ -e ${guardDir}/break ]; then
          echo "df: /nix/store: Input/output error" >&2
          exit 1
        fi
        printf 'Avail\n%s\n' "$((64 * 1024 * 1024 * 1024))"
        exit 0
      fi
      exec /run/real-coreutils/bin/"$prog" "$@"
    '';

    # The coreutils the prebuild resolves, recorded from the *node's* pkgs. Not the test
    # file's: the node is the deployed host config, which is free to bring its own nixpkgs or
    # overlays, and a bind mount aimed at the wrong store path would silently shadow nothing.
    environment.etc."auto-upgrade-test/coreutils-bin".text = "${pkgs.coreutils}/bin";

    # Written by the slow builder, which nix runs as a nixbld user.
    systemd.tmpfiles.rules = [ "d ${guardDir} 0777 root root -" ];

    # Normal priority, to break a tie: hosts/rpi5 and the test framework's network.nix both
    # define hostName with mkDefault, and two mkDefaults of differing values conflict. Every
    # rpi node in this repo names itself for the same reason. It does not reach the prebuild
    # -- the flake ref below carries an explicit attribute, so nixos-rebuild's
    # hostname-fallback never applies.
    networking.hostName = "auto-upgrade-disk-guard";

    # Same value hosts/rpi5 sets, passed in from the same place the sibling upgrade checks
    # take it. Plain, not mkForce: str merges equal definitions and rejects differing ones, so
    # this fails loudly at eval if the two ever drift -- and the fake flake below is named
    # from it, so drift would otherwise show up as an unrelated eval error inside the guest.
    common.autoUpgrade.flake = flakeRef;

    # mkForce because the deployed floor is 1 GiB and this node's disk is 2 GiB: the scaled
    # pair is the whole point (see minFreeMb). One second rather than the deployed five, for
    # the same reason -- the guest writes far faster than an SD card even with oflag=dsync, so
    # sampling every second keeps this about whether the guard fires rather than about whether
    # it is quick enough on this particular disk.
    common.autoUpgrade.minFreeBytes = lib.mkForce (minFreeMb * 1024 * 1024);
    common.autoUpgrade.diskCheckSeconds = lib.mkForce 1;

    # The rpi config enables rebootOnChange. The control subtest runs a successful upgrade
    # through the mocked rebuild, which never updates the system profile, so the comparison
    # against /run/booted-system would schedule a reboot mid-test. Both reboot paths off.
    common.autoUpgrade.rebootOnChange = lib.mkForce false;
    system.autoUpgrade.allowReboot = lib.mkForce false;

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
    # tests/auto-upgrade-prebuild.nix. It is also what lets the slow builder reach guardDir.
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
    guard_dir = "${guardDir}"

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

    def start_upgrade():
        # reset-failed first: back-to-back `systemctl start` of a oneshot that just failed
        # trips systemd's start rate limit, which would report as a spurious failure here.
        machine.succeed("systemctl reset-failed nixos-upgrade.service || true")
        machine.succeed(f"rm -f {guard_dir}/building {guard_dir}/break")
        machine.succeed("systemctl start --no-block nixos-upgrade.service")

    def wait_upgrade():
        """Block until the started run has ended; return its systemd Result."""
        machine.wait_until_succeeds(
            "systemctl show nixos-upgrade.service -p ActiveState --value "
            "| grep -Eqx 'inactive|failed'",
            timeout=600,
        )
        return machine.succeed(
            "systemctl show nixos-upgrade.service -p Result --value"
        ).strip()

    def run_upgrade():
        # reset-failed for the same reason as above; this one blocks, which is what the
        # subtests that need no mid-run injection want.
        machine.succeed("systemctl reset-failed nixos-upgrade.service || true")
        machine.succeed(f"rm -f {guard_dir}/building {guard_dir}/break")
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

    def install_df_stub():
        """Shadow the prebuild's df with the stub, inside that unit only.

        A bind mount in the unit's own mount namespace rather than a PATH entry: the prebuild
        is a writeShellApplication, which puts its runtimeInputs at the *front* of PATH, so
        nothing planted in PATH can win.

        The target is not `bin/df`. nixpkgs builds coreutils as one multicall binary with a
        symlink per command, systemd resolves a bind-mount target through symlinks, and a
        mount aimed at `bin/df` therefore lands on `bin/coreutils` and replaces tr, wc, tail
        and mktemp along with it. (Observed exactly that: the loop died with `tr: printf:
        write error: Broken pipe`.) So the stub takes over the whole multicall binary and
        dispatches on $0, with every other command forwarded to a copy of the real one --
        which has to be a copy, since the original is the path being shadowed.
        """
        cu_bin = machine.succeed("cat /etc/auto-upgrade-test/coreutils-bin").strip()
        target = machine.succeed(f"readlink -f {cu_bin}/df").strip()
        assert target.endswith("/coreutils"), (
            f"expected {cu_bin}/df to resolve to coreutils' multicall binary, got {target}; "
            "if the layout changed to one file per command the stub no longer needs to "
            "dispatch, but the forwarding copy below would be wrong"
        )
        machine.succeed(
            "mkdir -p /run/real-coreutils/bin",
            f"cp {target} /run/real-coreutils/bin/coreutils",
            f'for n in $(ls {cu_bin}); do [ "$n" = coreutils ] || '
            'ln -sf coreutils /run/real-coreutils/bin/"$n"; done',
            "install -m 0755 /etc/auto-upgrade-test/df-stub /run/df-stub",
            "mkdir -p /run/systemd/system/nixos-upgrade.service.d",
            "printf '[Service]\\nBindReadOnlyPaths=/run/df-stub:%s\\n' "
            f"{target} > /run/systemd/system/nixos-upgrade.service.d/df-stub.conf",
            "systemctl daemon-reload",
        )

    def remove_df_stub():
        machine.succeed(
            "rm -rf /run/systemd/system/nixos-upgrade.service.d /run/real-coreutils",
            f"rm -f {guard_dir}/break",
            "systemctl daemon-reload",
        )

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

    # The two df-failure subtests share one flake: the first kills guard-mid before it can
    # write $out, so the derivation is still outstanding and the second run builds it again.
    install_df_stub()
    install_flake("${flakeSlow}")

    with subtest("a disk it cannot read terminates the upgrade"):
        # The regression this pins: the watchdog polls in a background subshell that inherited
        # errexit and pipefail, and the parent never looks at its exit status -- only at the
        # file it writes when it trips. So a df that failed used to kill the watchdog outright
        # and leave the remaining hours of the build completely unmonitored, with nothing in
        # the journal to say so. An upgrade that cannot be measured must stop, not continue
        # blind; the 2026-09-21 outage is what running unmonitored looks like.
        start_upgrade()
        # The builder announces itself, so the failure lands while a build is genuinely in
        # flight -- after the per-derivation pre-check, which the next assertion separates out.
        machine.wait_for_file(f"{guard_dir}/building", timeout=300)
        machine.succeed(f"touch {guard_dir}/break")

        assert wait_upgrade() != "success", (
            "the upgrade should fail when the guard cannot read available space:\n"
            + upgrade_log()
        )
        log = upgrade_log()

        # Named, counted and attributed, so this is distinguishable in the journal from a
        # build that simply failed -- and from the floor being crossed, which it was not.
        assert "cannot read available space" in log, log
        assert "unreadable" in log and "guard-mid" in log, log
        assert "terminating the upgrade" in log, log

        # It must be the watchdog that stopped this, not the pre-check: the pre-check ran
        # before the injection and saw a healthy figure, and proving the two paths are
        # distinct is the point of waiting for the builder above.
        assert "before building" not in log, log

    with subtest("a transient unreadable disk is survived, and logged"):
        # The other half. Terminating on the first failed sample would be its own outage --
        # df here reads a filesystem being hammered by the build it is measuring -- so a brief
        # failure must leave the upgrade running, and must still be visible in the journal
        # rather than swallowed.
        machine.succeed(f"rm -f {guard_dir}/break")
        start_upgrade()
        machine.wait_for_file(f"{guard_dir}/building", timeout=300)

        # Lifted as soon as one failed sample is on record, rather than after a fixed sleep.
        # The budget is three consecutive samples a second apart, so any window wide enough
        # to guarantee a failure is also close enough to three to trip on a slow moment --
        # a first draft slept 2s and logged 2 of the 3. Scoped to this invocation, or it
        # would match the previous subtest's failures and lift the break immediately.
        inv = machine.succeed(
            "systemctl show nixos-upgrade.service -p InvocationID --value"
        ).strip()
        machine.succeed(f"touch {guard_dir}/break")
        machine.wait_until_succeeds(
            f"journalctl _SYSTEMD_INVOCATION_ID={inv} -o cat --no-pager "
            "| grep -q 'cannot read available space'",
            timeout=60,
        )
        machine.succeed(f"rm -f {guard_dir}/break")

        assert wait_upgrade() == "success", (
            "a transient df failure must not fail the upgrade:\n" + upgrade_log()
        )
        log = upgrade_log()
        assert "cannot read available space" in log, (
            "the failed sample must reach the journal -- a guard that hides them is a guard "
            "nobody can tell has stopped working:\n" + log
        )
        assert "terminating the upgrade" not in log, log
        assert built_names() == ["guard-mid", "guard-top"], built_names()

    remove_df_stub()
  '';
}
