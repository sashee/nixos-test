{ config, lib, pkgs, ... }:

let
  cfg = config.common.autoUpgrade;

  planParse = import ../lib/upgrade-plan-parse.nix { inherit pkgs; };

  flakeParts = if cfg.flake == null then [ ] else lib.splitString "#" cfg.flake;
  flakeRoot = if cfg.flake == null then null else builtins.head flakeParts;

  # `nixos-rebuild --flake /etc/nixos` with no '#attr' resolves to
  # nixosConfigurations.<hostname>; mirror that fallback or the prebuild below would
  # instantiate a different configuration than the rebuild that follows it.
  flakeAttr =
    if cfg.flake == null then null
    else if builtins.length flakeParts > 1 then builtins.elemAt flakeParts 1
    else config.networking.hostName;

  # Assembled here and passed through escapeShellArg at the call site, so the shell never
  # has to quote anything itself. The attribute name needs literal double quotes (hostnames
  # contain dashes), and an indented Nix string takes those verbatim -- trying to build the
  # same value inside the script's own `''` block is where the escaping gets unreadable.
  toplevelAttr =
    if flakeRoot == null then null
    else ''${flakeRoot}#nixosConfigurations."${flakeAttr}".config.system.build.toplevel.drvPath'';

  # Everything the upgrade does before `nixos-rebuild` (spec/features/auto-upgrade.md):
  # update the lock, instantiate, then build every outstanding derivation in its own `nix`
  # process.
  #
  # Why one process per derivation: a single `nix build` of the toplevel keeps per-goal state
  # for every derivation it has already finished -- measured at ~16 MB per completed build on
  # this config -- so a large plan walks the coordinator off the end of a 4 GB host. 443
  # builds reached 6.5 GB and were OOM-killed; the full 1552-derivation plan would need
  # ~25 GB, which no amount of swap or --max-jobs tuning fixes. Building one at a time caps
  # the peak at ~6 MB per invocation (measured flat across 45 consecutive builds), leaving
  # the evaluation below as the high-water mark at ~1.1 GB.
  #
  # This is NOT the known nix#5200 / nix#10862 "eval memory held during build" issue: the
  # growth reproduces in a process that does no evaluation at all.
  prebuild =
    if flakeRoot == null then null
    else pkgs.writeShellApplication {
      name = "nixos-upgrade-prebuild";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.gawk
        pkgs.gnugrep
        # `nix flake update --commit-lock-file` shells out to git. Must be a real git, not
        # the sandboxed nix-utils wrapper that cannot write outside $HOME (same reason the
        # unit sets `path` below).
        pkgs.git
        config.nix.package
      ];
      text = ''
        echo "auto-upgrade: updating flake inputs in ${flakeRoot}"
        ${lib.escapeShellArgs [ "nix" "flake" "update" "common" "--flake" flakeRoot "--commit-lock-file" ]}

        # One evaluation, in a process that then exits so its heap goes with it.
        echo "auto-upgrade: instantiating ${flakeAttr}"
        drv="$(nix eval --raw ${lib.escapeShellArg toplevelAttr})"
        echo "auto-upgrade: toplevel is $drv"

        plan="$(mktemp)"
        todo="$(mktemp)"
        topo="$(mktemp)"
        ordered="$(mktemp)"
        trap 'rm -f "$plan" "$todo" "$topo" "$ordered"' EXIT

        # Reads the .drv, so this costs no second evaluation.
        nix build --dry-run "$drv^*" >/dev/null 2>"$plan"

        # Parsing nix's human-readable plan, with a self-check against nix's own count --
        # see lib/upgrade-plan-parse.nix for why that check is load-bearing. It exits
        # non-zero on a mismatch, which `set -o errexit` turns into a failed upgrade rather
        # than a silent fallback to one monolithic build.
        ${lib.getExe planParse} "$plan" > "$todo"
        count="$(wc -l < "$todo" | tr -d ' ')"

        if [ "$count" -eq 0 ]; then
          echo "auto-upgrade: nothing to build"
          exit 0
        fi

        # Dependency order, so every invocation finds its inputs already present and
        # therefore has exactly one goal. `nix-store --requisites` on a .drv returns the
        # closure topologically sorted, dependencies first.
        nix-store --query --requisites "$drv" | grep '[.]drv$' > "$topo" || true
        awk 'NR == FNR { want[$0] = 1; next } ($0 in want)' "$todo" "$topo" > "$ordered"

        ordered_count="$(wc -l < "$ordered" | tr -d ' ')"
        if [ "$ordered_count" -ne "$count" ]; then
          echo "auto-upgrade: $count derivations to build but $ordered_count found in the closure; refusing to continue" >&2
          exit 1
        fi

        echo "auto-upgrade: building $count derivations, one per nix process"
        i=0
        while read -r d; do
          i=$((i + 1))
          echo "auto-upgrade: [$i/$count] $(basename "$d" .drv)"
          # ^* -- ALL outputs, not just the default one. The kernel derivation has three
          # (out, dev, modules) and an out-only build leaves the derivation unbuilt as far
          # as nix is concerned, so the nixos-rebuild that follows would recompile the whole
          # thing and defeat the loop. Same trap the Makefile's export-rpi-kernel documents.
          nix build "$d^*" --no-link --max-jobs 1 --cores 1
        done < "$ordered"

        echo "auto-upgrade: all $count derivations built"
      '';
    };

  # Reboot after a successful boot-generation upgrade when the freshly-built generation differs
  # from the running system. operation = "boot" already made it the default generation, so the
  # reboot just activates it. Compares the full system toplevel, so ANY change triggers a reboot --
  # unlike system.autoUpgrade.allowReboot, which reboots only on kernel/initrd/kernel-modules changes.
  rebootIfChanged = pkgs.writeShellApplication {
    name = "nixos-upgrade-reboot-if-changed";
    runtimeInputs = [ pkgs.coreutils config.systemd.package ];
    text = ''
      booted="$(readlink -f /run/booted-system)"
      built="$(readlink -f /nix/var/nix/profiles/system)"
      if [ "$booted" != "$built" ]; then
        echo "auto-upgrade: new generation differs from booted system; scheduling reboot"
        shutdown -r +1
      fi
    '';
  };
