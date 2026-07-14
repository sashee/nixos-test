{ nixpkgs, pkgs, stateVersion, moduleUnderTest }:

# Concept test: run the module's PRODUCTION timer constants (bootGrace=5min,
# setupTimeout=10min -- deliberately NOT overridden here) in seconds of wall time
# via QEMU icount. `-icount shift=auto,sleep=off` derives the guest clock from
# executed instructions and, whenever the guest is idle, warps the virtual clock
# to the next timer deadline instead of sleeping in real time. Monotonic timers
# (OnBootSec, systemd-run --on-active) -- which no wall-clock trick can reach --
# fire at their real deadlines almost for free. TCG-only (no KVM), so busy phases
# (boot) run slow; the payoff is that idle waits cost nothing.
#
# Timing-sensitive scripting rule: ANY idle gap between driver commands warps the
# clock, potentially past the next boundary (the +15min safety reboot). So the
# script synchronizes with guest-side blocking sleeps and compound one-liners,
# and never polls across a boundary.
let
  fakeIwctl = pkgs.writeShellScriptBin "iwctl" ''
    echo "iwctl $*" >> /tmp/iwctl.log
    exit 0
  '';
  fakeIw = pkgs.writeShellScriptBin "iw" ''
    echo "iw $*" >> /tmp/iw.log
    exit 0
  '';
in
nixpkgs.lib.nixos.runTest {
  name = "connectivity-fallback-timing";
  hostPkgs = pkgs;

  nodes.machine = { config, lib, pkgs, ... }: {
    imports = [ moduleUnderTest ];

    networking.hostName = "nixos-rpi5";
    networking.wireless.iwd.enable = true;
    systemd.services.iwd.wantedBy = lib.mkForce [ ];

    common.connectivityFallback = {
      enable = true;
      # eth1 exists in the VM, so the AP-side services come up cleanly; the radio
      # is mocked as in the main test. bootGrace/setupTimeout/connectivityCheck
      # stay at PRODUCTION defaults -- that is the point of this test (the default
      # check URL is unreachable in the sandbox, so the machine is offline).
      interface = "eth1";
      tools.iwd = fakeIwctl;
      tools.iw = fakeIw;
    };

    virtualisation.qemu.options = [
      # Override the base accel=kvm:tcg -- icount requires TCG (later -machine
      # keys win over earlier ones).
      "-machine accel=tcg"
      # Guest clock from instruction count; warp over idle instead of sleeping.
      "-icount shift=auto,sleep=off"
      # RTC follows the virtual clock; base per repo convention (see testRtcBase).
      "-rtc clock=vm,base=$(${pkgs.coreutils}/bin/date -u -d tomorrow +%Y-%m-%dT10:00:00)"
    ];

    system.stateVersion = stateVersion;
  };

  testScript = ''
    import time

    machine.start()
    machine.wait_for_unit("multi-user.target")
    boot_uptime = float(machine.succeed("cut -d' ' -f1 /proc/uptime"))
    t0 = time.monotonic()

    with subtest("production OnBootSec=5min fires at its real deadline"):
        # Guest-side blocking sleep to past the +300s boundary (the setup script
        # itself sleeps ~3s after the check fires, so probe at 320): while the
        # guest sleeps, the warp delivers the check timer at exactly 300s. The
        # status queries ride in the same command -- no idle gap to warp through.
        out = machine.succeed(
            "sleep \"$(awk '{d=320-$1; print (d<1)?1:d}' /proc/uptime)\"; "
            "systemctl is-active connectivity-fallback-setup.service || true; "
            "systemctl show connectivity-fallback-check.service "
            "-p ExecMainExitTimestampMonotonic --value"
        )
        state, check_exit_us = out.split()
        assert state == "active", out
        check_exit = int(check_exit_us) / 1e6
        assert 295 <= check_exit <= 330, f"check finished at monotonic {check_exit}s"

    with subtest("production setupTimeout=10min really reboots; warp makes it cheap"):
        # ~600 further virtual seconds with zero driver interaction.
        machine.wait_for_shutdown()
        wall = time.monotonic() - t0
        virtual = 905 - boot_uptime  # reboot lands at guest uptime ~905s
        machine.log(
            f"boot reached multi-user at guest uptime {boot_uptime:.0f}s; "
            f"then ~{virtual:.0f}s virtual took {wall:.0f}s wall"
        )
        # The icount certificate: the virtual span must cost far less wall time
        # than real time (a non-warping run would need >= `virtual` seconds).
        assert wall < 300, f"warp too slow: {wall:.0f}s wall for {virtual:.0f}s virtual"
  '';
}
