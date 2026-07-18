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

  hardware.bluetooth.enable = true;

  services.blueman.enable = true;
  services.fwupd.enable = true;
  services.power-profiles-daemon.enable = true;
  services.printing.enable = true;
  services.upower.enable = true;
}
