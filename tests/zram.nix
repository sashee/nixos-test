{ nixpkgs, pkgs, stateVersion, machineModule }:

nixpkgs.lib.nixos.runTest {
  name = "zram";
  hostPkgs = pkgs;
  # Generous ceiling (not a fixed wait): fine under KVM, but the rpi variant runs
  # under slow TCG emulation on the KVM-less aarch64 CI runner and needs the room.
  globalTimeout = 1800;

  nodes.machine = { ... }: {
    imports = [ machineModule ];

    networking.hostName = "zram-test";
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

    # device has a nonzero size (memoryPercent = 50 of VM RAM)
    machine.succeed('test "$(cat /sys/block/zram0/disksize)" -gt 0')
  '';
}
