{ nixpkgs, pkgs, stateVersion, machineModule, dirtyBytes, dirtyBackgroundBytes
, bluetooth ? true
}:

# The shared System feature (spec/features/system.md): zram swap plus the
# byte-based dirty-page writeback thresholds. The zram assertions are
# value-agnostic because the hosts size it differently; the writeback ones are
# not, so the expected values come in as arguments -- the per-host numbers live
# in flake.nix next to the other spec constants (gcOptions, keptAfterGc).
#
# `bluetooth`: whether this node is expected to have it enabled. Same shape and same reason as
# the parameter of the same name in tests/common-desktop.nix -- the hosts disagree (the rpi5
# spec asks for it, anya-feher-laptop's spec asks for it off), so this cannot be a constant.
# The disabled case is asserted by the host's own test, tests/anya-feher-laptop.nix.
nixpkgs.lib.nixos.runTest {
  name = "system";
  hostPkgs = pkgs;
  # Generous ceiling (not a fixed wait): fine under KVM, but the rpi variant runs
  # under slow TCG emulation on the KVM-less aarch64 CI runner and needs the room.
  globalTimeout = 1800;

  nodes.machine = { ... }: {
    imports = [ machineModule ];

    networking.hostName = "system-test";
    system.stateVersion = stateVersion;
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # zram swap device comes up
    machine.wait_until_succeeds("swapon --show=NAME --noheadings | grep -q zram", timeout=60)
    machine.succeed("test -e /dev/zram0")

    # the setup service completed successfully
    machine.succeed("systemctl show systemd-zram-setup@zram0.service -p Result --value | grep -qx success")

    # default compression algorithm is zstd
    machine.succeed("grep -q '\[zstd\]' /sys/block/zram0/comp_algorithm")

    # device has a nonzero size. Deliberately ratio-agnostic: this test is shared by the
    # laptop variants (memoryPercent 50, the module default) and the rpi one (100, raised
    # after the 2026-07-29 OOM), so it can only assert that sizing happened at all.
    machine.succeed('test "$(cat /sys/block/zram0/disksize)" -gt 0')

    # every sysctl in /etc/sysctl.d applied: systemd-sysctl fails the unit on a
    # key the running kernel rejects, so this catches a knob that went away
    # under us rather than only the two values asserted below.
    machine.succeed("systemctl show systemd-sysctl.service -p Result --value | grep -qx success")

    # the spec'd writeback thresholds are live in the kernel
    assert machine.succeed("cat /proc/sys/vm/dirty_bytes").strip() == "${toString dirtyBytes}"
    assert machine.succeed("cat /proc/sys/vm/dirty_background_bytes").strip() == "${toString dirtyBackgroundBytes}"

    # ... and they are the thresholds actually in force: the kernel zeroes the
    # ratio counterpart of whichever byte knob was written last, so a nonzero
    # ratio here would mean the byte value never took (defaults are 20 and 10).
    assert machine.succeed("cat /proc/sys/vm/dirty_ratio").strip() == "0"
    assert machine.succeed("cat /proc/sys/vm/dirty_background_ratio").strip() == "0"
    ${nixpkgs.lib.optionalString bluetooth ''
      # BlueZ is installed and bluetoothd is wired up to start.
      machine.succeed("systemctl is-enabled bluetooth.service")

      # powerOnBoot, which is the half that would otherwise go untested: a guest has no radio,
      # so hci0 never appears and "is the adapter powered" is unaskable here. What IS checkable
      # is the setting the nixpkgs module derives from it.
      machine.succeed("grep -qi 'AutoEnable *= *true' /etc/bluetooth/main.conf")
    ''}
  '';
}
