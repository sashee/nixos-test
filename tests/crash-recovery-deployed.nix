# Eval-only guard on the half of modules/crash-recovery.nix that the deployed Pi gets from its
# firmware, which tests/crash-recovery.nix cannot see: its nodes compose rpi5HostModules
# without nixos-raspberrypi, so they have no config.txt and no cmdline.txt.
#
#   * THE RAMOOPS OVERLAY (hosts/rpi5/firmware.nix). Without it the crash-recovery reboots work
#     but leave nothing behind: no pstore backend, so nothing for systemd-pstore to move into the
#     journal. Nothing on the running Pi would say so, because an empty /sys/fs/pstore is also
#     what a host that never crashed looks like.
#   * THE BOOT PARAMETERS on the deployed config, which the firmware passes on through
#     cmdline.txt. The VM test reads /proc/cmdline, but of a config without the nixos-raspberrypi
#     modules, so a `panic=` from there would get past it.
#   * WHAT ARMS PANIC-ON-OOPS. The VM test starts the reachable target by hand, because it has no
#     tunnel; tests/iroh-ssh.nix proves the failsafe starts it. That leaves the link between
#     the two: the Pi has to name that target and run that failsafe, or panic_on_oops is never
#     armed and nothing says so.
#
# Sizes are spelled out as the spec states them (spec/rpi-features.md, "Auto-reboot"), not read
# back from hosts/rpi5/firmware.nix, so that a change to one has to be made in the other too.
# Fails with `throw` during evaluation, like tests/thingspeak-deployed.nix.
{ pkgs, hosts }:

let
  lib = pkgs.lib;
  config = hosts.rpi5.config;

  kib = n: n * 1024;
  consoleSize = kib 128;
  recordSize = kib 16;
  records = 4;

  # nixos-raspberrypi renders an overlay as its dtoverlay= line, one dtparam= per parameter in
  # attribute-name order, and an empty dtoverlay= that ends it.
  expectedOverlay = [
    "dtoverlay=ramoops-pi5"
    "dtparam=console-size=${toString consoleSize}"
    "dtparam=record-size=${toString recordSize}"
    "dtparam=total-size=${toString (consoleSize + records * recordSize)}"
    "dtoverlay="
  ];

  lines = map lib.trim (lib.splitString "\n" config.hardware.raspberry-pi.config-generated);
  start = lib.lists.findFirstIndex (l: l == builtins.head expectedOverlay) null lines;
  block = lib.sublist start (builtins.length expectedOverlay) lines;
  # The [filter] section the overlay sits in: the last one opened before it.
  section = lib.findFirst (lib.hasPrefix "[") null (lib.reverseList (lib.take start lines));

  overlayErrors =
    if start == null then
      [ "config.txt has no ${builtins.head expectedOverlay} at all" ]
    else
      lib.optional (block != expectedOverlay)
        "config.txt renders the overlay as [ ${toString block} ], expected [ ${toString expectedOverlay} ]"
      ++ lib.optional (section != "[all]")
        "config.txt puts the overlay under ${toString section}, so a Pi 5 may never load it; expected [all]";

  params = config.boot.kernelParams;
  expectedParams = [ "panic=10" "boot.panic_on_fail" "systemd.crash_action=reboot" ];
  panics = lib.filter (lib.hasPrefix "panic=") params;

  paramErrors =
    map (p: "the kernel command line lacks ${p}") (lib.subtractLists params expectedParams)
    ++ lib.optional (panics != [ "panic=10" ])
      "the kernel command line has ${toString panics}; the kernel takes the last panic=, so exactly one, panic=10, is expected"
    ++ lib.optional (lib.elem "oops=panic" params)
      "the kernel command line has oops=panic, so an oops panics from the start of the boot; it must panic only from 10 minutes after ssh first answers through the tunnel";

  answeredTarget = "iroh-ssh-answered.target";
  armingErrors =
    lib.optional (config.common.crashRecovery.reachableTarget != answeredTarget)
      "common.crashRecovery.reachableTarget is ${config.common.crashRecovery.reachableTarget}, expected ${answeredTarget}"
    ++ lib.optional (!(config.systemd.targets ? ${lib.removeSuffix ".target" answeredTarget}))
      "${answeredTarget} is not defined"
    ++ lib.optional (!(config.systemd.services ? iroh-ssh-failsafe))
      "iroh-ssh-failsafe.service, the only thing that starts ${answeredTarget}, is not enabled";

  errors = overlayErrors ++ paramErrors ++ armingErrors;
in
if errors != [ ] then
  throw ''
    The deployed rpi5 crash recovery does not match the spec.

      ${lib.concatStringsSep "\n  " errors}

    None of these show on the running Pi. The overlay is what makes a crash leave a trace:
    missing, or with console-size 0 (the overlay's default), a reboot from the hardware watchdog
    leaves no log anywhere. And a panic_on_oops that is never armed looks the same as one that
    is, until an oops.
  ''
else
  pkgs.runCommand "crash-recovery-deployed-check" { } ''
    echo "ramoops overlay, boot parameters and panic-on-oops arming verified on rpi5" > $out
  ''
