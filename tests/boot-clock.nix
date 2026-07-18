{ nixpkgs, pkgs, machineModule, stateVersion }:

# Per-host regression guard against the boot clock jump. The host config sets an
# RTC base far in the future (its testRtcBase, "tomorrow 10:00"); if the RTC
# driver is not read until stage-2 (e.g. rtc_cmos as a module not in the initrd),
# the clock sits at systemd's build epoch through early boot and then jumps
# forward AFTER the timer units arm -- which fires daily timers spuriously. This
# asserts the kernel set the clock from the RTC BEFORE timers.target, i.e. no
# late jump. rpi passes (its RTC driver is in the initrd); a laptop host fails
# until rtc_cmos is added to boot.initrd.availableKernelModules.
nixpkgs.lib.nixos.runTest {
  name = "boot-clock";
  hostPkgs = pkgs;

  nodes.machine = { ... }: {
    imports = [ machineModule ];

    networking.hostName = "boot-clock-test";
    # Off in the VM: no network for upgrades, no credentials for reporting/iroh.
    common.autoUpgrade.enable = nixpkgs.lib.mkForce false;
    common.monitoring.enable = nixpkgs.lib.mkForce false;
    common.irohSsh.enable = nixpkgs.lib.mkForce false;
    system.stateVersion = stateVersion;
  };

  testScript = ''
    import re

    machine.wait_for_unit("multi-user.target")

    # Uptime at which the kernel set the system clock from the RTC.
    rtc = machine.succeed("dmesg | grep -i 'setting system clock' | head -1")
    m = re.search(r"\[\s*([0-9]+\.[0-9]+)\]", rtc)
    assert m, f"no RTC 'setting system clock' line in dmesg: {rtc!r}"
    rtc_up = float(m.group(1))

    # Uptime at which stage-2 userspace (the real root, post switch-root) began.
    # An RTC read in the initrd lands before this; a late read (module loaded by
    # stage-2 udev) lands after -- and by then the clock has jumped forward,
    # racing every timer/service that armed during stage-2 startup.
    userspace_up = int(machine.succeed("systemctl show -p UserspaceTimestampMonotonic --value").strip()) / 1e6

    machine.log(f"RTC set at {rtc_up:.2f}s ; stage-2 userspace began at {userspace_up:.2f}s")

    assert rtc_up < userspace_up, (
        f"boot clock jump: the RTC was read at {rtc_up:.2f}s, in STAGE-2 (userspace began "
        f"at {userspace_up:.2f}s) -- so the clock sat at the build epoch through early boot "
        f"and jumped forward once the RTC driver loaded, racing timers/services that armed "
        f"during stage-2. Read the RTC in the initrd: add its driver (rtc_cmos on x86) to "
        f"boot.initrd.availableKernelModules."
    )
  '';
}
