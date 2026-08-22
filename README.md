# Plasma Firefox NixOS Module

This flake exports one composed NixOS desktop module and a QEMU VM/check that
exercise that same common configuration.

## Laptop Import

Use this flake as the source of `nixpkgs` so the laptop and common config do not
evaluate against competing nixpkgs revisions:

```nix
{
  inputs = {
    common.url = "github:sashee/nixos-test";
    nixpkgs.follows = "common/nixpkgs";
  };

  outputs = { nixpkgs, common, ... }: {
    nixosConfigurations.laptop = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        common.nixosModules.common-desktop
        ./configuration.nix
      ];
    };
  };
}
```

`common.nixosModules.common-desktop` is the public laptop module. It composes
these internal modules:

```text
modules/nix-settings.nix
modules/locale.nix
modules/laptop-base.nix
modules/audio.nix
modules/firewall.nix
modules/doh.nix
modules/restic.nix
modules/auto-upgrade.nix
modules/monitoring.nix
modules/system-metrics.nix
modules/time-sync.nix
modules/iroh-ssh.nix
modules/fonts.nix
modules/development-base.nix
modules/nix-utils.nix
modules/plasma-firefox.nix
```

Host-specific users, hostnames, disks, bootloaders, passwords, and hardware
quirks should stay in the laptop config.

`modules/auto-upgrade.nix` enables automatic laptop updates by default as part
of `common-desktop`. Each host config must point it at the local flake output
that should be rebuilt:

```nix
{
  common.autoUpgrade = {
    flake = "/etc/nixos#my-laptop";
  };
}
```

The module runs daily with `system.autoUpgrade.operation = "boot"`, so the timer
builds the new generation and makes it the next boot target without switching
the running system. The new system is activated after reboot.

For laptop-local flakes, the timer runs `nix flake update common --flake
/etc/nixos --commit-lock-file` before rebuilding. This keeps the exact central
`github:sashee/nixos-test` revision recorded in the laptop's local
`/etc/nixos/flake.lock`. The root user must be able to commit in that
repository; if `/etc/nixos` is not owned by root, configure Git's
`safe.directory` for it. Disable the timer on non-laptop systems with:

Laptop flakes must name this repository input `common`:

```nix
inputs.common.url = "github:sashee/nixos-test";
```

Disable the timer on non-laptop systems with:

```nix
common.autoUpgrade.enable = false;
```

`.github/workflows/update-flake.yml` updates `flake.lock` daily, runs every check
set one check at a time (the same legs, sharding and `make run-checks` invocation
CI uses), and commits the lock file only when they all pass.
Hosts that point a local input at this repository can advance to those validated
commits when their local upgrade timer updates `/etc/nixos/flake.lock`.

VM-only users, autologin, and test tools are internal to this flake and are only
used by the QEMU VM/tests.

## Installing on a laptop

`common-desktop` already provides the parts that are the same on every machine, so
a host config only needs the hardware-specific pieces.

Provided by `common-desktop` (do not repeat in the host config):

```text
Plasma 6 + Firefox, SDDM, hardware graphics
NetworkManager, Bluetooth, DNS over HTTPS, nftables firewall
PipeWire audio, fonts, CLI/dev tools, direnv
redistributable firmware, CPU microcode (Intel + AMD), zram swap
byte-based dirty-page writeback thresholds (256 MiB hard / 64 MiB background)
flakes/nix settings + GC, auto-upgrade, monitoring, restic scaffolding
SSH over iroh tunnel for IP-less remote access
```

Laptop host configs live **in this repository** (`hosts/<name>/configuration.nix`,
exposed as `common.lib.hosts.<name>`; spec in `spec/<name>.md`), so the shared
modules, the host specifics, and the VM tests that exercise the real host config
evolve together. Only the machine-unique state stays on the device:

```text
hardware-configuration.nix   generated at install (filesystems, LUKS device, microcode kind)
flake.nix + flake.lock       the stub below
user passwords               set with `passwd` at install; never in this repo
encrypted credentials        systemd-creds blobs under /etc/credentials
```

The host config in this repo must set: `networking.hostName`, `time.timeZone`,
locale/keyboard, users (admin keys come from `lib/ssh-keys.nix`; **no password
options** — see Install below), the bootloader, `common.autoUpgrade.flake`,
`common.monitoring.report.credentialDirectory`, and
`common.irohSsh.credentialDirectory`. See
`hosts/anya-feher-laptop/configuration.nix` for the reference host.

`common.autoUpgrade`, `common.monitoring`, and `common.irohSsh` are **enabled by default**, and
each fails evaluation if its required argument is missing — `common.autoUpgrade.flake` for upgrades,
`common.monitoring.report.credentialDirectory` for monitoring (when reporting is on), and
`common.irohSsh.credentialDirectory` for the SSH tunnel. This is deliberate: a laptop cannot
silently ship with upgrades, monitoring, or remote access unconfigured. Opt a host out with
`common.autoUpgrade.enable = false` / `common.monitoring.enable = false` /
`common.irohSsh.enable = false`, or disable just the monitoring ping with
`common.monitoring.report.enable = false`.

### 1. On-device stub flake

