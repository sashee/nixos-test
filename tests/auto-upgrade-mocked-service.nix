{ nixpkgs
, pkgs
, autoUpgradeModule
, stateVersion
}:

let
  fakeNix = pkgs.writeShellScriptBin "nix" ''
    set -eu
    printf 'nix' >> /run/auto-upgrade-calls.log
    printf ' %s' "$@" >> /run/auto-upgrade-calls.log
    printf '\n' >> /run/auto-upgrade-calls.log
  '';
  fakeNixosRebuild = pkgs.runCommand "fake-nixos-rebuild" { } ''
    mkdir -p $out/bin
    cat > $out/bin/nixos-rebuild <<'EOF'
    #!${pkgs.runtimeShell}
    set -eu
    printf 'nixos-rebuild' >> /run/auto-upgrade-calls.log
    printf ' %s' "$@" >> /run/auto-upgrade-calls.log
    printf '\n' >> /run/auto-upgrade-calls.log
    EOF
    chmod +x $out/bin/nixos-rebuild
  '';
in
nixpkgs.lib.nixos.runTest {
  name = "auto-upgrade-mocked-service";
  hostPkgs = pkgs;

  nodes.machine = { lib, ... }: {
    imports = [ autoUpgradeModule ];

    common.autoUpgrade.flake = "/etc/nixos#laptop";

    networking.hostName = "auto-upgrade-mocked-service";
    system.stateVersion = stateVersion;

    system.build.nixos-rebuild = lib.mkForce fakeNixosRebuild;
    systemd.services.nixos-upgrade.path = lib.mkBefore [ fakeNix ];
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    machine.succeed("systemctl show nixos-upgrade.timer -p TimersCalendar --value | grep -F '*-*-* 00:00:00'")
    machine.succeed("systemctl show nixos-upgrade.timer -p Persistent --value | grep -F yes")
    machine.succeed("systemctl show nixos-upgrade.timer -p RandomizedDelayUSec --value | grep -F '2h'")
    machine.succeed("systemctl is-active --quiet nixos-upgrade.timer")

    machine.succeed("date -s '2027-01-02 00:01:00'")
    machine.succeed("date -s '2027-01-02 02:05:00'")
    machine.wait_until_succeeds("test -f /run/auto-upgrade-calls.log && systemctl show nixos-upgrade.service -p ActiveState --value | grep -F inactive && systemctl show nixos-upgrade.service -p Result --value | grep -F success", timeout=120)
    machine.succeed("cat /run/auto-upgrade-calls.log")
    machine.succeed("test \"$(sed -n '1p' /run/auto-upgrade-calls.log)\" = 'nix flake update common --flake /etc/nixos --commit-lock-file'")
    machine.succeed("""
      second="$(sed -n '2p' /run/auto-upgrade-calls.log)"
      case "$second" in
        "nixos-rebuild boot "*) ;;
        *) exit 1 ;;
      esac
      case "$second" in *"--refresh"*) ;; *) exit 1 ;; esac
      case "$second" in *"--flake /etc/nixos#laptop"*) ;; *) exit 1 ;; esac
      case "$second" in *"--print-build-logs"*) ;; *) exit 1 ;; esac
      case "$second" in *"--commit-lock-file"*) ;; *) exit 1 ;; esac
      case "$second" in *"--upgrade"*) ;; *) exit 1 ;; esac
    """)
    machine.succeed("test \"$(wc -l < /run/auto-upgrade-calls.log)\" = 2")
  '';
}
