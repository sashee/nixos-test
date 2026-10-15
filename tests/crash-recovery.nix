{ nixpkgs, pkgs, stateVersion, machineModule }:

# modules/crash-recovery.nix end to end, on the real host config (machineModule): every remedy is
# triggered for real and the test watches the machine reboot, or the watchdog fire.
#
#   * initrd failure -> panic -> reboot. Node `initrdfail` needs a filesystem in the initrd whose
#     device never appears. It never finishes booting, so it is its own node.
#   * failed mount after the initrd -> the boot carries on. `machine` has a stage-2 mount whose
#     device never appears, on every boot.
#   * hardware watchdog, armed in the initrd and again after switch-root, and a hung PID 1 reset
#     by it. QEMU has no BCM2835, so the node gets an emulated i6300esb. "Hung" is PID 1's cgroup
#     frozen: it stops pinging but keeps the device open, as a real hang does.
#   * a crashed PID 1 -> it reboots itself (systemd.crash_action). This is NOT the watchdog's
#     case. See modules/crash-recovery.nix for why, after the initrd's arming, a crash
#     would stop the watchdog rather than trip it.
#   * an oops, through a test-only module (./crash-recovery-oops.nix) that oopses on load. Before
#     panic-on-oops is armed it kills only the task and the machine stays up. The arming waits the
#     real 10 minutes after the reachable target starts, which the test starts itself, standing in
#     for the iroh-ssh failsafe's first answer: there is no tunnel here. tests/iroh-ssh.nix proves
#     the failsafe starts it, tests/crash-recovery-deployed.nix that the Pi is wired to it. Then the
#     escape hatch disarms it, and once armed again an oops -> panic -> reboot.
#   * a saved crash log -> the journal, through the real systemd-pstore unit and the deployed
#     pstore.conf, and on disk before a crash right after can lose it.
#
# Not covered, and cannot be: ramoops itself. On the Pi it is a device-tree overlay that a VM
# never reads, and the driver runs QEMU with -no-reboot, so every reboot here is a fresh QEMU
# whose RAM held nothing. tests/crash-recovery-deployed.nix guards what config.txt asks for, and
# one deliberate crash on the Pi proves the memory survives its reset.
#
# Every reboot is a QEMU exit (-no-reboot), so "it rebooted" is wait_for_shutdown(), and what
# caused it is read off the serial console of that boot.
#
# NixOS's test instrumentation passes `panic=1 boot.panic_on_fail` to every test VM, before the
# host's own parameters are appended:
#
#   * panic= is last-wins, and the module appends its own with mkAfter, so "Rebooting in 10
#     seconds" below is the host's value winning. It would read 1 if the host's were missing or
#     came first.
#   * boot.panic_on_fail is a flag, so the instrumentation's copy alone would set it. The initrd
#     subtest proves the chain on this host's initrd, not that the host passes the flag.
#     tests/crash-recovery-deployed.nix pins the flag on the deployed config.
let
  # A label nothing will ever carry. x-systemd.device-timeout keeps the wait short; without it
  # systemd waits its default 90s for the device on every boot of both nodes.
  missingDevice = "/dev/disk/by-label/crash-recovery-missing";
  missingDeviceOptions = [ "x-systemd.device-timeout=5s" ];
  initrdWatchdogReport = "/run/crash-recovery-initrd-watchdog";
