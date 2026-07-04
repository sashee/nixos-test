{ nixpkgs
, pkgs
, autoUpgradeModule
, stateVersion
, nodeModule ? { }
, flakeRef
}:

let
  # Flake dir (the part before '#'), as used by the preStart `nix flake update`.
  flakeRoot = builtins.head (nixpkgs.lib.splitString "#" flakeRef);
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
    imports = [ autoUpgradeModule nodeModule ];

    # mkDefault so a full system config (e.g. the rpi one) can set its own flake.
    common.autoUpgrade.flake = lib.mkDefault flakeRef;

    # This test covers timer + command shape; reboot behavior is covered by the
    # auto-upgrade-reboot test. Force both reboot paths off so the mocked rebuild (which never
    # updates the system profile) never reboots mid-test. (nodeModule is the rpi config, which
    # enables rebootOnChange.)
    system.autoUpgrade.allowReboot = lib.mkForce false;
    common.autoUpgrade.rebootOnChange = lib.mkForce false;

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

    def calls():
        return int(machine.succeed("cat /run/auto-upgrade-calls.log 2>/dev/null | wc -l").strip())

    def wait_idle():
        machine.wait_until_succeeds("systemctl show nixos-upgrade.service -p ActiveState --value | grep -F inactive")

    # First trigger absorbs any boot-time Persistent catch-up firing (a variable
    # baseline), so the test does not depend on how many times it fired at boot.
    machine.succeed("date -s '2027-01-02 00:01:00'")
    machine.succeed("date -s '2027-01-02 02:05:00'")
    machine.wait_until_succeeds("systemctl show nixos-upgrade.service -p Result --value | grep -F success", timeout=120)
    wait_idle()
    baseline = calls()

    # Second, isolated trigger: crossing exactly one more daily occurrence must
    # add exactly one run == two mocked calls (nix flake update + nixos-rebuild).
    machine.succeed("date -s '2027-01-03 00:01:00'")
    machine.succeed("date -s '2027-01-03 02:05:00'")
    machine.wait_until_succeeds(f"test $(cat /run/auto-upgrade-calls.log | wc -l) -ge {baseline + 2}", timeout=120)
    wait_idle()

    assert calls() - baseline == 2, f"one upgrade should add 2 calls, got {calls() - baseline}"

    machine.succeed("test \"$(tail -n 2 /run/auto-upgrade-calls.log | sed -n '1p')\" = 'nix flake update common --flake ${flakeRoot} --commit-lock-file'")
    machine.succeed("""
      second="$(tail -n 2 /run/auto-upgrade-calls.log | sed -n '2p')"
      case "$second" in
        "nixos-rebuild boot "*) ;;
        *) exit 1 ;;
      esac
      case "$second" in *"--refresh"*) ;; *) exit 1 ;; esac
      case "$second" in *"--flake ${flakeRef}"*) ;; *) exit 1 ;; esac
      case "$second" in *"--print-build-logs"*) ;; *) exit 1 ;; esac
      case "$second" in *"--commit-lock-file"*) ;; *) exit 1 ;; esac
      case "$second" in *"--upgrade"*) ;; *) exit 1 ;; esac
    """)
  '';
}
