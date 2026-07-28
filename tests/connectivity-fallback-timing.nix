{ nixpkgs, pkgs, stateVersion, machineModule, rtcOption }:

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
#
# machineModule is the system under test: the aarch64 variant passes the REAL rpi config
# (hosts/rpi5 on the Pi kernel), so the production constants run against the deployed
# stack. `rtcOption` is a parameter rather than a literal because this node must own the
# ONLY -rtc flag on the QEMU command line: it needs `clock=vm` (so the RTC follows the
# virtual clock), and virtualisation.qemu.options is a list, so a node that also picked up
# the shared `-rtc base=...` helper would emit two -rtc options whose merge order is
# undefined. The caller therefore supplies the whole flag, including the tomorrow-10:00
# base every test in this repo uses.
#
# Anything that wakes the guest periodically defeats this test: the warp only skips time
# while the guest is idle. The rpi variant forces off common.irohSsh.failsafe for that
# reason (see flake.nix) -- worth remembering before adding another polling unit to the
# node.
let
  fakeIwctl = pkgs.writeShellScriptBin "iwctl" ''
    echo "iwctl $*" >> /tmp/iwctl.log
    exit 0
  '';
  # `link` must answer "Not connected." explicitly rather than staying silent. The check
  # treats a NON-ZERO exit from iw as "the radio is unusable, do not enter setup mode"
  # (see modules/connectivity-fallback.nix), so a fake that failed -- or that a future
  # `set -o pipefail`-ish change made fail -- would swallow the trigger, and the
  # safety-net-reboot assertion below would never fire while the test still looked like
  # it was exercising the production constants. Other subcommands (`iw reg set`, from the
  # setup script) just get logged.
  fakeIw = pkgs.writeShellScriptBin "iw" ''
    echo "iw $*" >> /tmp/iw.log
    if [ "''${3-}" = "link" ]; then
      echo "Not connected."
    fi
    exit 0
  '';