in
nixpkgs.lib.nixos.runTest {
  name = "crash-recovery";
  hostPkgs = pkgs;
  # Ceiling, not a wait: on top of five boots, the arming subtest waits the real 10 minutes,
  # and the rpi variant runs under TCG on the KVM-less aarch64 CI runner.
  globalTimeout = 5400;

  nodes.machine = { config, ... }: {
    imports = [ machineModule ];

    networking.hostName = "crash-recovery";
    system.stateVersion = stateVersion;

    # The Pi's watchdog is the BCM2835 PM block, which QEMU does not emulate. The 6300ESB is the
    # stand-in, and the Pi kernel ships its driver (CONFIG_I6300ESB_WDT=m). The action is `pause`
    # rather than QEMU's default `reset`: -no-reboot turns a reset into a plain exit, which looks
    # the same as the panic reboots below, while a pause shows up in the monitor as
    # "paused (watchdog)".
    virtualisation.qemu.options = [ "-device" "i6300esb" "-action" "watchdog=pause" ];
    # Loaded in the initrd so the initrd's PID 1 has something to arm. On the Pi the driver is
    # built in and exists before PID 1 starts. Here it is a module, so PID 1's first attempt
    # finds no device and it retries every few seconds.
    boot.initrd.kernelModules = [ "i6300esb" ];
    # Holds the initrd back until its PID 1 has armed the watchdog, which it does within one
    # retry, and records what the hardware said at that moment. Otherwise a fast initrd could
    # switch root before that retry. /run survives switch-root, so stage 2 can read the report.
    boot.initrd.systemd.services.crash-recovery-initrd-watchdog = {
      wantedBy = [ "initrd.target" ];
      before = [ "initrd.target" ];
      serviceConfig.Type = "oneshot";
      script = ''
        w=/sys/class/watchdog/watchdog0
        for _ in $(seq 60); do
          [ "$(cat "$w/state" 2>/dev/null)" = active ] && break
          sleep 1
        done
        {
          echo "identity=$(cat "$w/identity" 2>/dev/null)"
          echo "state=$(cat "$w/state" 2>/dev/null)"
          echo "timeout=$(cat "$w/timeout" 2>/dev/null)"
        } > ${initrdWatchdogReport}
      '';
    };

    boot.extraModulePackages = [ (config.boot.kernelPackages.callPackage ./crash-recovery-oops.nix { }) ];

    # No framebuffer console, which is how the Pi runs: headless, /sys/class/graphics has fbcon
    # but no fb0 (checked 2026-10-15). qemu-vm always gives the VM a display (std VGA on x86,
    # virtio-gpu-pci on aarch64). With its DRM framebuffer console up, a stage-2 panic never
    # reaches its panic= reboot. Reproduced on 6.18.56 with bochs-drm: hung 400s, while with
    # nomodeset the same oops rebooted in 13s. nomodeset keeps the native DRM drivers off.
    boot.kernelParams = [ "nomodeset" ];

    virtualisation.fileSystems."/missing" = {
      device = missingDevice;
      fsType = "ext4";
      options = missingDeviceOptions;
    };
  };

  nodes.initrdfail = { ... }: {
    imports = [ machineModule ];

    networking.hostName = "crash-recovery-initrd";
    system.stateVersion = stateVersion;

    # neededForBoot puts the mount in the initrd, under initrd-fs.target, whose OnFailure= is the
    # initrd's emergency.target.
    virtualisation.fileSystems."/needed" = {
      device = missingDevice;
      fsType = "ext4";
      neededForBoot = true;
      options = missingDeviceOptions;
    };
  };

  testScript = { nodes, ... }: let
    reachableTarget = nodes.machine.common.crashRecovery.reachableTarget;
    # The names the escape hatch in docs/rpi5-rescue.md uses.
    arming = "crash-recovery-panic-on-oops";
    offFlag = "/run/crash-recovery-oops-panic-off";
  in ''
    import re
    import time

    def wait_console(node, since, pattern, timeout):
        """Wait for `pattern` in the console output of `node`'s current boot past offset `since`."""
        deadline = time.monotonic() + timeout
        while not re.search(pattern, node.get_console_log()[since:]):
            assert time.monotonic() < deadline, f"{pattern!r} never appeared on {node.name}'s console"
            time.sleep(1)

    def panic_on_oops():
        return machine.succeed("cat /proc/sys/kernel/panic_on_oops").strip()

    def oops(node):
        """Load the oopsing module. In the background and after a moment, so the backdoor's reply
        is out before the kernel goes, if it does."""
        since = len(node.get_console_log())
        node.succeed("(sleep 2; modprobe crash_recovery_oops) >/dev/null 2>&1 &")
        wait_console(node, since, r"kernel BUG at", 120)
        return since

    def rebooted_from_panic(node, since, cause):
        """The panic message for `cause`, panic=10's countdown, then the reboot (a QEMU exit)."""
        wait_console(node, since, rf"Kernel panic - not syncing: .*{cause}", 600)
        wait_console(node, since, r"Rebooting in 10 seconds", 60)
        node.wait_for_shutdown()

    with subtest("an initrd that fails panics the kernel, which reboots"):
        # The device times out, initrd-fs.target fails into the initrd's emergency.target, and
        # panic-on-fail.service crashes the kernel with sysrq-c, which is the only thing that would.
        # Without boot.panic_on_fail it would sit in a locked emergency mode and never exit
        # (see the header for whose boot.panic_on_fail this is).
        initrdfail.start()
        rebooted_from_panic(initrdfail, 0, "sysrq triggered crash")

    machine.start()
    machine.wait_for_unit("multi-user.target")

    with subtest("the boot parameters reached the kernel"):
        params = machine.succeed("cat /proc/cmdline").split()
        for p in ("panic=10", "boot.panic_on_fail", "systemd.crash_action=reboot"):
            assert p in params, params
        assert "oops=panic" not in params, params
        # The kernel's effective values: the host's panic= is the last one (see the header), and
        # nothing in stage 2 set it back through sysctl. panic_on_oops waits for its arming.
        assert machine.succeed("cat /proc/sys/kernel/panic").strip() == "10"
        assert panic_on_oops() == "0"

    with subtest("a mount that fails after the initrd does not stop the boot"):
        # Reaching multi-user.target above is the assertion. These check that the boot got there
        # past the failure rather than around it.
        machine.fail("mountpoint -q /missing")
        journal = machine.succeed("journalctl -b -u local-fs.target -o cat")
        assert re.search(r"Dependency failed for .*Local File Systems", journal), journal
        load = machine.succeed("systemctl show -p LoadState --value emergency.target").strip()
        assert load == "not-found", load

    with subtest("the initrd armed the hardware watchdog"):
        report = dict(
            line.split("=", 1)
            for line in machine.succeed("cat ${initrdWatchdogReport}").splitlines()
        )
        assert report == {"identity": "i6300ESB timer", "state": "active", "timeout": "120"}, report

    with subtest("after switch-root the system manager armed it again"):
        # The initrd's PID 1 disarms it before handing over, so this is stage 2's own arming.
        w = "/sys/class/watchdog/watchdog0"
        assert machine.succeed(f"cat {w}/identity").strip() == "i6300ESB timer"
        assert machine.succeed(f"cat {w}/state").strip() == "active"
        assert machine.succeed(f"cat {w}/timeout").strip() == "120"

    with subtest("systemd-pstore ran at boot only once the journal was on disk"):
        # Its condition failed (nothing in /sys/fs/pstore), but PID 1 logs that when the start
        # job runs, so it still shows the ordering. The first such line: the condition is
        # checked again later in the boot, and ConditionTimestamp keeps only that one. Without
        # the ordering it was seen between the flush's Starting and Finished.
        lines = machine.succeed(
            "journalctl -b -o cat -u systemd-journal-flush.service -u systemd-pstore.service"
        ).splitlines()
        flushed = lines.index("Finished Flush Journal to Persistent Storage.")
        pstore = next(i for i, l in enumerate(lines) if l.startswith("Platform Persistent Storage Archival"))
        assert flushed < pstore, lines

    with subtest("a saved crash log survives a crash right after it went into the journal"):
        # The pstore backend is not testable here (see the header), so a tmpfs stands in for it
        # and the real unit runs on a staged log, with the deployed /etc/systemd/pstore.conf.
        machine.succeed(
            "mount -t tmpfs pstore-stand-in /sys/fs/pstore",
            "echo crash-recovery-marker > /sys/fs/pstore/dmesg-ramoops-0",
            "systemctl start systemd-pstore.service",
        )
        # Moved, not copied: gone from the source, and Storage=journal archived nothing.
        left = machine.succeed("find /sys/fs/pstore /var/lib/systemd/pstore -type f")
        assert left == "", left
        # A hard reset the moment the unit is done, as a crash loop would: whatever the guest
        # had not written to disk is gone.
        machine.crash()
        machine.start()
        machine.wait_for_unit("multi-user.target")
        machine.succeed(
            "journalctl -b -1 --all -o cat --output-fields=FILE 'MESSAGE=PStore dmesg-ramoops-0.'"
            " | grep -qx crash-recovery-marker"
        )

    with subtest("an oops before panic-on-oops is armed does not panic"):
        # The failsafe is running, but with no tunnel here its probe never answers, so nothing
        # arms it.
        machine.fail("systemctl is-active ${reachableTarget}")
        assert panic_on_oops() == "0"
        since = oops(machine)
        # Well past panic=10's countdown, had there been a panic.
        time.sleep(30)
        machine.succeed("true")
        assert "Kernel panic" not in machine.get_console_log()[since:]
        # Bit 7 is TAINT_DIE: the kernel oopsed and carried on.
        tainted = int(machine.succeed("cat /proc/sys/kernel/tainted"))
        assert tainted & (1 << 7), tainted

    with subtest("a hung PID 1 is reset by the hardware watchdog"):
        hung = time.monotonic()
        # PID 1 is alone in init.scope, so freezing that cgroup stops PID 1 and nothing else. It
        # keeps the watchdog open and simply stops pinging it. From here on nothing may talk to
        # PID 1 (systemctl, D-Bus); it would never answer.
        machine.succeed("echo 1 > /sys/fs/cgroup/init.scope/cgroup.freeze")
        machine.wait_until_succeeds("grep -qx 'frozen 1' /sys/fs/cgroup/init.scope/cgroup.events", timeout=30)
        # The kernel and the rest of userspace are fine, so what comes next is the watchdog
        # acting on PID 1 alone.
        machine.succeed("true")
        # The last ping was at most a minute ago (PID 1 pings at half the 2min timeout).
        deadline = hung + 600
        while "paused (watchdog)" not in (status := machine.send_monitor_command("info status")):
            assert time.monotonic() < deadline, status
            time.sleep(5)
        machine.log(f"watchdog fired {time.monotonic() - hung:.0f}s after PID 1 hung")
        machine.crash()

    with subtest("a crashed PID 1 reboots the machine itself"):
        machine.start()
        machine.wait_for_unit("multi-user.target")
        since = len(machine.get_console_log())
        # PID 1's crash handler takes it: core dump, then CrashAction. The default would
        # freeze here forever, with the watchdog stopped by that freeze's close (see the
        # header).
        machine.succeed("kill -SEGV 1")
        # PID 1 logs to journald, which the test instrumentation forwards to the console.
        wait_console(machine, since, r"Caught <SEGV>", 120)
        wait_console(machine, since, r"Rebooting in 10s", 120)
        machine.wait_for_shutdown()

    with subtest("panic-on-oops is armed 10 minutes after ssh first answers"):
        machine.start()
        machine.wait_for_unit("multi-user.target")
        # Only the reachable target pulls the timer in, not timers.target at boot.
        machine.fail("systemctl is-active ${arming}.timer")
        # Standing in for the failsafe's first answer (see the header).
        machine.succeed("systemctl start ${reachableTarget}")
        machine.succeed("systemctl is-active ${arming}.timer")
        assert panic_on_oops() == "0"
        # Not wait_for_unit: that gives up on an inactive unit with no job queued, which is
        # what the service is until the timer fires.
        machine.wait_until_succeeds("systemctl is-active ${arming}.service", timeout=900)
        assert panic_on_oops() == "1"
        # On the guest's own monotonic clock, so a slow host cannot make it look early.
        def entered(unit):
            return int(machine.succeed(f"systemctl show -P ActiveEnterTimestampMonotonic {unit}"))
        delay = entered("${arming}.service") - entered("${reachableTarget}")
        assert delay >= 600 * 10**6, delay
        machine.log(f"armed {delay / 10**6:.0f}s after ${reachableTarget}")

    with subtest("the escape hatch disarms it for the rest of the boot"):
        # The way out of a crash loop that recurs after the arming. Not `systemctl mask --runtime
        # --now`: run here, it disarmed, but the mask did not hold and the next start re-armed
        # (see modules/crash-recovery.nix for why).
        machine.succeed("touch ${offFlag} && systemctl stop ${arming}.service")
        assert panic_on_oops() == "0"
        # Whatever starts it again, the timer or a start of the target that pulls it in, now
        # finds its condition false. A failed condition is not an error, hence succeed.
        machine.succeed("systemctl start ${arming}.service")
        assert machine.succeed("systemctl show -P ConditionResult ${arming}.service").strip() == "no"
        assert panic_on_oops() == "0"

    with subtest("once armed, an oops panics the kernel, which reboots"):
        machine.succeed("rm ${offFlag}", "systemctl start ${arming}.service")
        assert panic_on_oops() == "1"
        rebooted_from_panic(machine, oops(machine), "Fatal exception")
  '';
}