The whole `/etc/nixos` on the laptop is a three-file stub (same shape as the
Pi's, see `docs/rpi5-rescue.md`): it names this repository `common` and injects
the generated hardware config into the in-repo host:

```nix
{
  inputs.common.url = "github:sashee/nixos-test";

  outputs = { common, ... }: {
    nixosConfigurations.anya-feher-laptop = common.lib.hosts.anya-feher-laptop {
      modules = [ ./hardware-configuration.nix ];
    };
  };
}
```

The daily auto-upgrade updates the `common` input and rebuilds, so pushing to
this repo is how shared *and* host-specific changes reach the machine; only
hardware changes ever require editing the stub.

Hardware-specific extras live in `hardware-configuration.nix`:

- **Disk encryption** — `nixos-generate-config` detects an open LUKS mapping
  under the root filesystem and emits `boot.initrd.luks.devices.<name>.device`
  itself; verify it is there.
- **Swap partition / swapfile** — `swapDevices` (merges with the base zram;
  zram keeps the higher priority, so disk swap is overflow only).
- **Hibernation** — additionally set `boot.resumeDevice` (and a `resume_offset`
  kernel param when resuming from a swapfile).

### 2. Install

Partitioning and formatting are hardware-specific; follow the
[NixOS manual](https://nixos.org/manual/nixos/stable/#sec-installation). Use
LUKS2 for the encrypted root — argon2id is its default KDF (`cryptsetup
luksFormat --type luks2 /dev/<part>`), and format on the target machine so the
benchmarked unlock cost fits its RAM. Once the target is mounted at `/mnt`:

```bash
nixos-generate-config --root /mnt
# Keep the generated hardware-configuration.nix, add the stub flake.nix next to
# it, then install the in-repo host:
nixos-install --flake /mnt/etc/nixos#anya-feher-laptop
# Passwords are imperative state (users.mutableUsers): set the primary user's
# now; admin accounts get none and stay key-only ssh.
nixos-enter --root /mnt -c 'passwd anya'
reboot
```

The installer needs flakes enabled for `--flake`; if they are not on, prepend
`--option experimental-features 'nix-command flakes'` to `nixos-install`.

After first boot the iroh credential is not provisioned yet, so the tunnel is
inert; the failsafe opens port 22 on the LAN ~5 minutes after boot. SSH in with
the admin key, provision the credentials (same commands as `docs/rpi5-rescue.md`
step 4), and start `iroh-ssh.service` — the failsafe closes port 22 as soon as
the tunnel answers.

## Module Contents

`modules/plasma-firefox.nix` contains Plasma 6 Wayland, SDDM, hardware graphics,
Firefox, and Konsole.

`modules/laptop-base.nix` contains NetworkManager, Bluetooth, redistributable
firmware, CPU microcode updates (Intel and AMD), firmware updates (fwupd), power
profiles, printing, UPower, and zram swap. The microcode and firmware settings
are CPU- and vendor-agnostic, so the base works unchanged on any Intel or AMD
laptop.

It also sets the dirty-page writeback thresholds in **bytes** —
`vm.dirty_background_bytes` 64 MiB, `vm.dirty_bytes` 256 MiB — instead of the
kernel's RAM-proportional `dirty_background_ratio`/`dirty_ratio` defaults
(10%/20%), which on a 16-32 GB laptop let GBs of dirty pages pile up before any
writeback starts and then stall in one burst. Writing either byte knob zeroes its
ratio counterpart, so the byte values are the ones in force. `hosts/rpi5` sets a
quarter of each (16 MiB / 64 MiB): 4 GiB of RAM behind an SD card, where a large
dirty pool is many seconds of queued writes. Both are covered by the `system`
check.

`modules/audio.nix` contains PipeWire and realtime audio support.

`modules/firewall.nix` blocks unsolicited inbound TCP, UDP, and ping while
allowing outbound traffic and established return traffic. It is enabled by
default in `common-desktop` and can be disabled with:

```nix
common.firewall.enable = false;
```

`modules/doh.nix` enables system-wide DNS over HTTPS through `dnscrypt-proxy`
with static IPv4 and IPv6 DoH resolver stamps for every provider in
`lib/doh-stamps.nix`. It points local resolver configuration at localhost and blocks
direct outbound TCP and UDP port 53 except to localhost. It is always enabled
for `common-desktop` hosts and has no opt-out, so plaintext DNS egress can never
be silently re-enabled. To keep captive portals usable behind that lock, the
connectivity-check names in `lib/captive-portals.txt` are answered locally from a
static map (so they resolve even when the DoH upstreams are unreachable), and
NetworkManager connectivity checking is enabled against `captive.apple.com` so
KDE Plasma detects the portal and offers the login page. The `nm-captive-portal`
test drives NetworkManager end-to-end against a fake `captive.apple.com`,
asserting it reports `full` on an open network and `portal` once the endpoint
redirects.

`modules/time-sync.nix` owns the clock. chrony replaces systemd-timesyncd and
synchronises over NTS — authenticated NTP — against the servers in
`lib/nts-servers.nix`, with `minsources 2` so no single reachable server can set
the time unchallenged.
`enableNTS` brings `ntsdumpdir` with it, so cookies survive a reboot and a cold
boot does not have to redo key establishment before it can ask the time. The
module also sets `rtcsync`, which keeps the RTC current (so a host that has one
starts its next boot close to correct) and is what makes chronyd tell the *kernel*
the clock is synchronised; nixpkgs' default `enableRTCTrimming` is mutually
exclusive with it and is therefore off, which costs nothing here — the Pi has no
RTC battery at all. The module writes `/run/chrony-wait/synchronized` from a small
`chrony-wait` unit and repoints `common.systemMetrics.syncedMarker` at it, since
chrony has no equivalent of timesyncd's marker and `time-sync.target` is reached
when chronyd *starts*, not when it has synchronised. (It repoints the marker but
no longer arms the gate on hosts whose metrics go through `mp-collector`, which
re-dates pre-sync batches instead of discarding them — see the monitoring
platform section below.)

The rest of the module is the way out of a deadlock. DoH and NTS are both TLS, so
a clock outside certificate validity blocks name resolution and time
synchronisation at once and neither can recover the other — and an RTC-less
Raspberry Pi is in exactly that state on every cold boot. chrony cannot break it
by synchronising, because whatever its certificate policy it still has to *resolve*
the NTS hostnames, and that is DoH. There are two independent ways out, and the
cheap one is chrony's own.

**The persisted last-known-good clock.** chronyd runs with `-s`. It rewrites its
`driftfile` whenever it computes a new drift value — at most hourly, and
unconditionally on exit — and only ever while it is actually disciplining the
clock, so that file's mtime is a timestamp at which this host was demonstrably
right. At startup `-s` sets the clock from the RTC, or, when there is no usable RTC
or the RTC reads *earlier* than that mtime (which is what a dead battery looks
like), steps the clock **forward** to the mtime instead. No network, no DNS, one
`stat`. It recovers a host that was merely off for a while; it cannot help one that
was off for longer than a certificate's validity, and being forward-only it can
never drag a good clock backwards.

**The time-correction service.** `packages/time-correction`, a small Rust binary, dials
a DoH resolver at a pinned address (the same addresses `modules/doh.nix` pins, read
from `lib/doh-stamps.nix`) to resolve an NTS server's name, does NTS key
establishment with that server, takes an authenticated NTPv4 timestamp — and only
then verifies both certificate chains, at the instant that was reported. That last
step is the whole security argument, and a `Deferred` type makes it structural
rather than a step someone can forget: there is no way to obtain a believable time
except by consuming the recorded chains. Two independent operators must agree
within a minute, so moving this clock means compromising two at once, and only ever
within a certificate's validity window — with `nixpkgs.lastModified` passed in from
`flake.nix` as a floor, applied to each provider's own answer *before* that answer
is used to re-verify anything, bounding how far back a once-valid certificate could
roll things. Any provider failing fails the run. `time-correction --force --dry-run` on
a live host asks exactly what the service asks and prints the answer without
setting anything.

It runs on a timer: once a minute after boot, then every
`common.timeSync.interval` (default one hour). Monotonic rather than
`OnCalendar` + `Persistent`, deliberately — `Persistent` works out what was missed
by comparing a stored wall-clock stamp against the current clock, and a wrong clock
is precisely the state this exists for. The hourly run is also a *check*, not only
a repair: it does the whole DoH + NTS exchange even where the clock is
demonstrably fine, so a provider that stopped answering or a pinned address that
moved shows up as a failing unit while the host is still healthy enough to say so,
rather than at the next cold boot when nothing works and nobody can reach the box.
Asking the kernel via `adjtimex` whether the clock is already synchronised, and
skipping the exchange when it is, would trade that discovery away for nothing.

It still steps the clock only when it has to. It stands down when the current
clock, however wrong, already falls inside the validity of every certificate it
just checked: TLS works at that point, which is the only thing this program exists
to arrange, and chrony will make the accurate correction itself rather than have a
whole-second approximation imposed on it first. *Checked*, not merely received —
a peer sends whatever is in its chain file and TLS uses only the certificates on
the path it builds, so a superseded cross-sign left behind must get no vote on
whether this clock is good enough. Letting it vote would narrow the window past
the present and step a *correct* clock on every run, on every host at once, with
nothing local to blame; `spec/features/system/time-correction-details.md` states
the rule and `verify::verified_window` is what enforces it. On a host chrony has
disciplined the stand-down rule always fires, which is what makes the
unconditional exchange free. It
leans on chrony being able to step a large error, which it can, because nixpkgs
defaults `services.chrony.makestep` to `0.1 3` — the first three updates step, with
no size limit.

It is deliberately not ordered against chronyd, though `Before=chronyd.service`
reads like the obvious thing to write. What that would buy is chronyd's *first*
name resolution happening with a usable clock, so it never enters its own retry
backoff — `7 × 2^n` seconds with `n` clamped to `[2,9]`, i.e. 28s to ~60min, and
`n` resets only on a successful resolve. What it costs is more: a full DoH + NTS
exchange before chronyd may start, on every boot of every host, now that the
exchange happens unconditionally; a postponed `chronyd -s`, which is the half of
the recovery needing no network and so the half most likely to work; and, since the
boot run waits for `network-online.target`, chronyd waiting for the network too.
The accepted consequence is that on an RTC-less cold boot whose persisted time is
too stale to help, chrony's first synchronisation is gated by its own 28s retry
floor. `tests/time-correction.nix` pins that chronyd runs regardless of whether the
correction service succeeded.

There is deliberately no reboot failsafe for "the correction service succeeded and
chrony still has not synchronised": a reboot is a remedy for a wedged resolver and
nothing else, the hourly run surfaces that class of fault as a plain failing unit,
and an unbounded reboot rule is the shape of the 2026-07-27 bootloop
`modules/connectivity-watchdog.nix` exists to avoid repeating.

It is opt-in (`common.timeSync.enable`) and enabled on every host that gets the
common desktop layer as well as on the Pi — `timeSyncSettings` in `flake.nix` is
composed into all three module lists, which is also where `floor` comes from
(`nixpkgs.lastModified` is only in scope there). Two VM checks cover it, each on
three configurations — the aarch64 Pi, the laptop as
`anya-feher-laptop-time-correction` / `anya-feher-laptop-nts-sync`, and the Pi's own
config on the stock x86 kernel as `rpi5-x86-time-correction` / `rpi5-x86-nts-sync`
(see "The rpi5 config on x86" below for what that last one does and does not prove).
`time-correction` exercises the binary's quorum, floor,
deferred certificate checks and stand-down rule, and the unit's timer, against
controlled DoH resolvers and NTS servers; `nts-sync` reproduces the deadlock end to
end on the real host config — the machine boots years out, cannot resolve anything,
and has to climb out to chrony on its own — and covers the persisted clock by
putting the RTC behind the drift file, which is what a dead battery looks like.
Both of those necessarily override the cadence, the server list and the floor to be
testable at all, so three eval checks cover what they cannot see: `nts-servers`
and `doh-providers` guard the two source lists, `time-sync-deployed` renders both
deployed hosts' timer and service and asserts the cadence, the whole argument
vector, and that the metrics clock gate points at chrony's marker, and
`time-sync-assertions` checks that the module still refuses the
configurations it says it refuses — an unset floor, a sample larger than the
distinct operators, an empty or unknown server list, and a marker path
`RuntimeDirectory` cannot create.

`modules/restic.nix` configures named restic backups using systemd credentials.
Each backup must specify the user that runs the service. Backup paths are bound
read-only into the hardened unit while `/home` is otherwise protected with a
temporary filesystem view.
Each backup expects a credential directory with raw secret files:

```text
/etc/credentials/restic/home/repository-password
/etc/credentials/restic/home/backend-username
/etc/credentials/restic/home/backend-password
```

Use the flake helper functions from a host configuration to keep backend shape
separate from the common module:

```nix
common.restic.backups.home = common.lib.restic.rest {
  user = "sashee";
  credentialDirectory = "/etc/credentials/restic/home";
  url = "https://backup.example.com";
  repository = "home";
  paths = [ "/home/sashee" ];
  exclude = [ ".stversions" ];
  prune.ignoreErrors = false;
};

common.restic.backups.photos = common.lib.restic.s3 {
  user = "sashee";
  credentialDirectory = "/etc/credentials/restic/photos";
  endpoint = "s3.example.com";
  bucket = "restic-backups";
  paths = [ "/home/sashee/Pictures" ];
  prune.ignoreErrors = true;
};
```

For S3 backups, use AWS credential files instead of `backend-password`:

```text
/etc/credentials/restic/photos/repository-password
/etc/credentials/restic/photos/aws-access-key-id
/etc/credentials/restic/photos/aws-secret-access-key
```

Missing credential files skip the generated backup unit instead of failing it.
Backups run `restic unlock` before `backup`, use `--group-by=` for backup and
retention, and run `restic check` after backup/retention.
When `prune.ignoreErrors = true`, backup success is preserved even if `restic
forget --prune` fails on an append-only repository.

`modules/monitoring.nix` runs daily health checks — SMART disk status, restic
backup age, local disk-space usage, NixOS system-generation count,
auto-upgrade age, nix-gc age, and iroh-ssh health (the tunnel service is
running and the failsafe has not opened firewall port 22 — a missing
credential also fails this check on purpose: broken remote management is
exactly what it alerts on) — and reports the result to a Healthchecks-compatible
URL. It is
**enabled by default**; when reporting is enabled (also the default), the host
must set `common.monitoring.report.credentialDirectory` (the directory holding
the URL credential) or evaluation fails. Disable the whole check with
`common.monitoring.enable = false`, or just the reporting with
`common.monitoring.report.enable = false`. See `common.monitoring.*` to tune each
check.

The **monitoring platform** is a separate thing that reads confusingly close to
the above: `modules/monitoring.nix` reports a host's *own* health outward, while
the platform *collects* measurements from devices. It is an OTLP/HTTP receiver
(protobuf, logs signal, events only) storing arbitrary measurements — CPU load,
GPS position, heart rate — in SQLite at `/var/lib/monitoring-platform`. It lives
in its own repository and is consumed as the non-flake `monitoring-platform`
input, exactly like `dotfiles`: `nix/module.nix` is a plain NixOS module and
`nix/package.nix` a plain `callPackage`, so the binary is built with the target
system's nixpkgs rather than a second pinned one. `mkRpi5` composes the module in
(an `imports` entry must resolve before module arguments exist, so the host
config cannot import it itself), and `hosts/rpi5` enables it with
`services.monitoring-platform.enable = true`. It listens on a **unix socket
only** — `RestrictAddressFamilies = [ "AF_UNIX" ]` makes that a kernel guarantee
— so there is no port for the firewall to open and no credential to provision;
reaching it means being in the `monitoring-platform` group, which owns the 0750
runtime directory. Remote devices still cannot reach it — upstream's iroh
transport has not landed — so everything it stores today comes from the host
itself, by way of the collector below. Upstream's own VM suite runs against the
real Pi configuration as the `monitoring-platform*` aarch64 checks, which is the
run that decides whether its hardening is right for the systemd the Pi actually
boots.

The same suite also runs as the `monitoring-platform*` **x86** checks, against a
node built from `modules/time-sync.nix` rather than a whole host config. That is
not about hardening — it is about the one thing the harness must do for any
consumer and can only get wrong at runtime: give the machine a working time
source without touching how it keeps time, so the receiver's boot-time clock gate
can open. Our chrony configuration uses NTS with `minsources 2` against four
server names, and a harness that resolved all four to one address left chrony a
single usable source, so the gate never opened and every case timed out. That
property is arch-independent, so having it on x86 means a laptop reproduces it in
minutes rather than it surfacing only on hardware CI cannot emulate. The node
deliberately skips `commonDesktopModule`: `modules/nix-utils.nix` puts the
sandboxed `sqlite3` on root's system-wide PATH, which the harness cannot use to
read the receiver's database — a desktop artifact the Pi does not have, since
there nix-utils is on the `nixos` user's PATH only. The x86
platform-plus-desktop combination is covered by the `system-metrics` check
instead.

Note the clock gate is switched off on every other test node, by
`testNodeClockGateOff` in `flake.nix`: it blocks startup until the kernel's clock
error estimate is small, and an ordinary test node has no time source to get
there with (`testNodeTimeSyncOff` removed chrony, and `qemu-vm.nix` had already
disabled `timesyncd`), so the gate would hold every boot for its full
`TimeoutStartSec` and then fail the unit. The two suites above are where the gate
is actually exercised; both bring their own NTP node and force it back on. A
third override beside those two, `testNodeCollectorHealthOff`, zeroes the
collector's own health-event interval on test nodes: those events are ordinary
measurements landing in the same table on a 60-second timer, which is wanted in
production and ruinous next to a test asserting an exact set of types and an
exact batch count.

**Nothing posts to the receiver directly.** In between sits `mp-collector`, the
monitoring platform's on-host forwarding collector (`nix/collector-module.nix` in
the same input, composed into `rpi5HostModules` beside the receiver). It takes
OTLP on its own unix socket, forwards to whatever `forwardTo` names, and exists
so that **moving the receiver is a change to one option on one service** — every
producer keeps posting to the same local socket and needs no edit. Today
`forwardTo` and `forwardToGroup` are left unstated because their defaults are
already the receiver's socket and group; when the platform moves off the Pi,
those two lines are the whole diff (`forwardToGroup = null` for an `http://`
target, which also widens the collector's `RestrictAddressFamilies` off that same
option, so there is no second switch to forget).

The hop earns its place for a second reason on this hardware. The Pi has no RTC
battery, so from boot until chrony first syncs its clock reads near the epoch.
The collector holds batches stamped in that window, works out which clock frame
they came from, and rewrites the timestamps once the true time is known — or
flushes them marked `mp.clock.uncertain` if sync never arrives at all. Its unit
is deliberately the inverse of the receiver's: the receiver refuses to start
until the clock is good, while the collector is ordered *before* every time
daemon, because a collector that is not running observes no clock step.

`modules/system-metrics.nix` is the producer: a systemd oneshot on a 15-minute
timer that collects the host's CPU (load, core count, utilisation over a
1-second `/proc/stat` sample), memory (including swap), per-filesystem usage and
current NixOS generation, and posts them to the collector as one OTLP batch —
five measurement types, `system.cpu` / `system.memory` / `system.filesystem` /
`system.generation` / `system.host`, each carrying `resource.attributes.host.name`
so one query can serve a whole fleet later. The wire format only speaks binary
OTLP protobuf and requires a non-empty `LogRecord.event_name` per record, so the
producer is a small Rust binary in `packages/system-metrics` built on the same
`opentelemetry-proto` crate the receiver decodes with, rather than a shell
script. It runs under `DynamicUser` whose only privilege is membership of the
collector's group, and `RestrictAddressFamilies = [ "AF_UNIX" ]` makes "this
never talks to the network" a kernel guarantee on the producer side too. Two
behaviours worth knowing: a **collector** that is down makes the unit fail rather
than skip, since a silently-green unit that stopped measuring is the failure mode
worth avoiding — while a *receiver* that is down is not the producer's problem at
all, because the collector buffers through it; and there is deliberately no clock
gate on hosts where the collector is in the path.

