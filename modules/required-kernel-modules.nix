# Build-time guard: every module listed in a checked-in file must exist in the
# configured kernel. Wired into system.checks, so `nixos-rebuild` (and thus the
# unattended auto-upgrade) FAILS TO BUILD a generation whose kernel dropped a
# required module, instead of rebooting into broken hardware. Main use case:
# switching the rpi5 from the vendor kernel to mainline.
#
# Lookup runs `modprobe --dry-run` against system.modulesTree (the aggregated,
# depmod'd tree, including boot.extraModulePackages like zfs), so it accepts
# builtins (via modules.builtin.bin), resolves aliases, and treats `-`/`_` as
# equivalent. The check derivation stays out of the system closure.
{ config, lib, pkgs, ... }:
let
  cfg = config.common.requiredKernelModules;
  check = pkgs.runCommand "required-kernel-modules-check"
    {
      nativeBuildInputs = [ pkgs.buildPackages.kmod ];
      modulesList = cfg.file;
      modulesTree = config.system.modulesTree;
      kernelVersion = config.boot.kernelPackages.kernel.modDirVersion;
    } ''
    fail=0
    while IFS= read -r line; do
      mod=''${line%%#*}
      mod=''${mod//[[:space:]]/}
      [ -n "$mod" ] || continue
      if ! modprobe --dry-run --dirname "$modulesTree" \
             --set-version "$kernelVersion" -- "$mod" > /dev/null 2>&1; then
        echo "MISSING required kernel module: $mod" >&2
        fail=1
      fi
    done < "$modulesList"
    if [ "$fail" -ne 0 ]; then
      echo "required-kernel-modules: modules listed above are neither loadable" >&2
      echo "nor builtin in kernel $kernelVersion ($modulesTree)." >&2
      echo "List file: $modulesList" >&2
      exit 1
    fi
    touch $out
  '';
in
{
  options.common.requiredKernelModules = {
    enable = lib.mkEnableOption
      "build-time check that all required kernel modules exist in the configured kernel";
    file = lib.mkOption {
      type = lib.types.path;
      description = ''
        File of required kernel module names, one per line.
        Blank lines and `#` comments are allowed.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    system.checks = [ check ];
    # Exposed so the flake can run the same derivation as a CI check.
    system.build.requiredKernelModulesCheck = check;
  };
}
