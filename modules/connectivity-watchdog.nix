{ config, lib, pkgs, ... }:

let
  cfg = config.common.connectivityWatchdog;

  # Where the last successful probe's UPTIME is recorded. /run, not /var/lib, and that is
  # load-bearing rather than incidental -- see the comment on `since` in the script below.
  runtimeDir = "connectivity-watchdog";
  marker = "/run/${runtimeDir}/last-success";

  # Hardcoded, not options, because neither will ever change and each would be a footgun:
  #
  #  * The resolver must be the host's own. modules/doh.nix rejects port 53 to anything but
  #    loopback (chain common-doh-egress), so an externally-pointed probe would fail every
  #    time and reboot a box whose internet is perfectly fine.
  #  * The query domain must not be one of the names in lib/captive-portals.txt, which
  #    dnscrypt-proxy answers locally at all times with no internet -- exactly how the
  #    2026-07-27 outage was able to hide. Fixing the domain here makes that unreachable
  #    by configuration.
  resolver = "127.0.0.1";
  queryDomain = "example.com";

  probe = pkgs.writeShellApplication {
    name = "connectivity-watchdog";
    runtimeInputs = [ cfg.tools.dig cfg.tools.coreutils cfg.tools.gnused cfg.tools.systemd ];
    text = ''
      # Resolve one name through this host's own resolver. A DoH answer proves the whole
      # path the box depends on -- dnscrypt-proxy, TCP 443 egress, TLS, and a live upstream
      # -- and dnscrypt already spreads its queries over the four independent operators in
      # lib/doh-stamps.nix, so no single provider's outage can drive a reboot.
      #
      # Deliberately NOT the trigger for wifi setup mode: that decision is local-only (see
      # modules/connectivity-fallback.nix), because new credentials cannot fix an ISP
      # outage. This is the other half -- associated and iwd-healthy, but the stack is
      # wedged (brcmfmac firmware halt, wedged dnscrypt, an IPv4LL lease, a broken route).
      # A reboot does fix those, and nothing else on the box would ever notice.

      # Indeterminate beats wrong: if the probe cannot run at all, decide nothing. Rebooting
      # every ${toString cfg.afterSeconds}s would fix no missing binary. Same rule as the
      # `iw` fail-safe in connectivity-fallback.nix.
      #
      # Narrower than it looks: writeShellApplication pins tools.dig on PATH, so this cannot
      # fire on a system that merely lacks dnsutils. What it catches is tools.dig overridden
      # with a package that ships no `dig` -- without it errexit would kill the script at the
      # probe below and the unit would just go `failed`, which is silent in the same way.
      if ! command -v dig >/dev/null; then
        echo "connectivity-watchdog: dig unavailable; NOT deciding"
        exit 0
      fi

      # MONOTONIC, never the wall clock. Recording an epoch and diffing it against
      # `date +%s` would make a forward clock correction indistinguishable from an outage:
      # a Pi 5 with no RTC battery boots with a stale clock, a probe succeeds and records
      # it, NTP then steps the clock past the threshold, and the next failed probe reboots
      # a healthy box. Uptime cannot step. It also puts the marker and the clock in one
      # domain -- both reset at boot.
      now="$(cut -d' ' -f1 /proc/uptime | cut -d. -f1)"

      # A UNIQUE label every time. dnscrypt-proxy's cache is keyed on the question, so a
      # name never asked before cannot be a hit, positive or negative -- which is what
      # stops a cached answer masking a real outage. It matters here specifically because
      # dnscrypt's cache_max_ttl defaults to 86400s, which dwarfs any threshold this module
      # would sensibly carry -- the 24h default, the 3h hosts/rpi5 deploys -- so one fixed
      # name could be served from cache for the entire window whichever is chosen.
      #
      # This is sufficient because of WHAT dnscrypt-proxy is: a forwarding proxy with a
      # question-keyed response cache, require_dnssec = false, no validation of its own. A
      # *validating* resolver using RFC 8198 aggressive NSEC can synthesise NXDOMAIN for
      # names it has never queried, out of a cached NSEC range -- that would defeat random
      # labels completely. If the DNS layer is ever swapped (unbound with
      # `aggressive-nsec: yes`, knot-resolver), this reasoning has to be revisited.
      name="$(cat /proc/sys/kernel/random/uuid).${queryDomain}."

      # Success is an explicit rcode, NOT dig's exit status. With every upstream
      # unreachable dnscrypt-proxy answers SERVFAIL, which is a perfectly valid DNS
      # *response*, so dig exits 0. Treating "dig succeeded" as success would make an
      # offline box read as healthy and this failsafe would never once fire -- silently,
      # with nothing in the journal to suggest it. NXDOMAIN is success on purpose: a random
      # label under ${queryDomain} does not exist, and getting that answer back proves the
      # round-trip to a real upstream happened.
      # `|| true` is load-bearing, not defensive noise. writeShellApplication sets
      # `pipefail` and `errexit`, and dig exits 9 when it gets no reply at all -- so
      # without this the script would DIE on the single most important failure mode
      # (resolver gone), the unit would just go `failed`, and the reboot would never
      # happen. An empty $status then means "no response", handled below.
      status="$(dig +tries=2 +time=5 @${resolver} -t A "$name" 2>/dev/null \
        | sed -n 's/^;; ->>HEADER<<-.*status: \([A-Z]*\).*/\1/p' || true)"

      case "$status" in
        NOERROR | NXDOMAIN)
          printf '%s\n' "$now" > "${marker}.tmp"
          mv -f "${marker}.tmp" "${marker}"
          echo "connectivity-watchdog: resolved via ${resolver} ($status); nothing to do"
          exit 0
          ;;
      esac
      echo "connectivity-watchdog: probe failed (status=''${status:-no-response})"

      # The marker can only have been written during THIS boot, so the uptime it holds is
      # always <= the current uptime. "no success for >= threshold" therefore already
      # implies "up for >= threshold", and the whole max(last_boot, last_success) term
      # collapses into this one comparison: a tight reboot loop is structurally impossible
      # rather than merely guarded against, because a freshly booted box cannot have
      # accumulated enough age to qualify. An absent marker means no success since boot,
      # so the current uptime is itself the correct age.
      #
      # Content-checked, not merely `-r`. An empty or truncated marker would expand to
      # `$(( now -  ))`, and under errexit that syntax error KILLS the script before the
      # reboot below -- disabling the failsafe exactly as a `failed` unit would, and for the
      # same reason the dig pipeline needs its `|| true`. Falling back to the uptime is the
      # safe direction: an unusable marker carries no evidence of a success, which is what
      # the absent-marker branch already assumes.
      last=""
      if [ -r "${marker}" ]; then
        last="$(cat "${marker}")"
      fi
      case "$last" in
        "" | *[!0-9]*) since="$now" ;;
        *) since=$(( now - last )) ;;
      esac

      if [ "$since" -lt ${toString cfg.afterSeconds} ]; then
        echo "connectivity-watchdog: ''${since}s of ${toString cfg.afterSeconds}s without DNS; nothing to do"
        exit 0
      fi

      # Nothing but the log line and the reboot. There is deliberately no breadcrumb file:
      # journald is persistent by default (services.journald.storage), so this verdict is
      # already readable after the reboot via `journalctl -b -1 -u connectivity-watchdog`.
      # A file would also be actively harmful here -- written under errexit immediately
      # before the reboot, a failed redirect on a full or read-only /var would abort the
      # script and cancel the reboot, disabling the failsafe in precisely the degraded
      # conditions it exists for (this box has a documented SD disk-full history).
      echo "connectivity-watchdog: no DNS for ''${since}s; rebooting"
      systemctl reboot
    '';
  };
