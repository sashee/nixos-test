# VM-test guest clock: tomorrow at 10:00 UTC, computed when the VM starts
# (qemu-vm.nix splices options unescaped into the start script, so the $()
# runs at launch; the derivation string itself is constant). Always 10-34h
# ahead of real time: past systemd's built-in epoch, past the notBefore of
# build-time-generated test certs (tests/test-cert.nix mints CAs with the
# real clock, so a base in the past fails their validation), and pinned to
# 10:00 so no host timer slot (nix-gc at 03:15/15:15) can elapse mid-test.
# The coreutils must match the platform the test driver runs on.
#
# Lives here rather than in flake.nix because a test file needs it too: a helper node
# serving time to the node under test (tests/system-metrics.nix) has to sit on the same
# clock, and the day-truncated `date -d tomorrow` makes two nodes given this same
# expression agree on the absolute instant rather than merely on the offset.
coreutils:
"-rtc base=$(${coreutils}/bin/date -u -d tomorrow +%Y-%m-%dT10:00:00)"
