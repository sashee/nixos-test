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

    # The mocks append to this; create it up front so the test can count it before the first
    # upgrade run. The test driver runs every command with `set -euo pipefail`, so reading a
    # missing file fails rather than counting zero.
    systemd.tmpfiles.rules = [ "f /run/auto-upgrade-calls.log 0644 root root -" ];

    system.build.nixos-rebuild = lib.mkForce fakeNixosRebuild;
    systemd.services.nixos-upgrade.path = lib.mkBefore [ fakeNix ];
  };

  testScript = ''
    import shlex

    machine.start()
    machine.wait_for_unit("multi-user.target")

    machine.succeed("systemctl show nixos-upgrade.timer -p TimersCalendar --value | grep -F '*-*-* 00:00:00'")
    machine.succeed("systemctl show nixos-upgrade.timer -p Persistent --value | grep -F yes")
    machine.succeed("systemctl show nixos-upgrade.timer -p RandomizedDelayUSec --value | grep -F '2h'")
    machine.succeed("systemctl is-active --quiet nixos-upgrade.timer")

    def prop(unit, name):
        # Returned verbatim, not parsed: systemd renders these inconsistently -- the timer's
        # LastTriggerUSecMonotonic comes out as "12.910274s" while the service's
        # InactiveEnterTimestampMonotonic comes out as raw microseconds, and both are a bare
        # "0" while unset. So compare them for *change*; a monotonic clock only moves
        # forward, so "changed" means "advanced".
        return machine.succeed(f"systemctl show {unit} -p {name} --value").strip()

    def wait_until_changed(unit, name, previous):
        machine.wait_until_succeeds(
            f'test "$(systemctl show {unit} -p {name} --value)" != {shlex.quote(previous)}',
            timeout=120,
        )

    def calls():
        return int(machine.succeed("wc -l < /run/auto-upgrade-calls.log").strip())

    def trigger_daily_upgrade(day):
        """Cross exactly one daily occurrence; return how many mocked calls that run logged.

        Readiness comes from systemd's record of the timer firing and of the service
        invocation ending -- NOT from Result/ActiveState, which already read
        success/inactive for a unit that has never started. Both timestamps are
        CLOCK_MONOTONIC, so the date jumps below cannot move them.
        """
        # Here `inactive` means only "nothing running right now" (also true when the unit
        # never ran), so the snapshots are taken against a quiet unit.
        machine.wait_until_succeeds(
            "systemctl show nixos-upgrade.service -p ActiveState --value | grep -Fqx inactive"
        )
        before_trigger = prop("nixos-upgrade.timer", "LastTriggerUSecMonotonic")
        before_finish = prop("nixos-upgrade.service", "InactiveEnterTimestampMonotonic")
        before_calls = calls()

        # The 00:01 jump may land inside the 2h randomized delay window; 02:05 is past the
        # whole window. Together they cross this day's occurrence exactly once.
        machine.succeed(f"date -s '{day} 00:01:00'")
        machine.succeed(f"date -s '{day} 02:05:00'")

        wait_until_changed("nixos-upgrade.timer", "LastTriggerUSecMonotonic", before_trigger)
        wait_until_changed("nixos-upgrade.service", "InactiveEnterTimestampMonotonic", before_finish)
        machine.succeed("systemctl show nixos-upgrade.service -p Result --value | grep -qx success")
        return calls() - before_calls

    # One daily occurrence == one run == two mocked calls (nix flake update + nixos-rebuild).
    first = trigger_daily_upgrade("2027-01-02")
    assert first == 2, f"one upgrade should log 2 calls (nix flake update + nixos-rebuild), got {first}"

    # The timer must re-arm: the next daily occurrence adds exactly one more run.
    next_day = trigger_daily_upgrade("2027-01-03")
    assert next_day == 2, f"the next day's occurrence should add 2 more calls, got {next_day}"

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
      # Concurrency caps: the unattended upgrade must stay bounded on low-RAM hosts (see
      # the flags comment in modules/auto-upgrade.nix). Pinned so they cannot silently drop.
      case "$second" in *"--cores 1"*) ;; *) exit 1 ;; esac
      case "$second" in *"--max-jobs 1"*) ;; *) exit 1 ;; esac
    """)
  '';
}
