{ config, lib, pkgs, ... }:

# Report the devices this host can see -- attached over USB, or detected over WiFi and Bluetooth.
#
# A separate producer from `common.systemMetrics` rather than more measurement types inside it. The
# two answer different questions and want different switches: system metrics are a passive read of
# this host's own state, while these are an inventory of hardware and of radio neighbours. Only some
# hosts should collect the latter at all, and the radio half records third parties -- neighbouring
# SSIDs and BSSIDs, other people's phones -- which is a decision to take per host rather than a side
# effect of turning metrics on.
#
# Each collector has its own enable, following the `smart` / `irohFailsafe` pattern in
# system-metrics.nix: the binary treats a missing tool flag as "do not collect this", so an
# off-by-default collector costs nothing and tightens the sandbox with it.

let
  cfg = config.common.detectedDevices;

  collectArgs =
    [ "--socket" cfg.socketPath ]
    ++ lib.optionals cfg.usb.enable [ "--usb-devices-root" cfg.usb.devicesRoot ]
    ++ lib.optionals cfg.wifi.enable [
      "--wifi-interface"
      cfg.wifi.interface
      "--iw"
      (lib.getExe' cfg.wifi.package "iw")
    ]
    ++ lib.optionals cfg.bluetooth.enable [
      "--bluetooth-adapter"
      cfg.bluetooth.adapter
      "--bluetooth-sysfs-root"
      cfg.bluetooth.sysfsRoot
      "--btmon"
      (lib.getExe' cfg.bluetooth.package "btmon")
      "--bluetoothctl"
      (lib.getExe' cfg.bluetooth.package "bluetoothctl")
      "--ble-scan-seconds"
      (toString cfg.bluetooth.scanSeconds)
      "--ble-scan-interval-ms"
      (toString cfg.bluetooth.scanIntervalMs)
      "--ble-scan-window-ms"
      (toString cfg.bluetooth.scanWindowMs)
    ];
in
{
  options.common.detectedDevices = {
    enable = lib.mkEnableOption "reporting attached and detected devices to a local monitoring-platform receiver";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../packages/detected-devices/package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ../packages/detected-devices/package.nix { }";
      description = "The producer binary to run.";
    };

    socketPath = lib.mkOption {
      type = lib.types.str;
      example = "/run/mp-collector/mp-collector.sock";
      description = ''
        Unix socket to post to. Hosts should wire this from
        `services.mp-collector.socketPath`, exactly as
        [](#opt-common.systemMetrics.socketPath) does, so the receiver's location is stated once
        per host rather than restated per producer.
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      example = "mp-collector";
      description = "Group owning the socket, joined as a supplementary group.";
    };

    timerConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        OnBootSec = "5min";
        OnUnitActiveSec = "15min";
      };
      description = ''
        When to collect. `OnUnitActiveSec` is the spec's "every 15 minutes"; the `OnBootSec` leg is
        only what gives the timer a first trigger, since a timer with neither `OnBootSec` nor
        `OnCalendar` never fires at all.

        Note what the cadence costs on hosts with the radio collectors on. A WiFi sweep takes the
        radio off-channel for several seconds: measured on the Pi it moved the host's own RTT from
        1.4 ms to 133 ms peak, on the link its remote access runs over. Both radios also share one
        antenna, so the BLE scan costs the WiFi link too.
      '';
    };

    usb = {
      enable = lib.mkEnableOption "reporting attached USB devices and hub ports";

      devicesRoot = lib.mkOption {
        type = lib.types.path;
        default = "/sys/bus/usb/devices";
        description = ''
          Directory of USB devices to sweep.

          Redirectable so a VM test can point it at a fixture tree: a guest's USB tree is a root
          hub and nothing else, so the shapes worth asserting on are exactly the ones a guest
          lacks -- a nested hub, an unconfigured device, and a port holding a device that never
          enumerated (which has a port directory but no device directory at all).
        '';
      };
    };

    wifi = {
      enable = lib.mkEnableOption "scanning for nearby WiFi networks";

      interface = lib.mkOption {
        type = lib.types.str;
        default = "wlan0";
        description = "Wireless interface to scan on.";
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.iw;
        defaultText = lib.literalExpression "pkgs.iw";
        description = ''
          Provides `iw`, which is used rather than a manager's own CLI because it is the only tool
          present under both wireless managers this fleet runs: `iwctl` exists on the Pi and
          `nmcli` on the laptops, but both iwd and NetworkManager are nl80211 clients and `iw`
          talks nl80211 directly. Its output is also the only one carrying the information
          elements a `wifi_bss` record needs.
        '';
      };
    };

    bluetooth = {
      enable = lib.mkEnableOption "scanning for nearby Bluetooth LE devices";

      adapter = lib.mkOption {
        type = lib.types.str;
        default = "hci0";
        description = "HCI adapter to scan on.";
      };

      sysfsRoot = lib.mkOption {
        type = lib.types.path;
        default = "/sys/class/bluetooth";
        description = ''
          Where HCI adapters appear. An absent adapter is reported as
          `skipped_reason = "no-adapter"` rather than attempted, so this is redirectable for the
          same reason [](#opt-common.detectedDevices.usb.devicesRoot) is: a QEMU guest has no
          Bluetooth controller at all, and without a fixture every assertion about a device row
          would be vacuous.
        '';
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.bluez;
        defaultText = lib.literalExpression "pkgs.bluez";
        description = "Provides `btmon` and `bluetoothctl`.";
      };

      scanSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 10;
        description = "How long to listen for advertisements.";
      };

      scanIntervalMs = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1280;
        description = ''
          LE scan interval. Together with
          [](#opt-common.detectedDevices.bluetooth.scanWindowMs) this is the duty cycle, and it is
          pinned rather than inherited: BlueZ's own default is window == interval == 11.25 ms, i.e.
          the radio listens continuously, which starves any active connection on the controller.
          The defaults here are ~1%.
        '';
      };

      scanWindowMs = lib.mkOption {
        type = lib.types.ints.positive;
        default = 11;
        description = "LE scan window. See [](#opt-common.detectedDevices.bluetooth.scanIntervalMs).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.group != "";
        message = "common.detectedDevices.group must name the socket's owning group.";
      }
      {
        # Every tick would fail against a socket nothing is serving. Only checkable where the
        # collector's module is in the imports list at all, hence the `?` guard.
        assertion = !(config.services ? mp-collector)
          || config.services.mp-collector.enable
          || cfg.socketPath != config.services.mp-collector.socketPath;
        message = ''
          common.detectedDevices posts to ${cfg.socketPath}, but services.mp-collector.enable is
          false on this host. Enable the collector, point common.detectedDevices.socketPath at
          another receiver, or disable common.detectedDevices.
        '';
      }
      {
        assertion = cfg.usb.enable || cfg.wifi.enable || cfg.bluetooth.enable;
        message = ''
          common.detectedDevices is enabled but every collector is off, so each run would post an
          empty batch. Enable at least one of usb, wifi or bluetooth.
        '';
      }
      {
        # bluetoothctl drives the scan over D-Bus, so bluetoothd has to be running. Without this
        # the collector would report controller-busy on every tick and look like a radio fault.
        assertion = !cfg.bluetooth.enable || config.hardware.bluetooth.enable;
        message = ''
          common.detectedDevices.bluetooth needs hardware.bluetooth.enable: the scan is driven
          through bluetoothd, and without it every run reports skipped_reason=controller-busy.
        '';
      }
    ];

    systemd.services.detected-devices = {
      description = "Report attached and detected devices to the local monitoring platform";
      after = [ "mp-collector.socket" ] ++ lib.optional cfg.bluetooth.enable "bluetooth.service";

      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.escapeShellArgs ([ (lib.getExe cfg.package) ] ++ collectArgs);

        # No identity of its own and no state; the one privilege it needs is membership of the
        # receiver's group, which is what gates the socket.
        DynamicUser = true;
        SupplementaryGroups = [ cfg.group ];

        # Long enough for a WiFi sweep (~6 s measured) plus the whole BLE listen window, with room
        # for a slow SD card, and short enough to kill a wedged run before the next tick.
        TimeoutStartSec = "${toString (cfg.bluetooth.scanSeconds + 120)}s";

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        # A scan is a privileged nl80211 operation even though it changes nothing, and it is
        # granted only when that collector is on, so the default sandbox is unchanged.
        # A scan is a privileged nl80211 operation even though it changes nothing, and btmon needs
        # CAP_NET_RAW to bind the HCI monitor channel -- without it it fails with "Failed to bind
        # channel: Operation not permitted" and the capture comes back empty, which is
        # indistinguishable from a quiet neighbourhood. Each is granted only where its collector is
        # on, so the default sandbox is unchanged.
        CapabilityBoundingSet = lib.optional cfg.wifi.enable "CAP_NET_ADMIN"
          ++ lib.optional cfg.bluetooth.enable "CAP_NET_RAW";
        AmbientCapabilities = lib.optional cfg.wifi.enable "CAP_NET_ADMIN"
          ++ lib.optional cfg.bluetooth.enable "CAP_NET_RAW";
        ProtectHome = true;
        PrivateTmp = true;
        # NOT PrivateDevices: btmon opens the HCI monitor channel, and a private /dev would leave
        # the Bluetooth collector reporting an adapter that is present as absent.
        PrivateDevices = !cfg.bluetooth.enable;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        # Hides other processes, which this unit never reads. Not ProcSubset = "pid": the USB sweep
        # reads /sys, and /proc/sys/kernel/hostname is a resource attribute.
        ProtectProc = "invisible";
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallFilter = [ "@system-service" ];
        SystemCallArchitectures = "native";
        # AF_UNIX for the receiver's socket and the system bus bluetoothctl uses; AF_NETLINK is
        # what nl80211 rides for the WiFi scan; AF_BLUETOOTH is btmon's monitor channel. Each is
        # allowed only where the collector needing it is on.
        RestrictAddressFamilies = [ "AF_UNIX" ]
          ++ lib.optional cfg.wifi.enable "AF_NETLINK"
          ++ lib.optional cfg.bluetooth.enable "AF_BLUETOOTH";
      };
    };

    systemd.timers.detected-devices = {
      wantedBy = [ "timers.target" ];
      timerConfig = cfg.timerConfig // { Unit = "detected-devices.service"; };
    };
  };
}