in
{
  options.common.autoUpgrade = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to enable automatic NixOS boot-generation updates.";
    };

    flake = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/etc/nixos#my-laptop";
      description = ''
        Flake URI and NixOS configuration attribute used by nixos-rebuild.
      '';
    };

    rebootOnChange = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Reboot (via `shutdown -r +1`) after a successful upgrade whenever the new boot
        generation differs from the currently running system -- i.e. on ANY change, not only
        kernel/initrd/kernel-modules changes (which is all `system.autoUpgrade.allowReboot`
        covers). Enable only one of the two reboot paths.
      '';
    };

  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.flake != null;
        message = "common.autoUpgrade.flake must be set when common.autoUpgrade.enable is true.";
      }
      {
        assertion = !(cfg.rebootOnChange && config.system.autoUpgrade.allowReboot);
        message = "common.autoUpgrade.rebootOnChange and system.autoUpgrade.allowReboot both reboot after an upgrade; enable only one.";
      }
    ];

    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    system.autoUpgrade = {
      enable = true;
      inherit (cfg) flake;
      dates = "daily";
      flags = [
        "--print-build-logs"
        "--commit-lock-file"
        # Bound build concurrency for the unattended upgrade only; an interactive
        # nixos-rebuild still uses every core. On the 4 GB Pi `cgroup_disable=memory` is on
        # the rpi kernel cmdline, so there is no memory cgroup and MemoryHigh=/MemoryMax=
        # are inert. A 2026-07-20 upgrade was OOM-killed with two 1.1 GiB rustc plus the
        # evaluator's retained ~2 GiB heap -- exactly the shape these flags remove.
        #   --cores 1     -> NIX_BUILD_CORES=1, which nixpkgs' cargo build hook passes as
        #                    `-j`, so Rust crates compile one at a time.
        #   --max-jobs 1  -> one derivation at a time, so the kernel and the locally built
        #                    Rust packages cannot pile up together.
        # These are not the only lever, and alone they are not enough: the 2026-07-29 OOM
        # killed the top-level `nix` process at ~4.6 GB of anon demand while every compiler
        # alive at that moment came to 401 MB combined, so serializing builds would not have
        # saved it. Swap sizing is the other lever -- zram is compressed RAM and therefore
        # *does* buy effective capacity (~5:1 measured on the evaluator's heap), which is why
        # hosts/rpi5/configuration.nix now sets zramSwap.memoryPercent = 100.
        # Substitutions are unaffected (max-substitution-jobs/http-connections are
        # separate), so download-only nights are as fast as before; a from-source kernel
        # bump goes from ~4h to ~11h, which is acceptable for an unattended nightly.
        "--cores"
        "1"
        "--max-jobs"
        "1"
      ];
      operation = "boot";
      randomizedDelaySec = "2h";
    };

    systemd.services.nixos-upgrade.environment = {
      GIT_AUTHOR_NAME = "NixOS Auto-upgrade";
      GIT_AUTHOR_EMAIL = "root@${config.networking.hostName}";
      GIT_COMMITTER_NAME = "NixOS Auto-upgrade";
      GIT_COMMITTER_EMAIL = "root@${config.networking.hostName}";
    };

    systemd.services.nixos-upgrade.preStart =
      lib.optionalString (prebuild != null) (lib.getExe prebuild);

    # GC before the upgrade (spec/features/auto-upgrade.md: "run the nix-gc first"), pulled
    # in as a dependency rather than invoked from the prebuild script. Two reasons:
    #
    #   * `Wants=` rather than `Requires=`: a GC failure must never block upgrades. This host
    #     has had a corrupted nix DB before, and "GC is broken" should not also mean "no
    #     security updates".
    #
    #   * the obvious alternative -- `systemctl start --wait nix-gc.service` from the prebuild
    #     -- deadlocks against nix-gc's own guard. That guard skips the GC whenever
    #     nixos-upgrade is not idle, and a unit running its ExecStartPre is `activating`, so
    #     the upgrade would skip the very GC it just asked for. With After=, the upgrade is
    #     still `inactive` while the dependency runs (measured), so the guard passes.
    #
    # This ordering also resolves the reverse race for free: a GC already in flight when the
    # upgrade is triggered makes the upgrade wait for it rather than run alongside it.
    #
    # Conditional on nix.gc.automatic so a host without an automatic GC does not declare a
    # dependency on a unit that does not exist. (Whether systemd tolerates a missing Wants=
    # target is beside the point -- not asserting it is cheaper than depending on it.)
    systemd.services.nixos-upgrade.wants = lib.optional config.nix.gc.automatic "nix-gc.service";
    systemd.services.nixos-upgrade.after = lib.optional config.nix.gc.automatic "nix-gc.service";

    # After a successful boot-generation upgrade, reboot if anything changed (opt-in). Runs only
    # on ExecStart success and exits 0 either way, so the unit still succeeds and nixos-upgrade's
    # OnSuccess (the monitoring last-success marker) still fires before the +1min reboot.
    systemd.services.nixos-upgrade.serviceConfig.ExecStartPost =
      lib.mkIf cfg.rebootOnChange (lib.getExe rebootIfChanged);

    # The system `git` may be a sandboxed wrapper (nix-utils) that cannot write
    # outside the user's home; auto-upgrade commits the lock in the flake dir
    # (e.g. /etc/nixos), so ensure a real git is first on the service PATH.
    systemd.services.nixos-upgrade.path = lib.mkBefore [ pkgs.git ];
  };
}
