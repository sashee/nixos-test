{ config, lib, pkgs, ... }:

# Recovery from the failures a network watchdog cannot see because the box itself is gone:
# a hung or crashed PID 1, a hung kernel, a kernel panic or oops, a boot that stops before it
# is reachable.
# spec/rpi-features.md, "Auto-reboot". Every remedy is a reboot, because the hosts this is for
# are headless and nobody is there to do anything else.
#
# What is NOT here, on purpose:
#
#  * The crash-log buffer (ramoops). It is a device-tree overlay, so it lives with the rest of
#    config.txt in hosts/rpi5/firmware.nix. This module only decides where a saved log goes.
#  * hung_task_panic. A task blocked past hung_task_timeout_secs (120s) is normal on the
#    Pi: SD writeback stalls fsync for 20-150s during builds. Panicking on it would reboot
#    the box in the middle of the nightly upgrade.
#  * The bootloader stage. Nothing here can recover a firmware that fails to load the kernel;
#    that needs the EEPROM's BOOT_WATCHDOG_TIMEOUT, which the deployed bootloader predates.
let
  cfg = config.common.crashRecovery;

  # Hardcoded, not options: the spec fixes both, and nothing in the repo needs them different.
  #
  # The watchdog timeout is generous because a spurious reset mid-upgrade costs more than a slow
  # recovery from a real hang. PID 1 pings at half of it, from its event loop, and that loop
  # can stall on memory pressure: on the Pi the SD stalls fsync for 20-150s, and the
  # connectivity-watchdog has already seen a probe hang under memory pressure.
  watchdogTimeout = "2min";
  panicRebootSeconds = 10;
  # How long after the host is first reachable an oops starts to panic the kernel. It is the
  # window an operator gets, on every turn of a crash loop, to get in and stop it.
  oopsPanicDelay = "10min";
  oopsPanicUnit = "crash-recovery-panic-on-oops";
  # While it exists, nothing arms panic-on-oops again. In /run, so a reboot clears it.
  oopsPanicOffFlag = "/run/crash-recovery-oops-panic-off";
  sysctl = "${pkgs.procps}/bin/sysctl";
