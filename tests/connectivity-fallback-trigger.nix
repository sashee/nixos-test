{ nixpkgs, pkgs, stateVersion, machineModule }:

# Trigger semantics for the connectivity check, isolated from the radio stack.
#
# This is the regression test for the shape of the 2026-07-27 outage. Back then the check
# asked the internet whether it should raise the setup AP: it probed a single third-party
# HTTP canary (detectportal.firefox.com), Mozilla migrated that host to a new CDN, the
# pinned address went stale, and the box rebooted every 15m23s for ~16 hours while its
# internet worked the whole time. The fix is not a better probe -- it is asking a question
# the module can actually act on. Setup mode hands out new wifi credentials, so the only
# condition it can repair is "not associated to any network", and that is read from the
# kernel via `iw dev <iface> link`.
#
# What has to hold, and what breaks silently if it does not:
#
#   1. Sustained non-association enters setup mode -- otherwise a Pi that lost its wifi
#      never offers a way back in, and the module does nothing at all.
#   2. A SINGLE association anywhere in the sampling window wins. Association flaps (a
#      roam, a background scan, a driver hiccup), and if one unlucky reading were enough
#      the module would reproduce the old bootloop from a purely local cause. This is the
#      property the sampling loop exists for; with samples=1 the test above still passes
#      and only this one fails.
#   3. `iw` failing (missing device, wrong `interface`, dead driver) must NOT enter setup
#      mode. Without that radio the AP cannot beacon either, so the only reachable
#      outcome is a reboot every bootGrace+setupTimeout -- the same bootloop, now caused
#      by a typo in a config option rather than by someone else's CDN. The old
#      "endpoints must not be empty" / "no '|' in a field" eval assertions guarded this
#      class at build time; a wrong-but-well-formed interface name cannot be caught at
#      eval, so the runtime path has to fail safe instead.
#
# `iw` is replaced by a fake that pops one line off a queue file, so the driver can script
# exactly what each sample sees -- which is the only way to test case 2 at all. Everything
# real about the radio (station mode, AP mode, DHCP, the portal) is covered by
# connectivity-fallback.nix on mac80211_hwsim.
#
# machineModule is the system under test: the aarch64 variant passes the REAL rpi config
# (hosts/rpi5 on the Pi kernel, with only auto-upgrade and monitoring disabled), so the
# deployed stack -- dnscrypt, the doh egress rules, the default-deny firewall -- is live
# while the check runs. That matters beyond fidelity: with the firewall managed, the setup
# script inserts its runtime nixos-fw openings, so the first subtest exercises that path
# too. The x86 variant has no real image (aarch64-only) and uses a minimal
# module+firewall node.
let
  queue = "/run/fake-iw-queue";

  samples = 3;
  intervalSeconds = 2;

  # Stands in for `iw`. Pops the queue's first line and acts on it:
  #   up   -> print what an associated interface looks like, exit 0
  #   down -> "Not connected.", exit 0
  #   gone -> iw's own wording for a missing device, on stderr, exit non-zero
  # An exhausted queue keeps returning the last verdict, so a test that under-fills it
  # fails on the assertion it is making rather than on a surprise from the fake.
  fakeIw = pkgs.writeShellScriptBin "iw" ''
    verdict="$(head -n 1 ${queue} 2>/dev/null || true)"
    if [ "$(wc -l < ${queue} 2>/dev/null || echo 0)" -gt 1 ]; then
      tail -n +2 ${queue} > ${queue}.next && mv ${queue}.next ${queue}
    fi
    case "$verdict" in
      up)
        printf 'Connected to 02:00:00:00:01:00 (on %s)\n\tSSID: FakeNet\n\tfreq: 2437\n' "$2"
        ;;
      gone)
        echo "command failed: No such device (-19)" >&2
        exit 240
        ;;
      *)
        echo "Not connected."
        ;;
    esac
  '';