That last one used to be the opposite. `common.systemMetrics.requireClockSync`
put a `ConditionPathExists` on `common.systemMetrics.syncedMarker` and skipped
every run until the clock was known-synchronised, because the RTC-less Pi would
otherwise write permanent 1970-dated rows into a store that has no retention.
Once the collector is re-dating those batches, the gate is no longer the cheaper
mistake — it discards exactly the samples the collector exists to recover — so it
defaults off there. The switch is derived, not configured:
`common.systemMetrics.viaCollector` is a read-only option that holds when
`socketPath` is the enabled collector's socket, and both `requireClockSync` and
the `mkDefault` at the end of `modules/time-sync.nix` read it, so pointing the
socket elsewhere cannot leave a stale assumption behind. Where the gate does
still apply, its marker default is the one systemd-timesyncd writes, and
`modules/time-sync.nix` repoints it at chrony's `chrony-wait` marker, since
enabling chrony forces timesyncd off and its marker never appears.

The two halves of that are checked separately, because they fail differently. The
*mechanism* is covered by the `system-metrics` check against a real NTP server
rather than a hand-placed marker file: it runs a second node with chrony (`local
stratum 10`, so an island with no upstream still serves a usable reference) and
asserts that a batch produced while that daemon is down is **buffered rather than
dropped**, lands in the store once `systemd-timesyncd` syncs to it, is not marked
uncertain (so it flushed on sync, not on the 300-second cap), and carries the
`mp.clock.*` attributes that prove it travelled through the collector at all. It
also asserts the inverse of the old behaviour at the other end: losing NTP after
a good sync does *not* stop recording, because nothing steps when a time source
disappears — the clock free-runs and the error *bound* grows while the actual
error stays in milliseconds, and blanking telemetry during a network outage would
be paying for that with the data you most want. That helper node takes the same
`-rtc base=tomorrow 10:00` as the node under test (`lib/test-rtc-base.nix`) —
otherwise it would serve real wall-clock time and step the machine a day
backwards mid-test. Which shape each *deployed* host is in is a claim about
rendered units, so `time-sync-deployed` asserts it per host at eval time; that
also makes it the only check that covers the Pi.

