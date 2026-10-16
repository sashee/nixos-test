# config.txt settings for the deployed Pi. Only mkRpi5 (flake.nix) imports this, next to
# nixos-raspberrypi's raspberry-pi-5.base: that module declares hardware.raspberry-pi.*, and the
# test nodes compose rpi5HostModules without it because a VM has no firmware to read config.txt.
# What this renders is guarded by tests/crash-recovery-deployed.nix instead.
{ ... }:

let
  kib = n: n * 1024;
  # spec/rpi-features.md, "Auto-reboot". The console buffer is the kernel log leading up to a
  # reset. Without it a hang that the hardware watchdog resets leaves no trace at all, because
  # only panics and oopses write dump records. 128 KiB is about a day of this host's steady-state
  # kernel log, which is ~20 firewall "refused connection" lines an hour, or a whole boot (~60 KiB).
  consoleSize = kib 128;
  # Each panic/oops dump is one record, and an oops once panic_on_oops is armed writes two: the
  # oops, then the panic. Four slots hold two crashes. Records are compressed (CONFIG_PSTORE_COMPRESS),
  # so 16 KiB carries more log than its size suggests.
  recordSize = kib 16;
  records = 4;
in
{
  # Crash logs that survive the reset: the Pi 5 variant of the ramoops overlay reserves this much
  # RAM at a fixed address, the kernel writes the logs into it, and on the next boot
  # systemd-pstore moves them into the journal (modules/crash-recovery.nix sets Storage=journal).
  hardware.raspberry-pi.config.all.dt-overlays.ramoops-pi5 = {
    enable = true;
    params = {
      total-size = { enable = true; value = consoleSize + records * recordSize; };
      record-size = { enable = true; value = recordSize; };
      console-size = { enable = true; value = consoleSize; };
    };
  };
}
