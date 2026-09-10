{ config, lib, pkgs, ... }:

let
  cfg = config.common.nixSettings;

  # nix-gc must not collect while an upgrade is mid-flight. modules/auto-upgrade.nix builds
  # the new system one derivation per `nix` process and deliberately keeps no GC roots
  # between those invocations, so a concurrent collect deletes outputs from under the loop
  # and the upgrade fails. spec/features/gc.md: "it does not run if the nixos-upgrade script
  # is running".
  #
  # Three systemd details this spelling exists to dodge, all measured on the Pi rather than
  # assumed (see the probe notes in the commit that added this):
  #
  #   * a script, NOT `ExecCondition=! systemctl ...`. A leading `!` in an Exec* line is
  #     systemd's *privilege* prefix, not shell negation, so that spelling silently inverts
  #     the test into "collect only while upgrading". (`Condition*=` directives do support
  #     `!`; the Exec* family does not.)
  #
  #   * `ActiveState`, NOT `systemctl is-active`. is-active exits 3 for BOTH `inactive` and
  #     `activating`, so it cannot tell idle from busy. That distinction is the whole point
  #     here: the upgrade spends its entire multi-hour prebuild -- lock update, eval, and the
  #     one-by-one build loop -- in ExecStartPre, i.e. `activating`.
  #
  #   * `exit 1`, never 255 and never a signal. 1-254 makes systemd *skip* the unit
  #     (ActiveState=inactive, Result=success); 255 or a signal makes it *fail*.
  #
  # Not a lock: this samples state, so a GC and an upgrade starting in the same instant can
  # still race. That residual case is the one spec/features/gc.md already tolerates (the
  # upgrade fails and the next GC cleans up). The far more likely ordering -- a GC already
  # running when the upgrade is triggered -- is handled on the other side, by the upgrade's
  # After=nix-gc.service making it wait for the in-flight run.
  skipIfUpgrading = pkgs.writeShellApplication {
    name = "nix-gc-skip-if-upgrading";
    runtimeInputs = [ config.systemd.package ];
    text = ''
      state="$(systemctl show nixos-upgrade.service --property=ActiveState --value)"
      case "$state" in
        # Empty covers hosts that do not have the unit at all (auto-upgrade disabled).
        inactive | failed | "")
          exit 0
          ;;
        *)
          echo "nix-gc: nixos-upgrade.service is $state; skipping this run"
          exit 1
          ;;
      esac
    '';
  };
in
{
  options.common.nixSettings = {
    gcOptions = lib.mkOption {
      type = lib.types.str;
      default = "--delete-older-than 14d";
      example = "--delete-old";
      description = ''
        Arguments passed to nix-collect-garbage for the automatic GC. Default keeps
        14 days of generations (laptops, which have a boot menu to roll back from).
        Hosts with no interactive boot selection and tight disk (e.g. the Pi) can
        use "--delete-old" to keep only the current generation.
      '';
    };

    gcDates = lib.mkOption {
      type = lib.types.str;
      default = "weekly";
      example = "daily";
      description = ''
        systemd calendar expression for the periodic GC (spec/features/gc.md: "plus there
        is a weekly gc"). This is the backstop only -- the two GCs that matter in practice
        are the post-boot one (gcOnBootDelay) and the one the auto-upgrade pulls in before
        it starts building.
      '';
    };

    gcOnBootDelay = lib.mkOption {
      type = lib.types.str;
      default = "15min";
      description = ''
        Delay after boot before the GC runs (spec/features/gc.md: "after boot it deletes
        old generations and runs gc"). Deliberately longer than a VM test's guest runtime:
        the boot trigger fires in every test that boots, so a short delay would have GC
        competing with tests that previously only had to dodge a fixed clock slot (see the
        note in lib/test-rtc-base.nix).

        Note this is additive to the timer's Persistent=true, which already replays a
        *missed* periodic slot after boot; OnBootSec covers boots where nothing was missed.
      '';
    };
  };

  config = lib.mkMerge [
    {
      nix = {
        gc = {
          # Must stay true even though the schedule is overridden below:
          # modules/monitoring.nix gates its GC health check on config.nix.gc.automatic, so
          # turning this off makes the check silently *skip* rather than fail.
          automatic = true;
          options = cfg.gcOptions;
          dates = cfg.gcDates;
        };

        settings = {
          auto-optimise-store = true;
          # Fsync store path contents before registering them in the Nix DB, so a
          # power cut mid-upgrade/GC can't leave a path registered as valid with
          # non-durable contents. Costs some write speed on builds/substitutions.
          fsync-store-paths = true;
          experimental-features = [ "nix-command" "flakes" ];
        };
      };

      # spec/features/gc.md, Auto build cleanup. Nix removes a build directory when a build
      # ends normally, but not when the process is SIGKILLed -- so an OOM-killed or power-cut
      # build leaves its whole tree behind, and nothing else ever reclaims it:
      # nix-collect-garbage ignores these (they are not store paths). One OOM-killed kernel
      # build on the Pi left 1.7 GB sitting there, still present hours and several GCs later,
      # on a 29 GB SD card where a full disk has previously corrupted the nix database.
      #
      # tmpfiles rather than a unit of our own, for two reasons. NixOS already expresses
      # exactly this for the sibling directories -- `R! /nix/var/nix/gcroots/tmp` and
      # `R! /nix/var/nix/temproots` in 00-nixos.conf -- and `builds` looks simply to have
      # been missed when nix moved build directories out of /tmp (where
      # boot.tmp.cleanOnBoot used to handle them) into /nix/var. And systemd-tmpfiles-setup
      # runs inside sysinit.target, which is before nix-daemon.socket and long before
      # nixos-upgrade, so the spec's "the auto-upgrade does not start before the directory is
      # cleaned" comes for free rather than needing Before= wiring that could rot.
      #
      # `R!` is boot-only and recursive, and it removes the directory *itself*, not just its
      # contents (both measured). The `d` line puts it back: nix would very likely recreate
      # it, as it does for temproots, but tmpfiles runs its remove phase before its create
      # phase (also measured), so pairing them costs nothing and removes the assumption.
      #
      # Not gated on nix.gc.automatic: this is unrelated to collection, and a host with GC
      # disabled needs it just as much. Accepted consequence: a leak from an interruption
      # that does *not* reboot persists until the next boot.
      systemd.tmpfiles.rules = [
        "R! /nix/var/nix/builds - - - - -"
        "d /nix/var/nix/builds 0755 root root -"
      ];
    }

    # Guarded on nix.gc.automatic even though it is set true just above, because a host or
    # test can force it off (tests/monitoring/rpi.nix and tests/monitoring/restic.nix both
    # do). nixpkgs only defines the nix-gc units when automatic is set, so adding to them
    # unconditionally would *create* a service carrying an ExecCondition and no ExecStart --
    # which systemd refuses to load -- plus an orphan timer wanted by nothing.
    (lib.mkIf config.nix.gc.automatic {
      # Boot trigger, on top of the periodic OnCalendar from nix.gc.dates. A timer with
      # both fires on whichever comes first, independently -- which is exactly "after boot"
      # plus "weekly".
      systemd.timers.nix-gc.timerConfig.OnBootSec = cfg.gcOnBootDelay;

      systemd.services.nix-gc.serviceConfig.ExecCondition = lib.getExe skipIfUpgrading;
    })
  ];
}
