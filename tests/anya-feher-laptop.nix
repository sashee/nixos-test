{ nixpkgs, pkgs, machineModule, stateVersion }:

# Host-spec test for anya-feher-laptop (spec/anya-feher-laptop.md): asserts the
# host-specific bullets on the real host config. The shared feature behaviors
# (doh, firewall, iroh tunnel, monitoring, zram) have their own *-anya variants.
nixpkgs.lib.nixos.runTest {
  name = "anya-feher-laptop";
  hostPkgs = pkgs;
  globalTimeout = 600;

  nodes.machine = {
    imports = [ machineModule ];

    networking.hostName = "anya-feher-laptop-test";
    # auto-upgrade off in the VM (no network). monitoring and iroh-ssh stay
    # enabled: their timer cadence / sshd settings are part of what is asserted.
    # Neither service actually runs -- the pinned test clock keeps the
    # monitoring timer from elapsing, and iroh-ssh skips on the missing
    # credential, as on first boot.
    common.autoUpgrade.enable = false;
    system.stateVersion = stateVersion;
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("graphical.target")

    # anya is auto-logged in to a Plasma session, without any interaction
    machine.wait_until_succeeds("pgrep -u anya plasmashell")
    machine.wait_until_succeeds("pgrep -u anya kwin_wayland")

    # Hungarian keyboard: console keymap, X/greeter layout, Plasma session default
    machine.succeed("grep -iq 'KEYMAP=hu' /etc/vconsole.conf")
    machine.succeed("grep -q 'LayoutList=hu' /etc/xdg/kxkbrc")

    # Hungarian system language
    machine.succeed("grep -q 'LANG=hu_HU.UTF-8' /etc/locale.conf")

    # never suspend: logind refuses the verb entirely
    machine.succeed("grep -q 'AllowSuspend=no' /etc/systemd/sleep.conf")
    machine.fail("systemctl suspend")

    # lid close locks (instead of the logind default of suspending)
    machine.succeed("grep -q 'HandleLidSwitch=lock' /etc/systemd/logind.conf")
    machine.succeed("grep -q 'HandleLidSwitchExternalPower=lock' /etc/systemd/logind.conf")

    # inactivity locks: system-wide kscreenlocker default
    machine.succeed("grep -q 'Autolock=true' /etc/xdg/kscreenlockerrc")
    machine.succeed("grep -q 'LockOnResume=true' /etc/xdg/kscreenlockerrc")
    machine.succeed("grep -q 'Timeout=10' /etc/xdg/kscreenlockerrc")

    # bluetooth disabled (the shared laptop base enables it)
    machine.fail("systemctl is-enabled bluetooth.service")
    machine.fail("command -v blueman-manager")

    # wifi is NetworkManager (anya joins networks from the GUI: networkmanager group)
    machine.succeed("systemctl is-active NetworkManager.service")
    machine.succeed("groups anya | grep -wq networkmanager")

    # anya has no sudo; sashee does, and it must not prompt (the account has no password)
    machine.fail("groups anya | grep -wq wheel")
    machine.succeed("groups sashee | grep -wq wheel")
    machine.succeed("runuser -u sashee -- sudo -n true")

    # sashee: key-only ssh, locked password, no password/console login
    machine.succeed("grep -Eq '^sashee:!' /etc/shadow")
    machine.succeed("grep -iq 'PasswordAuthentication no' /etc/ssh/sshd_config")
    machine.succeed("grep -q 'ssh-ed25519' /etc/ssh/authorized_keys.d/sashee")

    # dotfiles: nix-utils on the path
    machine.succeed("command -v all-info-json")

    # spec cadences: auto GC and monitoring both run daily
    machine.succeed("systemctl show nix-gc.timer -p TimersCalendar | grep -F '*-*-* 03:15:00'")
    machine.succeed("systemctl show common-monitoring.timer -p TimersCalendar | grep -F '*-*-* 00:00:00'")
  '';
}