in
nixpkgs.lib.nixos.runTest {
  name = "connectivity-fallback-trigger";
  hostPkgs = pkgs;

  nodes.machine = { lib, pkgs, ... }: {
    imports = [ machineModule ];

    networking.hostName = "nixos-rpi5";
    networking.wireless.iwd.enable = true;

    common.connectivityFallback = {
      enable = true;
      # Only the check's own view of the radio is faked. iwd is real and running; the
      # setup script's iwctl calls are expected to fail on a node with no radio, which
      # is why "not inactive" is what the assertions look for below.
      tools.iw = lib.mkForce fakeIw;
      association = { inherit samples; inherit intervalSeconds; };
      # The check is driven by hand here, so keep the boot timer far away, and keep the
      # safety-net reboot far enough out that a started setup mode cannot power-cycle
      # the VM mid-test.
      bootGrace = "1h";
      setupTimeout = "1h";
    };

    system.stateVersion = stateVersion;
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # The timer must not have fired on its own; every assertion below is about a
    # hand-started run.
    machine.succeed("systemctl is-active connectivity-fallback-check.timer")
    machine.fail("systemctl is-active connectivity-fallback-setup.service")


    def run_check(verdicts):
        machine.succeed(
            "printf '%s\\n' " + " ".join(verdicts) + " > ${queue}"
        )
        # Back-to-back `systemctl start` of a oneshot trips the start-limit otherwise.
        machine.succeed("systemctl reset-failed connectivity-fallback-check.service || true")
        machine.succeed("systemctl start connectivity-fallback-check.service")


    def check_journal():
        # Scope the read to the service's CURRENT invocation, so a later subtest cannot
        # see an earlier one's verdict. Rotating and vacuuming between runs does not
        # achieve that: `journalctl --vacuum-time=` drops archived files by their newest
        # entry's age, so a file rotated moments earlier is younger than any usable bound
        # and survives with the old lines in it. Same pattern as tests/iroh-ssh.nix and
        # tests/nix-gc-retention.nix.
        inv = machine.succeed(
            "systemctl show -p InvocationID --value connectivity-fallback-check.service"
        ).strip()
        return machine.succeed(f"journalctl _SYSTEMD_INVOCATION_ID={inv} -o cat")


    def mono(prop):
        # One property per call: `systemctl show` with several -p flags gives no
        # documented output order, and guessing it would make this silently wrong.
        return int(
            machine.succeed(
                f"systemctl show connectivity-fallback-check.service -p {prop} --value"
            ).strip()
        ) / 1e6


    with subtest("sustained non-association enters setup mode"):
        run_check(["down"] * ${toString samples})
        # NB: not `log` -- that name is the test driver's own logger object.
        journal = check_journal()

        assert "entering setup mode" in journal, journal
        # "nothing to do" rather than "associated": the per-sample lines say "not
        # associated", so a substring check on that word matches its own negation.
        assert "nothing to do" not in journal, journal
        # Every sample was actually taken; without this the test would pass on a check
        # that gave up after the first reading, which is the behaviour subtest 2 forbids.
        for i in range(1, ${toString samples} + 1):
            assert f"not associated (sample {i}/${toString samples})" in journal, journal

        # The window was really waited out rather than short-circuited -- otherwise
        # association.intervalSeconds would be untested and a flap could still win.
        elapsed = mono("ExecMainExitTimestampMonotonic") - mono("ExecMainStartTimestampMonotonic")
        machine.log(f"check took {elapsed:.1f}s over ${toString samples} samples")
        window = (${toString samples} - 1) * ${toString intervalSeconds}
        assert elapsed >= window, f"check took only {elapsed}s; the samples were not spaced"

        # Setup mode was genuinely triggered. It cannot succeed on a node with no radio,
        # so "not inactive" (activating or failed) is the observable signal that the
        # check handed off rather than silently doing nothing.
        machine.wait_until_succeeds(
            "test \"$(systemctl is-active connectivity-fallback-setup.service)\" != inactive",
            timeout=30,
        )
        machine.succeed("systemctl stop connectivity-fallback-setup.service")
        machine.succeed("systemctl reset-failed connectivity-fallback-setup.service || true")

    with subtest("one association anywhere in the window outvotes the rest"):
        # The flap: two bad readings and one good one. If any single "not associated"
        # were enough, this host would tear down a working link -- locally caused, but
        # the same bootloop as 2026-07-27.
        run_check(["down", "down", "up"])
        journal = check_journal()

        assert "associated (Connected to 02:00:00:00:01:00" in journal, journal
        assert "nothing to do" in journal, journal
        assert "entering setup mode" not in journal, journal
        machine.fail("systemctl is-active connectivity-fallback-setup.service")

    with subtest("an unusable radio does not enter setup mode"):
        # `iw` itself failing means no device -- so no AP either. Entering setup mode
        # could only cost a reboot every bootGrace+setupTimeout while fixing nothing.
        run_check(["gone"] * ${toString samples})
        journal = check_journal()

        assert "NOT entering setup mode" in journal, journal
        assert "No such device" in journal, journal
        assert "entering setup mode" not in journal.replace("NOT entering setup mode", ""), journal
        machine.fail("systemctl is-active connectivity-fallback-setup.service")
  '';
}
