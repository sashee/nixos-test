{ nixpkgs, pkgs, stateVersion }:

nixpkgs.lib.nixos.runTest {
  name = "nix-settings";
  hostPkgs = pkgs;
  globalTimeout = 120;

  nodes.machine = {
    imports = [ ../modules/nix-settings.nix ];

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