in
nixpkgs.lib.nixos.runTest {
  name = "connectivity-fallback-timing";
  hostPkgs = pkgs;

  nodes.machine = { config, lib, pkgs, ... }: {
    imports = [ machineModule ];

    networking.hostName = "nixos-rpi5";
    networking.wireless.iwd.enable = true;
    systemd.services.iwd.wantedBy = lib.mkForce [ ];

    common.connectivityFallback = {
      enable = true;
      # eth1 exists in the VM, so the AP-side services come up cleanly; the radio
      # is mocked as in the main test. bootGrace/setupTimeout/association all stay at
      # PRODUCTION defaults -- that is the point of this test. The sampling loop is
      # deliberately NOT shortened: a guest blocked on `sleep 10` is idle, so icount
      # warps over it for almost no wall time, and running the real sample count is
      # what makes this test cover the check completing inside its TimeoutStartSec --
      # past that the check would be SIGTERMed before it ever reaches
      # `systemctl start ... setup.service`, and a host with no wifi would silently
      # never enter setup mode. TimeoutStartSec is derived from the same two options,
      # so this is the test that the derivation leaves usable headroom.
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
      # RTC follows the virtual clock; base per repo convention (see testRtcBase). Supplied
      # by the caller so this stays the only -rtc on the command line (see header).
      rtcOption
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
        # Guest-side blocking sleep past the +300s boundary AND past the sampling loop:
        # while the guest sleeps, the warp delivers the check timer at exactly 300s.
        # The status queries ride in the same command -- no idle gap to warp through.
        #
        # Probe instant = 300 (OnBootSec) + 50 (the production sampling window:
        # (association.samples - 1) x association.intervalSeconds) + ~3 (the setup
        # script's own two sleeps) + margin = 380. Raising either association option
        # eats that margin. The next boundary is the safety-net reboot at ~955s, so
        # there is ample room above.
        #
        # That target only bites on boots that reach multi-user before ~380s. Above it the
        # awk clamps to `sleep 1` and the driver simply reads state after boot, which is
        # the regime the x86 variant is actually in (387s boot measured) -- so the 380 is
        # inert there and the arithmetic above did not apply to the numbers quoted further
        # down. Both assertions still hold either way; the number is worth leaving as the
        # documented deadline rather than tuning, since it is what makes the fast-boot case
        # synchronize instead of warping past the boundary.
        out = machine.succeed(
            "sleep \"$(awk '{d=380-$1; print (d<1)?1:d}' /proc/uptime)\"; "
            "systemctl is-active connectivity-fallback-setup.service || true; "
            # One property per call: `systemctl show` with several -p flags gives no
            # documented output order. Both queries ride in this same command, so there
            # is still no idle gap for the clock to warp through.
            "systemctl show connectivity-fallback-check.service "
            "-p ExecMainStartTimestampMonotonic --value; "
            "systemctl show connectivity-fallback-check.service "
            "-p ExecMainExitTimestampMonotonic --value"
        )
        state, check_start_us, check_exit_us = out.split()
        check_start = int(check_start_us) / 1e6
        check_exit = int(check_exit_us) / 1e6
        machine.log(
            f"check ran {check_start:.1f}s..{check_exit:.1f}s monotonic "
            f"({check_exit - check_start:.1f}s in the sampling loop); "
            f"setup.service is {state}"
        )
        assert state == "active", out
        # Two independent properties, asserted separately so a failure says which one
        # broke: the monotonic timer fired at its real 300s deadline, and the production
        # sampling loop takes the time the options say it should while staying inside the
        # check service's derived TimeoutStartSec (window + 30s).
        #
        # Bounded on BOTH sides. The upper bound is the TimeoutStartSec headroom. The
        # lower bound is the one that carries weight: the whole point of sampling is that
        # a momentary flap cannot trigger setup mode, and a check that returned in 2s
        # would have skipped the waiting entirely while every other assertion here still
        # passed. Expected 50s ((6 - 1) x 10s); the slack absorbs process-spawn overhead
        # under TCG and systemd's 1s AccuracySec.
        assert 295 <= check_start <= 305, f"check started at monotonic {check_start}s"
        sampling_loop = check_exit - check_start
        assert 45 <= sampling_loop <= 70, f"sampling loop took {sampling_loop}s"

    with subtest("production setupTimeout=10min really reboots; warp makes it cheap"):
        # ~600 further virtual seconds with zero driver interaction.
        machine.wait_for_shutdown()
        wall = time.monotonic() - t0
        # The safety-net reboot is scheduled (systemd-run --on-active=10min) when the
        # setup script reaches its last line, ~3s after the check exits -- so derive
        # the span rather than hardcoding it, since it moves with the sampling loop.
        virtual = (check_exit + 3 + 600) - boot_uptime
        machine.log(
            f"boot reached multi-user at guest uptime {boot_uptime:.0f}s; "
            f"then ~{virtual:.0f}s virtual took {wall:.0f}s wall"
        )
        # The span the ratio below is computed over. A slow boot does not fail this test --
        # the check still fires at its real 300s deadline and the awk sleep clamps to 1s --
        # but every virtual second spent booting is one the driver never gets to watch the
        # warp over, so `virtual` shrinks and the ratio quietly measures less and less. At
        # some point it measures nothing while still passing. Assert the span explicitly so
        # that degradation fails loudly instead. Half of setupTimeout is the floor; measured
        # 529s on x86 (387s boot). If the aarch64 variant trips this, the answer is a faster
        # node (memory/vCPUs), not a lower floor.
        assert virtual >= 300, (
            f"only {virtual:.0f}s of virtual span left after a {boot_uptime:.0f}s boot; "
            "the icount warp is barely being measured"
        )
        # The icount certificate: the virtual span must cost far less wall time than real
        # time (a non-warping run would need >= `virtual` seconds).
        #
        # Expressed as a ratio, not an absolute wall-clock bound. This used to be
        # `wall < 300`, which was already sitting at 96% of the observed value (288s) and
        # went to 99% once the production check loop lengthened the virtual span -- i.e.
        # it was one slow runner away from flaking while measuring nothing the ratio does
        # not measure better. The ratio also scales on its own if the sampling window
        # grows. Observed here: 0.48.
        ratio = wall / virtual
        assert ratio < 0.75, (
            f"warp too slow: {wall:.0f}s wall for {virtual:.0f}s virtual (ratio {ratio:.2f})"
        )
  '';
}