It is opt-in (`common.systemMetrics.enable`) and enabled wherever a receiver
runs. `system-metrics --dry-run` prints the batch a run would send without
sending it. Covered end to end by the `system-metrics` check on both x86 and
aarch64: it posts through the real socket and reads the results back out of the
receiver's own query API, which is what verifies the encoding.

The fast x86 target for the producer is `rpi5-x86-system-metrics`: the Pi's own
config on the stock x86 kernel, so the whole producer → collector → receiver path
is the deployed one rather than a stand-in. `commonDesktopHostModule` in
`flake.nix` still **temporarily** composes the receiver and the collector into the
generic x86 desktop config, which is what that scaffolding was originally for; it
is now vestigial and can be dropped. `hosts/anya-feher-laptop` composes its own
module list and is deliberately untouched by it.

`modules/iroh-ssh.nix` keeps the laptop SSH-reachable by node identity
instead of IP: a hardened long-running service runs `iroh-ssh-listen` (a small
tool in `packages/iroh-ssh`, built on [iroh](https://iroh.computer))
forwarding incoming iroh streams to the local sshd at `127.0.0.1:22`. iroh
dials outbound through relays and hole-punches, so it works behind NAT and the
default-deny firewall without any inbound rules; port 22 stays closed to the
network (`services.openssh` is enabled with `mkDefault` and
`openFirewall = false`, so hosts keep control of sshd settings). It is
**enabled by default**; the host must set
`common.irohSsh.credentialDirectory` or evaluation fails
(`common.irohSsh.enable = false` opts out).

A **failsafe** watchdog probes the tunnel end-to-end: it dials the host's own
listener over iroh (using the canonical ticket and an ephemeral key) and checks
that sshd answers with its banner — hourly while probes succeed, then every 30
seconds after a failure so the 15-minute window is actually measured. If the
tunnel has not answered for 15 continuous minutes — missing or lost credential,
crash loop, blocked relay, dead sshd all read the same — it opens firewall port
22 at runtime so the operator can still ssh in over the local network and repair
remote management, and closes it within one recheck of the first successful
probe. sshd is key-only, so an engaged failsafe exposes only the ssh handshake
to the local network. This also makes first-time provisioning possible over the
LAN: the first probe runs at boot, so a freshly installed host with no iroh
credential yet (a traffic-free check for the ticket file) has port 22 open
minutes after boot until the secret lands and a rebuild starts the tunnel. The
probe inspects nothing about the listener at all — not even its output: the
ticket it dials is derived from the secret by `iroh-ssh-ticket`, which the
listener runs as an `ExecStartPre` before it binds, publishing to
`/run/iroh-ssh/ticket` (root-only — the failsafe is the only reader). So the
listener stays a faithful dumbpipe derivative and could be swapped for stock
dumbpipe unchanged, and the probed ticket can never name an endpoint the running
listener does not answer on: both come from the same credential, so rotation
moves them together or not at all, and a credential staged for a rotation that
has not happened yet changes nothing. That ticket is also the one operators
distribute, so the probe exercises the path clients actually use — endpoint-id
discovery — rather than a relay url that no distributed ticket contains. The
flip side is that the failsafe is fate-shared with that discovery: while
`dns.iroh.link` is not answering, the tunnel reads as down, which is why the
window is 15 minutes and not 5 (the negative-TTL story is in the `delaySeconds`
option doc). Tune or disable with
`common.irohSsh.failsafe.{enable,delaySeconds,probeIntervalSeconds,recheckIntervalSeconds}`;
the monitoring check reports when the failsafe is engaged.

`iroh-ssh` is wire-compatible with [dumbpipe](https://www.dumbpipe.dev) (same
ALPN and handshake), reduced to the ssh-tunnel use case and split into one
binary per command (`iroh-ssh-listen`, `iroh-ssh-connect`,
`iroh-ssh-generate-secret`, `iroh-ssh-ticket`) so it needs no CLI-parser
dependency. Two changes
from dumbpipe: the listener reads the key from the decrypted systemd credential
(`$CREDENTIALS_DIRECTORY/iroh-secret`) instead of the environment, and relay TLS
is verified against the operating system trust store instead of dumbpipe's
compiled-in Mozilla roots. The trust-store change
is what lets the VM test stay hermetic while server and client run *completely
stock* configuration: the test intercepts the DoH upstream traffic (the same
technique as the `doh-upstream` test), answering the real n0 relay hostnames
with a stand-in `iroh-relay` node whose TLS is trusted via a `security.pki`
test CA. Nothing on the tested node is reconfigured — its real dnscrypt/DoH
resolver, firewall, and default relay selection are exercised as shipped. The
trust-store behavior also means hosts can front a self-hosted relay with a
normally-issued certificate.

The iroh node identity comes from a stable secret key, stored encrypted at rest
with the host's systemd credential key (never in git or the store) and decrypted
by systemd into the unit's runtime credential directory. Provision it once per
host:

```bash
sudo install -d -m 0700 /etc/credentials/iroh-ssh
iroh-ssh-generate-secret \
  | sudo systemd-creds encrypt --name=iroh-secret - /etc/credentials/iroh-ssh/iroh-secret
sudo chmod 0600 /etc/credentials/iroh-ssh/iroh-secret
```

`iroh-ssh-generate-secret` uses iroh's own key generator (so the key is the
right size for whatever iroh version is built in) and prints the node's endpoint
id to stderr while the secret goes to stdout for the pipe. Set
`common.irohSsh.credentialDirectory = "/etc/credentials/iroh-ssh";`. The
`--name=iroh-secret` and the `iroh-secret` filename must match, or systemd
refuses to decrypt it. Until the blob exists the unit skips gracefully
(`ConditionPathExists`) instead of crash-looping.

Read the connect ticket from the running host. It is derived from the secret, so
it is stable across restarts, networks and relay changes — grab it once:

```bash
sudo cat /run/iroh-ssh/ticket
```

This is the canonical form: the endpoint id and nothing else, byte-identical to
the connect command `iroh-ssh-generate-secret` printed when the key was created.
Prefer it over the tickets the listener logs, which also embed the relay urls it
happens to be using at that moment — pinning a client to a relay that may later
go away. The id-only ticket is resolved through endpoint-id discovery instead, so
it keeps working wherever the node moves. `sudo`, not `cat`: the file is public
data but only the failsafe needs it, so it is kept root-only. It is also only
there once the listener has started this boot; when it is not,
`iroh-ssh-ticket` re-derives the same string from the credential
(`docs/rpi5-rescue.md`, "Recovering a lost ticket").

To rotate the key, stage a new credential under a *new* directory and point
`common.irohSsh.credentialDirectory` at it in a commit, rather than overwriting
the blob in place — the switch then restarts the listener as a side effect of the
rebuild, and reverting the commit converges the host back onto a credential that
is still on disk and a ticket you still hold. `docs/rpi5-rescue.md` has the full
flow.

Connect from any machine, no IP address needed (`nix run
github:sashee/nixos-test#iroh-ssh` works in place of an installed
`iroh-ssh-connect`; stock `dumbpipe connect` also accepts the same ticket):

```bash
ssh -o ProxyCommand='iroh-ssh-connect <ticket>' user@laptop
```

`modules/connectivity-watchdog.nix` reboots the host after a sustained DNS
outage. It covers the one failure nothing else here can reach: the machine is on
a network and its wifi stack is healthy, but nothing resolves — a wedged
`dnscrypt-proxy`, a halted brcmfmac firmware, an IPv4LL lease, a broken route.
`modules/connectivity-fallback.nix` deliberately ignores that case (its remedy is
new wifi credentials, which cannot fix a wedged network stack), monitoring can
only report it to a server that is by definition unreachable, and the iroh-ssh
failsafe above only opens a port on the local network — which is no help on a
headless box that nobody shares a LAN with. A reboot does fix those.

On the Pi it resolves one name through the host's own resolver at `127.0.0.1`
every 10 minutes and reboots once nothing has resolved for 3 hours. The fuse
length is the interesting number, because it bounds the cost of the watchdog
being *wrong*: an outage no reboot can fix — a dead ISP — costs one pointless
reboot per threshold for as long as it lasts, so the module defaults to a
conservative 24 hours and the Pi's shorter value is argued for at its call site.
It is not shorter still because a reboot is not free there: `monitoring-platform`
gates its own startup on the clock being synced, so rebooting with no DNS means
it does not come back at all, and a box left alone through an ISP outage keeps
collecting local metrics that a box rebooting through one loses. The 2026-08-22
outage is what moved it off a day — a lease taken from a second router during a
wifi roam left the Pi behind a dead default route, and the watchdog had the right
verdict in the journal within the hour but was 23 hours from acting.

Three details are load-bearing rather than incidental. The query name is a
**fresh random label** under `example.com` on every probe, because
`dnscrypt-proxy`'s cache is keyed on the question and its `cache_max_ttl`
defaults to 86400s — which dwarfs any threshold this module would carry, so one
fixed name could be answered from cache for the entire window, hiding a real
outage. Success is an explicit DNS **rcode**, not `dig`'s exit status: with
every upstream unreachable `dnscrypt-proxy` answers SERVFAIL, which is a
perfectly valid response, so `dig` exits 0 and an offline box would read as
healthy. And the age is measured in **monotonic uptime**, never the wall clock,
so NTP stepping the clock on a Pi 5 with no RTC battery cannot be mistaken for
hours without DNS. The verdict is left in the journal rather than a breadcrumb
file (journald is persistent by default), readable after the fact with
`journalctl -b -1 -u connectivity-watchdog`.

It is **off by default** — a laptop merely closed for two days must not reboot
itself — and enabled only on the Raspberry Pi host. Evaluation fails unless
`services.dnscrypt-proxy` is enabled (`modules/doh.nix`), since without a local
resolver every probe would fail and a perfectly healthy machine would reboot on
a timer. Tune with
`common.connectivityWatchdog.{enable,afterSeconds,intervalSeconds,accuracySeconds}`.

`modules/fonts.nix` contains common desktop fonts.

`modules/development-base.nix` contains common CLI tools and direnv with
nix-direnv.

`modules/nix-utils.nix` installs the full sandboxed utility environment from
the `github:sashee/dotfiles/bwrap` flake input's `nix-utils` directory with
this flake's `pkgs`, `unstable = pkgs`, and `nixgl = null` for native NixOS
graphics.

`modules/nix-settings.nix` enables flakes, nix-command, store
optimisation, and automatic garbage collection.

## QEMU VM

The `nix` commands below pass `--extra-experimental-features 'nix-command
flakes'`, so they work even if flakes are not enabled in your `nix.conf`. To
avoid repeating the flag, enable them permanently by adding this line to
`~/.config/nix/nix.conf` (or `/etc/nix/nix.conf`):

```text
experimental-features = nix-command flakes
```

The `./result/bin/run-nixos-qemu-vm` runner needs no Nix flags at all.

Build the graphical VM:

```bash
nix --extra-experimental-features 'nix-command flakes' build .#qemu-vm
```

Run it:

```bash
./result/bin/run-nixos-qemu-vm
```

Try GL acceleration for Plasma:

```bash
QEMU_OPTS="-display gtk,gl=on -device virtio-vga-gl" ./result/bin/run-nixos-qemu-vm
```

The VM starts Plasma Wayland in a QEMU window and logs in as `demo`
automatically.

The real laptop host configs boot the same way — e.g. anya-feher-laptop
(autologin as `anya`, Hungarian locale and keyboard; the lock screen password
is `anya` in the VM only — the real machine's password is set at install):

```bash
make host-vm HOST=anya-feher-laptop   # or: nix --extra-experimental-features 'nix-command flakes' build .#anya-feher-laptop-vm
./result/bin/run-anya-feher-laptop-vm
```

The same `QEMU_OPTS` variants (GL, TCG) apply to this runner too.

Check rendering inside the VM:

```bash
glxinfo -B
```

`virgl` in the renderer usually means accelerated virtual graphics are working. `llvmpipe`, `softpipe`, or `Software Rasterizer` means rendering is happening on the CPU.

Manual login details, if needed:

```text
user: demo
password: demo
```

If QEMU complains about KVM permissions, either add your host user to the `kvm` group or run without KVM:

```bash
QEMU_OPTS="-accel tcg" ./result/bin/run-nixos-qemu-vm
```

## The rpi5 config on x86

Most of what the rpi checks assert is arch-independent configuration — the DoH
egress rules, the default-deny firewall, the connectivity-fallback trigger logic,
the `--delete-old` GC policy, the reboot-on-change decision, the time chain. So the
same `rpi5HostModules` the deployed Pi composes is also built as an x86 check set,
`lib.checkSets.rpi5-x86`, and runs under KVM in minutes:

```bash
make run-rpi-x86-tests
```

That is possible because `rpi5HostModules` is deliberately hardware-free: the
`nixos-raspberrypi` modules (`sd-image`, `raspberry-pi-5.base`) are added only by
`mkRpi5`. Exactly three things are neutralized for x86 (`rpi5X86Kernel` in
`flake.nix`): the `headless-trim` kernel patch is dropped so the node lands on the
cached stock kernel, `common.requiredKernelModules` is switched off because its list
is the Pi's hardware, and `rtc_cmos` is added to the initrd — the direct analogue of
the aarch64 nodes' `rtc-pl031`, without which the clock jumps in stage-2 and wakes
Persistent timers mid-test (`rpi5-x86-boot-clock` is the guard).

**A green run here is not a substitute for `make run-rpi-tests`.** It is not the Pi's
kernel (BTF is on here and off there, and the module set is a different one), not
aarch64, and not even the same nixpkgs — the aarch64 checks evaluate against
`nixos-raspberrypi.inputs.nixpkgs`, these against this flake's own, so package
versions and the systemd under test differ in both directions. Kernel-dependent
behaviour is aarch64-only by construction, which is why `required-kernel-modules`
has no x86 twin at all.

This set is also where the host-independent x86 checks live — `monitoring-platform*`,
`monitoring-nix-gc`, `monitoring-iroh-ssh` and `connectivity-fallback-timing`, under
unprefixed names because none of them runs on the rpi5 node. They are here because
the Pi is the host that deploys their subject and this is the leg that already has
KVM; each has an aarch64 twin in `lib.checkSets.rpi5`.

## Running the rpi tests locally

For an arch-independent change, try `make run-rpi-x86-tests` above first — it needs
none of the setup below. The rest of this section is for the run that decides.

The aarch64 checks boot the exact patched rpi kernel, which is in no binary
cache — built from scratch it takes hours under emulation. CI does not publish
it: every rpi shard compiles it natively on its own arm64 runner, because
hoisting the build into a shared job and passing the result along was measured
to save no wall clock (see "CI sharding" below).

If you have access to any aarch64 machine that can build it (a Pi, an arm64
cloud box, a CI runner you control), you can move the kernel to your laptop
instead of compiling it under emulation:

```bash
# on the aarch64 machine:
make export-rpi-kernel                      # -> ./rpi-kernel-cache

# on the laptop, once per flake.lock / kernel-config change:
make import-rpi-kernel CACHE=rpi-kernel-cache
make run-rpi-tests
```

`import-rpi-kernel` first evaluates the kernel paths locally, so it fails
loudly if the cache was produced from a different flake.lock or kernel
config instead of importing a stale kernel. Both targets handle every output of
the kernel derivation (`out`, `dev`, `modules`); moving only `out` leaves the
derivation unbuilt as far as nix is concerned, and the next `run-rpi-tests`
recompiles the kernel to produce the missing outputs. The host also needs to be
able to build the remaining (cheap) aarch64 derivations, e.g. on NixOS:

```nix
boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
```

Note the checks use aarch64 `hostPkgs`, so the test driver and QEMU themselves
run under binfmt user emulation on x86 — correct but slow; expect much longer
runtimes than CI's native arm64 runner.

## Running the tests

The checks are partitioned into named sets (`lib.checkSets`), one per CI leg —
except `rpi5`, which CI splits across four legs (see "CI sharding" below). Every
check belongs to exactly one set — a check outside every set is never built by CI. Each suite runs with live logs, one check at a time (this is what CI runs;
evaluating every check in a single nix process peaks at ~15 GiB, so each check
gets its own short-lived eval+build process):

```bash
make run-eval-tests                        # lib.checkSets.eval
make run-host-tests HOST=anya-feher-laptop # lib.checkSets.anya-feher-laptop
make run-rpi-x86-tests                     # lib.checkSets.rpi5-x86
make run-rpi-tests                         # lib.checkSets.rpi5 (aarch64)
```

`run-eval-tests` is the quick one: those checks are `runCommand`s that assert on
pure data (DoH stamps, NTS server lists) and on the deployed host configs without
building a machine image, so they need no KVM and finish in about a minute. They
are their own set precisely so a data drift reports immediately instead of behind
a VM suite.

There is deliberately no generic suite. A check for a shared module belongs to the
set of a host that deploys it, so a failure names the config it broke; the shared
desktop payload, for instance, is asserted by `anya-feher-laptop-common-desktop`.
The two exceptions ride the `rpi5-x86` leg under unprefixed names because they are
host-independent but still need a KVM leg: see the header on `rpi5X86Checks` in
`flake.nix`.

### CI sharding

GitHub's hosted arm64 runners expose no `/dev/kvm`, so the aarch64 guests run
under TCG. The `rpi5` set takes about 4.5 hours that way, and with the kernel
build in front of it the single job hit GitHub's 6-hour limit on its last check.
CI therefore runs the set across four `checks (rpi5 N/4)` legs, each compiling
the kernel on its own runner. They are entries in the same matrix as the
unsharded legs: a leg declares `shard: i/n` only if it wants splitting, and
everything else defaults to `1/1`.

Building the kernel once in a preceding job and handing it to the shards was
measured to save nothing: the ~1.5-hour compile is on the critical path either
way — serialized in front of the shards, or in parallel inside them — so the
artifact bought about two minutes of upload/download in exchange for a job
dependency and three extra kernel compiles' worth of runner time. The only thing
that would lower that floor is a cache that survives *between* runs.

The shards run the same checks at the same CPU share as before — nothing runs
concurrently *within* a runner, which would eat into the TCG timing margin that
`ATTEMPTS` already covers. Which checks a shard runs is derived, never listed:

```bash
make run-checks SYSTEM=aarch64-linux SET=rpi5 SHARD=3/4
```

takes every 4th name of `lib.checkSets.rpi5`, so a check added to the flake lands
in a shard with no CI change. `SHARD` is one `i/n` field rather than an index and
a total, so the two cannot drift apart: a matrix listing `1/4 2/4 3/4 4/4` states
the total on every line. The split is round-robin over the alphabetical names
rather than balanced by runtime, which would mean checking in a table of measured
durations that silently goes stale; raising `n` is the cheaper knob. Omitting
`SHARD` (the default, `1/1`, and what `make run-rpi-tests` does) runs the whole
set. A malformed `SHARD`, an `i` outside `1..n`, or a shard that would run nothing
is an error, not a green leg.

Each check's output lands under `results/<system>/<check-name>`, e.g.:

```text
results/x86_64-linux/anya-feher-laptop-doh
results/x86_64-linux/rpi5-x86-firewall
results/x86_64-linux/anya-feher-laptop-plasma-firefox/plasma-desktop.png
results/x86_64-linux/anya-feher-laptop-plasma-firefox/firefox-page.png
```

Checks get two attempts when `SYSTEM=aarch64-linux` and one otherwise, because the
reason for the retry is the system: the aarch64 CI runner has no KVM and its TCG
guests are slow enough to lose races the x86 runs win. A check that only passed on
the retry prints `=== FLAKY: <name> passed on attempt 2 of 2`, so retries stay
visible in the log rather than silently absorbing an unstable test. A failure on an
x86 suite is a real failure; pass `ATTEMPTS=2` explicitly to retry one by hand.

Many tests also exist as `<name>-driver-interactive` packages built on the generic
desktop node (the cheapest one to boot by hand). Those are debugging entry points,
**not** coverage: they are in no check set, so CI never builds them. Each is covered
by its `anya-feher-laptop-*` or `rpi5-x86-*` twin.

The default package is the graphical QEMU VM runner (no tests):

```bash
nix --extra-experimental-features 'nix-command flakes' build -L
./result/bin/run-nixos-qemu-vm
```

Tests live under `tests/`. Run one test during development by building its check:

```bash
nix --extra-experimental-features 'nix-command flakes' build -L .#checks.x86_64-linux.plasma-firefox
nix --extra-experimental-features 'nix-command flakes' build -L .#checks.x86_64-linux.common-desktop
nix --extra-experimental-features 'nix-command flakes' build -L .#checks.x86_64-linux.doh
nix --extra-experimental-features 'nix-command flakes' build -L .#checks.x86_64-linux.doh-upstream
nix --extra-experimental-features 'nix-command flakes' build -L .#checks.x86_64-linux.doh-captive
nix --extra-experimental-features 'nix-command flakes' build -L .#checks.x86_64-linux.nm-captive-portal
nix --extra-experimental-features 'nix-command flakes' build -L .#checks.x86_64-linux.firewall
nix --extra-experimental-features 'nix-command flakes' build -L .#checks.x86_64-linux.locale-firefox
nix --extra-experimental-features 'nix-command flakes' build -L .#checks.x86_64-linux.restic
```

Tests always run one at a time — each loop iteration builds a single check, so
`--max-jobs` (default `auto`) only parallelizes dependency builds within that
check. On a RAM-constrained machine, serialize those too:

```bash
make run-host-tests HOST=anya-feher-laptop MAX_JOBS=1
```

`doh-upstream` is hermetic: it routes `doh-test` default IPv4 traffic through
`dns-peer`, redirects outbound HTTPS there, and verifies that a local DNS query
becomes an HTTPS `/dns-query` request to one of the configured DoH hostnames.

`time-correction` and `nts-sync` are hermetic in the same way and are among the
slowest checks in the suite — six and four VMs, both existing on x86 and aarch64.
`time-correction` covers the time-correction service in isolation against
impersonated DoH resolvers and NTS servers, including the cases that only ever
matter once: an expired certificate on either leg while that server's clock stays
correct (so the answer it gives is right and must still be refused), a time below
the build-time floor (refused before any chain is re-verified against it), one
provider of two failing (which fails the whole run), a clock already inside the
certificates' validity (left alone) and one outside it (set), no reachable
resolver at all (a visibly failed unit with the timer still armed), v4-only,
v6-only and NTS-reachable-only-over-v6 hosts, and a server that redirects
timestamping to a second hostname — the shape `nts.netnod.se` has in production,
proved followed rather than ignored by logging every name the impersonated
resolver was asked for. It also pins that the `time-correction` wrapper on `PATH`
execs exactly the unit's argument vector, since that wrapper is what the Pi is
driven by hand with. `nts-sync` boots a machine years out of date on the deployed
configuration and asserts it climbs out on its own, then that chrony records and
restores its last known good time (forward only), reports itself synchronised to
the kernel (`rtcsync`, which is what keeps a laptop's RTC current for the next
boot), refuses a falseticker, keeps cookies across a reboot, will not fall back to
unauthenticated NTP when NTS-KE is blocked, and — at the deployed `sample = 2`,
which is the only place that configuration is exercised — that the correction
service refuses to set a clock from two operators that disagree. Their aarch64
variants get a raised `globalTimeout` (1800s and 2400s), since under TCG a run of
either is measured in tens of minutes, and their `anya-feher-laptop-` variants get
1800s for booting the full autologin desktop three times over.

Both of those override the timer's cadence so a timed run cannot land in the
middle of a subtest that places the clock by hand, and both override the server
list and the floor so their impersonated providers are the ones dialled — which
leaves the values the hosts actually ship uncovered by either.
`time-sync-deployed` is the eval-only check that closes that. It renders
`time-correction.timer` from both deployed host configs and asserts
`OnBootSec=1min`, `OnUnitActiveSec=1h`, no `OnCalendar` and no `Persistent`; it
renders `time-correction.service` and asserts the argument vector — one `--nts`
per entry of `lib/nts-servers.nix` with its operator, one `--doh` per provider in
`lib/doh-stamps.nix` with both families, `--sample 2`, `--tolerance 60`,
`--timeout 10`, and a `--floor` that is present and numeric. It also asserts, on
each host that deploys the metrics producer, that `system-metrics.service` is in
one of its two valid shapes and fully in that one: either gated on exactly
`ConditionPathExists=<the chrony marker>` when it posts straight at a receiver —
the two-line `mkDefault` in `modules/time-sync.nix` whose failure is silent in
both directions — or, when `mp-collector` is in the path, carrying **no**
condition at all *and* posting at the collector's socket. Both halves of that
second shape are needed: a producer with the gate dropped but still aimed at the
receiver has the worst of both, writing 1970-dated rows nothing will correct.
No VM test covers this on a host anyone deploys. All of these throw during
evaluation on drift. It reads the rendered units rather than
`common.timeSync.interval`, since the claim worth making is that systemd was told
the value, not that the option holds it. The count assertions are the load-bearing
half: `selected` in `modules/time-sync.nix` filters `lib/nts-servers.nix` by
`cfg.servers` while chrony reads `cfg.servers` directly, so a hostname that stops
matching leaves chrony using the name while time-correction silently loses that
operator. That the wrapper on `PATH` carries the same arguments as the unit is
asserted in `time-correction` itself, where both are observable.

`nix flake check` also works, but it evaluates every check in one nix process
(~15 GiB peak) and leaves no output symlinks — prefer the `make run-*` targets,
which keep the collected outputs and screenshots under `results/`.

Build the interactive test driver:

```bash
nix --extra-experimental-features 'nix-command flakes' build .#plasma-firefox-driver-interactive
```
