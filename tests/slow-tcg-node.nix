# Headroom for the device units the test driver's root shell hangs off, for tests whose nodes boot
# concurrently under TCG emulation.
#
# nixpkgs' test-instrumentation.nix gives `backdoor.service` -- the shell the driver talks to --
# `Requires=dev-hvc0.device dev-${qemuSerialDevice}.device`, and caps manager-wide device jobs at
# `DefaultDeviceTimeoutSec = 300`. That is generous with KVM and marginal without it: the
# KVM-less aarch64 CI runner has four vCPUs, so a test that calls `start_all()` on six
# single-core nodes runs each at a small fraction of a core, and a device job queued 120 seconds
# into the boot can go unserviced past the cap.
#
# What makes that fatal rather than slow is the failure mode. The job does not stay pending -- it
# FAILS, `Requires=` propagates the failure, and `backdoor.service` is cancelled with nothing to
# retry it:
#
#   dohstale # [ 421.91] systemd[1]: dev-ttyAMA0.device: Job dev-ttyAMA0.device/start timed out.
#   dohstale # [ 421.97] systemd[1]: Dependency failed for backdoor.service.
#
# The driver then waits for a root shell that can no longer appear, so the run burns its whole
# globalTimeout and reports a hang instead of a result -- 30 minutes of a five-hour job, with no
# diagnosis and no signal on the code under test.
#
# It is a cliff, not a gradient, and the 2026-08-05 rpi job landed five nodes within 15 seconds of
# it: dohstale 299.9s and ntsgood 299.5s fell off, dohgood 289.8s, ntsstale 286.7s and
# ntsredirect 285.7s cleared it. Any one node tripping kills the whole test, so the same commit
# passed one run and hung the next. 1200 puts the margin far outside the jitter; the driver's own
# globalTimeout stays the real ceiling, so nothing here can make a genuine hang wait longer than
# it already would.
#
# Applied through `runTest`'s `defaults` rather than through rpiSystemModule, deliberately: the
# nodes that trip this are the 512MB single-core DoH interceptors and NTS peers, which are not rpi
# configs at all. The one node that IS one gets two cores and 4GB and was never at risk (165s).
# `defaults` is the only place that reaches every node.
#
# mkForce because test-instrumentation.nix assigns systemd.settings.Manager at normal priority.
{ lib, ... }:

{
  systemd.settings.Manager.DefaultDeviceTimeoutSec = lib.mkForce 1200;
}