in
{
  options.common.crashRecovery = {
    enable = lib.mkEnableOption ''
      rebooting the host when PID 1 hangs or crashes, the kernel hangs, panics or oopses, or the
      initrd fails, and keeping the boot going past a failed mount after it
    '';

    reachableTarget = lib.mkOption {
      type = lib.types.str;
      example = "iroh-ssh-answered.target";
      description = ''
        The unit that starts the first time in a boot that the host is remotely reachable. A
        kernel oops panics the kernel only from ${oopsPanicDelay} after it starts, so in a boot where
        it never starts, an oops never does.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # The initrd half (its own watchdog, and panic_on_fail via panic-on-fail.service) is
        # built on systemd in the initrd.
        assertion = config.boot.initrd.systemd.enable;
        message = "common.crashRecovery needs boot.initrd.systemd.enable: the initrd watchdog and the initrd panic-on-failure are systemd-initrd features.";
      }
    ];

    # The hardware watchdog. PID 1 arms it at startup and pings it from its main loop, so a hang
    # of PID 1 or the kernel stops the pings and the hardware resets the board. A *crashed*
    # PID 1 is systemd.crash_action's job, below.
    #
    # Both managers, because each one only covers its own lifetime: systemd disarms the
    # watchdog on switch-root (the new instance re-arms it), and without the initrd's own
    # setting nothing would be watching until the real root's PID 1 starts. Arming it in the
    # initrd is safe only because of boot.panic_on_fail below: otherwise an initrd stuck in
    # emergency mode would keep PID 1 alive and pinging forever.
    systemd.settings.Manager.RuntimeWatchdogSec = watchdogTimeout;
    boot.initrd.systemd.settings.Manager.RuntimeWatchdogSec = watchdogTimeout;

    # Boot parameters rather than the kernel.panic sysctl: systemd-sysctl applies it only in
    # stage 2, so a panic in the initrd would hang until power-cycled. kernel.panic_on_oops is
    # the exception, below.
    boot.kernelParams = lib.mkMerge [
      [
        # An initrd that reaches emergency mode crashes the kernel on purpose (nixpkgs'
        # panic-on-fail.service, wanted by the initrd's emergency.target), and panic= reboots
        # it. Root login is locked in the initrd, so that emergency mode is otherwise a dead end.
        "boot.panic_on_fail"
        # A crashed PID 1 (SIGSEGV, SIGABRT, ...) reboots itself 10s later instead of the default
        # freeze, which leaves services running with nothing managing them. A boot parameter
        # so the initrd's PID 1 gets it too. It is not left to the watchdog: when PID 1 freezes
        # it closes the device, and once the initrd has armed and then disarmed the watchdog,
        # that close stops the watchdog instead of letting it fire. (The disarm is a magic
        # close. The kernel keeps its "magic char seen" flag until the next write(), and
        # systemd only pings with ioctl(), so the flag is still set when the frozen PID 1
        # closes. Verified in a VM 2026-10-15: with the initrd's arming, a SIGSEGV'd PID 1
        # froze and the watchdog never fired. A hung PID 1 keeps the device open and is still
        # reset.)
        "systemd.crash_action=reboot"
      ]
      # mkAfter because the kernel takes the LAST panic= it is given, so this must come after
      # anyone else's. NixOS's test instrumentation, for one, passes panic=1 to every test VM.
      (lib.mkAfter [ "panic=${toString panicRebootSeconds}" ])
    ];

    # An oops kills only the task that hit it; the kernel carries on tainted, possibly with a lock
    # that task held, so a headless box is better off rebooted into a known state. But not from
    # the start of the boot, as oops=panic would: an oops that recurs on every boot would then
    # reboot the box in a loop that never reaches the network, and nobody can get to the box to
    # break it. So panic_on_oops is set only ${oopsPanicDelay} after the host was first reachable
    # in this boot. An oops before that leaves the box up, tainted but reachable. One after it
    # still loops, but every turn passes through ${oopsPanicDelay} in which an operator can get in
    # and stop it for the rest of that boot:
    #
    #   touch ${oopsPanicOffFlag} && systemctl stop ${oopsPanicUnit}.service
    #
    # The stop disarms; the flag keeps anything from arming it again, the timer included if it
    # has not fired yet. Not `systemctl mask`: a persistent mask fails because
    # /etc/systemd/system is a store path, and a --runtime one is silently ignored, because
    # NixOS keeps every unit in /etc/systemd/system, which outranks /run/systemd/system where
    # runtime masks go (seen in tests/crash-recovery.nix).
    #
    # An oops that stops the boot before the host is reachable is the watchdogs' case: the
    # hardware one if PID 1 is stuck behind it, connectivity-watchdog if the network never
    # comes up.
    systemd.timers.${oopsPanicUnit} = {
      description = "Make a kernel oops panic, ${oopsPanicDelay} after the host was first reachable";
      wantedBy = [ cfg.reachableTarget ];
      timerConfig.OnActiveSec = oopsPanicDelay;
    };
    systemd.services.${oopsPanicUnit} = {
      description = "Kernel oops panics the kernel";
      # Active exactly while armed, so stopping it is disarming it. That includes the stop at
      # shutdown; a shutdown that an oops hangs is the reboot watchdog's (RebootWatchdogSec).
      unitConfig.ConditionPathExists = "!${oopsPanicOffFlag}";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${sysctl} -w kernel.panic_on_oops=1";
        ExecStop = "${sysctl} -w kernel.panic_on_oops=0";
      };
    };

    # After the initrd, a failed mount must not stop the boot at a console login no one can
    # reach. Without emergency.target, local-fs.target's OnFailure= has nothing to start and
    # the boot carries on to multi-user, degraded but reachable over the network.
    systemd.enableEmergencyMode = false;

    # Crash logs saved by a pstore backend (ramoops on the Pi) go into the journal on the next
    # boot and are then cleared from pstore. systemd-pstore always journals the log; the
    # default Storage=external would also keep a copy under /var/lib/systemd/pstore, and
    # nixpkgs does not install upstream's 14-day cleanup rule for it. With Storage=journal the
    # journal's own size cap and rotation are the only retention.
    environment.etc."systemd/pstore.conf".text = ''
      [PStore]
      Storage=journal
    '';
    # The journal is then the only copy, and the RAM one is cleared right after the hand-off. So
    # the log must reach the SD card before a second crash can take it: upstream's unit is not
    # ordered after journald's move from /run to /var (in a VM it ran in the middle of it), and
    # journald only syncs an ordinary entry SyncIntervalSec (5min) later. Without these, a box
    # crash-looping within minutes of boot never keeps the log of the crash that loops it.
    systemd.services.systemd-pstore = {
      after = [ "systemd-journal-flush.service" ];
      serviceConfig.ExecStartPost = "${config.systemd.package}/bin/journalctl --sync";
    };
  };
}
