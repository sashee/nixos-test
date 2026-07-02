{ nixpkgs, pkgs, stateVersion, extraModule ? { } }:

nixpkgs.lib.nixos.runTest {
  name = "nix-settings";
  hostPkgs = pkgs;
  # Generous ceiling (not a fixed wait): fine under KVM, but the rpi variant runs
  # under slow TCG emulation on the KVM-less aarch64 CI runner and needs the room.
  globalTimeout = 1800;

  nodes.machine = {
    imports = [ ../modules/nix-settings.nix extraModule ];

    system.stateVersion = stateVersion;
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    machine.succeed("systemctl is-enabled nix-gc.timer")
    machine.succeed("systemctl is-active nix-gc.timer")
    machine.succeed("systemctl show nix-gc.service -p ExecStart --value | grep -o '/nix/store/[^ ;]*' | xargs grep -F -- '--delete-older-than 14d'")
    machine.succeed("nix config show | grep -F 'auto-optimise-store = true'")
  '';
}
