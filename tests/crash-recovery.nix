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
#   * oops -> panic -> reboot, through a test-only module (./crash-recovery-oops.nix) that oopses
#     on load.
#   * a saved crash log -> the journal, through the real systemd-pstore and the deployed
#     pstore.conf.
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

  testScript = ''
    import re
    import time

    def wait_console(node, since, pattern, timeout):
        """Wait for `pattern` in the console output of `node`'s current boot past offset `since`."""
        deadline = time.monotonic() + timeout
        while not re.search(pattern, node.get_console_log()[since:]):
            assert time.monotonic() < deadline, f"{pattern!r} never appeared on {node.name}'s console"
            time.sleep(1)

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
        for p in ("panic=10", "oops=panic", "boot.panic_on_fail", "systemd.crash_action=reboot"):
            assert p in params, params
        # The kernel's effective values: the host's panic= is the last one (see the header),
        # and nothing in stage 2 set either back through sysctl.
        assert machine.succeed("cat /proc/sys/kernel/panic").strip() == "10"
        assert machine.succeed("cat /proc/sys/kernel/panic_on_oops").strip() == "1"

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

    with subtest("a saved crash log goes into the journal and leaves no file behind"):
        # The pstore backend is not testable here (see the header), so the real systemd-pstore is
        # run on a staged log, with the deployed /etc/systemd/pstore.conf.
        machine.succeed(
            "mkdir -p /tmp/pstore/src /tmp/pstore/archive",
            "echo crash-recovery-marker > /tmp/pstore/src/dmesg-ramoops-0",
            "/run/current-system/systemd/lib/systemd/systemd-pstore /tmp/pstore/src /tmp/pstore/archive",
        )
        # Moved, not copied: gone from the source, and Storage=journal archived nothing.
        left = machine.succeed("find /tmp/pstore -type f")
        assert left == "", left
        machine.wait_until_succeeds(
            "journalctl -b --all -o cat --output-fields=FILE 'MESSAGE=PStore dmesg-ramoops-0.'"
            " | grep -qx crash-recovery-marker",
            timeout=60,
        )

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

    with subtest("an oops panics the kernel, which reboots"):
        machine.start()
        machine.wait_for_unit("multi-user.target")
        since = len(machine.get_console_log())
        # In the background and after a moment, so the backdoor's reply is out before the kernel
        # goes. Without oops=panic the kernel would only kill this modprobe and carry on.
        machine.succeed("(sleep 2; modprobe crash_recovery_oops) >/dev/null 2>&1 &")
        wait_console(machine, since, r"kernel BUG at", 120)
        rebooted_from_panic(machine, since, "Fatal exception")
  '';
}
