{ nixpkgs, pkgs, stateVersion, machineModule }:

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
  name = "auto-upgrade-reboot";
  hostPkgs = pkgs;

  # The real rpi system config (incl. common.autoUpgrade.rebootOnChange). The test only
  # mocks the upgrade itself + the preStart `nix`, so if the config didn't enable
  # reboot, this test would fail.
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

    # One upgrade -> new generation differs from booted -> reboot scheduled (the rpi config
    # sets rebootOnChange; if it didn't, this wait times out and the test fails).
    machine.succeed("systemctl start nixos-upgrade.service")
    machine.wait_until_succeeds("test -e /run/systemd/shutdown/scheduled", timeout=30)

    machine.succeed("shutdown -c || true")
  '';
}
