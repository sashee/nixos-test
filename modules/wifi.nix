# Spec: wifi power save is off (spec/features/wifi.md), on every host.
#
# Both stacks are set unconditionally: each key is inert unless its daemon runs, so a host that
# switches stack -- or runs NetworkManager on its iwd backend, which ignores NM's own powersave
# key -- stays covered without a per-host line. Guarded by the <host>-wifi checks.
{
  # iwd (rpi5): iwd disables power save itself on every interface it brings up, at startup and
  # whenever the netdev reappears (e.g. after a brcmfmac firmware reset). A glob rather than
  # "brcmfmac", so the setting follows the spec instead of the Pi's current chip.
  networking.wireless.iwd.settings.DriverQuirks.PowerSaveDisable = "*";

  # NetworkManager (laptops): the global default for every profile that leaves wifi.powersave
  # at "default" -- i.e. every network joined from the Plasma GUI. Applied on each activation.
  networking.networkmanager.wifi.powersave = false;
}