in
{
  options.common.connectivityWatchdog = {
    # Last resort for the one failure this repo otherwise has no answer to: the machine is
    # on a network and its wifi stack is healthy, but nothing resolves. The wifi setup
    # fallback deliberately ignores that case (its remedy is new credentials, which cannot
    # fix a wedged network stack), monitoring can only report it to a server that is by
    # definition unreachable, and the iroh-ssh failsafe only opens a LAN port. Off by
    # default: a laptop merely closed for two days must not reboot itself.
    enable = lib.mkEnableOption "rebooting the host after a sustained DNS resolution outage";

    afterSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 86400;
      description = ''
        How long DNS must have been failing, in seconds, before the host reboots.

        This is the fuse length, and what it buys is a bound on the cost of being WRONG. The
        remedy is drastic and the trigger consults the network, so a signal that has rotted --
        or an outage no reboot can fix, like a dead ISP -- costs one pointless reboot per
        threshold, forever. At the default day that is one a day; the value to keep away from
        is the reboot every 15m23s that modules/connectivity-fallback.nix caused on 2026-07-27.

        Which means the right value is per host, not universal, and the default is deliberately
        the conservative end for a host nobody has reasoned about. Shortening it trades that
        bound for downtime on a wedge a reboot DOES fix, and what sets the exchange rate is
        what a reboot costs the host: on hosts/rpi5 a reboot with no DNS means
        monitoring-platform does not come back at all (it gates startup on the clock being
        synced), so rebooting through an ISP outage destroys the local metrics that surviving it
        would have kept -- see the reasoning at its call site for why it still runs 3h.

        Seconds rather than a systemd duration string because the check does integer arithmetic
        on it.

        Must also outlast a boot, which is why the assertions below impose a floor. On the
        boot AFTER a watchdog reboot there is no /run marker, so the age is the uptime
        itself -- set this below a slow boot and the first probe of the new boot is already
        over the threshold, turning the one thing this module structurally prevents (see
        `since` above) back into a reboot loop.
      '';
    };

    intervalSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3600;
      description = ''
        How often to probe, in seconds (OnBootSec and OnUnitActiveSec on the timer).

        Bounds how late the reboot can be: the host reboots within afterSeconds +
        intervalSeconds + accuracySeconds of DNS breaking. So this is worth keeping small
        relative to afterSeconds -- at the deployed 600s against a 3h fuse it adds ~11 minutes
        to a 3h wait -- but there is no value in going far below that, because the decision is
        about hours and every probe is a real DNS exchange with a real timeout.

        Seconds rather than a systemd duration string so the assertions below can relate it
        to afterSeconds and accuracySeconds; a string leaves the constraints stated in prose
        and unchecked.
      '';
    };

    accuracySeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = ''
        AccuracySec on the timer, in seconds. Loose by default on purpose: it lets systemd
        coalesce this probe with other timers instead of waking the box alone for it, and 1m
        of jitter is noise against a threshold of a day.

        systemd places the expiry anywhere in [elapse, elapse + accuracySeconds], at a
        host-stable position synchronized across local timer units -- effectively a grid of
        this size. So an intervalSeconds that is not a multiple of it does not mean what it
        says: every nominal elapse lands between grid points and is pushed to the next one,
        and the real cadence is neither value. Both that and "no coarser than the interval"
        are asserted below. At the deployed 600/60 the interval is an exact multiple and
        firings land on grid points with no drift; it is the shortened intervals in
        tests/connectivity-watchdog.nix that need this turned down, and before it was
        configurable that test's 20s interval was silently a 60s one.
      '';
    };

    tools = {
      dig = lib.mkPackageOption pkgs "dig" { default = [ "dnsutils" ]; };
      coreutils = lib.mkPackageOption pkgs "coreutils" { };
      gnused = lib.mkPackageOption pkgs "gnused" { };
      systemd = lib.mkPackageOption pkgs "systemd" { };
    };
  };

  config = lib.mkIf cfg.enable {
    # Without a local resolver every probe fails, so the host reboots every afterSeconds
    # forever while its network is perfectly fine -- the same shape as the 2026-07-27
    # bootloop, and just as invisible from the box itself. dnscrypt-proxy specifically,
    # not merely "something on 127.0.0.1": the probe's whole rationale rests on what it is
    # (a forwarding proxy with a question-keyed cache and no DNSSEC validation, spreading
    # queries over four independent operators). A validating resolver with RFC 8198
    # aggressive NSEC would answer random labels from cache and quietly defeat the probe --
    # see the comment on `name` above. This assertion is what stops one being substituted.
    #
    # The four timing assertions after it exist because every one of them fails INVISIBLY:
    # the timer is well-formed, the unit runs, the journal looks right, and only the cadence
    # or the fuse length is not what the file says. Same reason modules/connectivity-fallback.nix
    # guards its own options at eval time rather than trusting the runtime to complain.
    assertions = [
      {
        assertion = config.services.dnscrypt-proxy.enable;
        message = "common.connectivityWatchdog probes 127.0.0.1 for DNS and expects dnscrypt-proxy to answer it (modules/doh.nix). Without it every probe fails and the host reboots every common.connectivityWatchdog.afterSeconds forever, on a healthy network.";
      }
      {
        assertion = cfg.accuracySeconds <= cfg.intervalSeconds;
        message = "common.connectivityWatchdog.accuracySeconds (${toString cfg.accuracySeconds}) must not exceed intervalSeconds (${toString cfg.intervalSeconds}): systemd would place every expiry on a grid coarser than the interval, so the real probe cadence is accuracySeconds and the configured interval means nothing.";
      }
      {
        # Same reasoning one step further: a non-multiple pushes every nominal elapse to the
        # next grid point, so the effective cadence is neither configured value.
        assertion = lib.mod cfg.intervalSeconds cfg.accuracySeconds == 0;
        message = "common.connectivityWatchdog.intervalSeconds (${toString cfg.intervalSeconds}) must be a multiple of accuracySeconds (${toString cfg.accuracySeconds}): otherwise each nominal elapse lands between grid points and is pushed to the next one, and the effective cadence is neither of the two configured values.";
      }
      {
        # One failed probe must never be enough -- that is the whole difference between this
        # module and the 2026-07-27 bootloop.
        assertion = cfg.intervalSeconds < cfg.afterSeconds;
        message = "common.connectivityWatchdog.intervalSeconds (${toString cfg.intervalSeconds}) must be below afterSeconds (${toString cfg.afterSeconds}): otherwise the very first probe of a boot is already at or past the threshold, so a single failed probe reboots the host.";
      }
      {
        # See the `afterSeconds` description: with no marker the age IS the uptime, so a
        # threshold shorter than a slow boot reboots the host again on its first probe.
        # Measured boots: ~60s on the Pi, 250-390s for the TCG VM tests -- hence 600, which
        # is also the value tests/connectivity-watchdog.nix picked for the same reason.
        assertion = cfg.afterSeconds >= 600;
        message = "common.connectivityWatchdog.afterSeconds (${toString cfg.afterSeconds}) must be at least 600: on the boot after a watchdog reboot there is no /run marker, so the age is the uptime itself, and a threshold shorter than a slow boot reboots the host again on its first probe -- a loop.";
      }
    ];

    systemd.services.connectivity-watchdog = {
      description = "Reboot if DNS resolution has been failing for too long";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe probe;
        RuntimeDirectory = runtimeDir;
        # Preserved across invocations on purpose: this oneshot's whole state is the marker
        # in there, and the default (remove when the unit stops) would wipe it every run.
        RuntimeDirectoryPreserve = true;
        # dig's own budget is +time=5 x +tries=2 per address family; leave room for both
        # plus process spawn, but stay well under intervalSeconds so runs cannot pile up.
        TimeoutStartSec = "60s";
      };
    };

    systemd.timers.connectivity-watchdog = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "${toString cfg.intervalSeconds}s";
        OnUnitActiveSec = "${toString cfg.intervalSeconds}s";
        AccuracySec = "${toString cfg.accuracySeconds}s";
        # No Persistent: catching up on missed runs after downtime is meaningless when the
        # whole question is "how long has this boot been without DNS".
        Unit = "connectivity-watchdog.service";
      };
    };
  };
}
