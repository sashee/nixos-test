{
  networking.networkmanager.enable = true;

  # Read the CMOS RTC in the initrd. nixpkgs builds rtc_cmos as a module and it
  # is not in the default initrd, so it otherwise loads in stage-2: the clock
  # sits at systemd's build epoch through early boot and then jumps forward when
  # the driver loads, racing timers/services that armed in the meantime (and
  # firing overdue daily timers). Loading it in the initrd sets the clock before
  # stage-2 starts. Guarded by the per-host boot-clock test.
  boot.initrd.availableKernelModules = [ "rtc_cmos" ];

  hardware.enableRedistributableFirmware = true;
  hardware.cpu.intel.updateMicrocode = true;
  hardware.cpu.amd.updateMicrocode = true;

  zramSwap.enable = true;

  # Byte-based dirty-page writeback thresholds, replacing the kernel's
  # RAM-proportional dirty_ratio/dirty_background_ratio defaults (20%/10%).
  # Setting either byte knob zeroes its ratio counterpart, so these become the
  # authoritative limits: writeback starts at 64 MiB of dirty pages and writers
  # block at 256 MiB, instead of letting GBs of dirty pages accumulate on a
  # 16-32 GB laptop and then stall in one burst. A host overrides with
  # lib.mkForce (as anya-feher-laptop already does for bluetooth).
  boot.kernel.sysctl = {
    "vm.dirty_bytes" = 268435456;             # 256 MiB
    "vm.dirty_background_bytes" = 67108864;   #  64 MiB
  };

  hardware.bluetooth.enable = true;

  services.blueman.enable = true;
  services.fwupd.enable = true;
  services.power-profiles-daemon.enable = true;
  services.printing.enable = true;
  services.upower.enable = true;
}
