# expectReboot = true  -> asserts the host reboots after a changed upgrade
#                         (rpi: common.autoUpgrade.rebootOnChange)
# expectReboot = false -> asserts the host does NOT reboot and the new
#                         generation is only staged for the next manual reboot
#                         (laptops: "do not reboot automatically")
{ nixpkgs, pkgs, stateVersion, machineModule, expectReboot ? true }:

let
  # A fake "upgraded" system: its system toplevel differs from the booted one, so
  # common.autoUpgrade.rebootOnChange decides a reboot is needed. Just
  # symlinks to a tiny cached pkg — no real kernel is built.
  fakeTarget = pkgs.runCommand "fake-upgraded-system" { } ''
    mkdir -p $out
    for f in initrd kernel kernel-modules; do ln -s ${pkgs.hello} $out/$f; done
  '';

  # Mocked nixos-rebuild: simulate a kernel-changing upgrade by pointing the system
  # profile at fakeTarget (the real thing builds+activates a new boot generation).
  fakeNixosRebuild = pkgs.writeShellScriptBin "nixos-rebuild" ''
    exec ${pkgs.nix}/bin/nix-env -p /nix/var/nix/profiles/system --set ${fakeTarget}
  '';
in
nixpkgs.lib.nixos.runTest {
  name = "auto-upgrade-${if expectReboot then "reboot" else "no-reboot"}";
  hostPkgs = pkgs;

  # The real host system config. The test only mocks the upgrade itself + the
  # preStart `nix`, so the reboot decision comes from the host's own
  # common.autoUpgrade.rebootOnChange setting — a host config flipping it makes
  # its variant fail.
  nodes.machine = { lib, ... }: {
    imports = [ machineModule ];

    networking.hostName = "auto-upgrade-reboot";
    system.stateVersion = stateVersion;

    system.build.nixos-rebuild = lib.mkForce fakeNixosRebuild;
    systemd.services.nixos-upgrade.path = lib.mkBefore [ (pkgs.writeShellScriptBin "nix" "exit 0") ];
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    # Quiesce any boot-time Persistent firing so we observe our own triggered run.
    machine.succeed("systemctl stop nixos-upgrade.timer")
    machine.wait_until_succeeds("systemctl show nixos-upgrade.service -p ActiveState --value | grep -F inactive")
    machine.succeed("shutdown -c || true")
    machine.fail("test -e /run/systemd/shutdown/scheduled")

    machine.succeed("systemctl start nixos-upgrade.service")
  '' + (if expectReboot then ''
    # New generation differs from booted -> reboot scheduled (the host config
    # sets rebootOnChange; if it didn't, this wait times out and the test fails).
    machine.wait_until_succeeds("test -e /run/systemd/shutdown/scheduled", timeout=30)

    machine.succeed("shutdown -c || true")
  '' else ''
    # The upgrade completes and stages the new generation, but the machine must
    # stay up: activation waits for the next manual reboot (operation = "boot").
    machine.wait_until_succeeds("systemctl show nixos-upgrade.service -p ActiveState --value | grep -F inactive")
    machine.succeed("systemctl show nixos-upgrade.service -p Result --value | grep -qx success")
    machine.fail("test -e /run/systemd/shutdown/scheduled")
    machine.succeed('test "$(readlink -f /nix/var/nix/profiles/system)" = "${fakeTarget}"')
    machine.succeed('test "$(readlink -f /run/booted-system)" != "${fakeTarget}"')
  '');
}
