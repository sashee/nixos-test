{ config, lib, pkgs, ... }:

let
  cfg = config.common.monitoring;

  resticBackups = lib.attrNames config.common.restic.backups;
  resticBackupArgs = lib.concatMapStringsSep " " lib.escapeShellArg resticBackups;

  excludeFsTypePattern = lib.concatStringsSep "|" (map lib.escapeShellArg cfg.diskSpace.excludeFsTypes);

  # systemd has no "last successful run" timestamp, so monitored units record one
  # via OnSuccess into this directory; the checks read the marker's age.
  successDir = "/var/lib/common-monitoring";
  markerPath = unit: "${successDir}/${unit}.last-success";
  recordServiceName = name: "common-monitoring-record-${name}";

  recordSuccess = pkgs.writeShellApplication {
    name = "common-monitoring-record-success";
    runtimeInputs = [ cfg.tools.coreutils ];
    text = ''
      target="$1"
      mkdir -p "$(dirname "$target")"
      tmp="$(mktemp "$target.XXXXXX")"
      date +%s > "$tmp"
      mv -f "$tmp" "$target"
    '';
  };

  # Units whose last-successful-run age the monitoring checks track. `name` is the
  # systemd.services.<name> key (no .service); `unit` is the full unit name.
  monitoredUnits =
    lib.optionals cfg.restic.enable
      (map (b: rec { name = "restic-backups-${b}"; unit = "${name}.service"; }) resticBackups)
    ++ lib.optional (cfg.autoUpgrade.enable && config.system.autoUpgrade.enable)
      { name = "nixos-upgrade"; unit = "nixos-upgrade.service"; };

  monitorScript = pkgs.writeShellApplication {
    name = "common-monitoring-checks";
    runtimeInputs = [
      cfg.tools.coreutils
      cfg.tools.curl
      cfg.tools.findutils
      cfg.tools.gawk
      cfg.tools.gnugrep
      cfg.tools.jq
      cfg.tools.smartmontools
      cfg.tools.systemd
    ];
    text = ''
      log_file="$(mktemp)"
      report_failed=0
      checks_failed=0
      report_enabled=${lib.escapeShellArg (lib.boolToString cfg.report.enable)}
      smart_enabled=${lib.escapeShellArg (lib.boolToString cfg.smart.enable)}
      restic_enabled=${lib.escapeShellArg (lib.boolToString cfg.restic.enable)}
      disk_space_enabled=${lib.escapeShellArg (lib.boolToString cfg.diskSpace.enable)}
      monitoring_auto_upgrade_enabled=${lib.escapeShellArg (lib.boolToString cfg.autoUpgrade.enable)}
      system_auto_upgrade_enabled=${lib.escapeShellArg (lib.boolToString config.system.autoUpgrade.enable)}
      generations_enabled=${lib.escapeShellArg (lib.boolToString cfg.generations.enable)}
      restic_backups=(${resticBackupArgs})

      cleanup() {
        rm -f "$log_file"
      }
      trap cleanup EXIT

      log() {
        printf '%s\n' "$*" | tee -a "$log_file"
      }

      fail() {
        checks_failed=1
        log "[FAIL] $*"
      }

      ok() {
        log "[OK] $*"
      }

      skip() {
        log "[SKIP] $*"
      }

      parse_duration_seconds() {
        value="$1"
        number="''${value%[smhd]}"
        unit="''${value#"$number"}"

        case "$unit" in
          s) printf '%s\n' "$number" ;;
          m) printf '%s\n' "$((number * 60))" ;;
          h) printf '%s\n' "$((number * 60 * 60))" ;;
          d) printf '%s\n' "$((number * 24 * 60 * 60))" ;;
          *)
            log "[FAIL] unsupported duration '$value'; use Ns, Nm, Nh, or Nd"
            checks_failed=1
            printf '%s\n' 0
            ;;
        esac
      }

      report_url() {
        if [ "$report_enabled" != "true" ]; then
          return 0
        fi

        if [ -z "''${CREDENTIALS_DIRECTORY:-}" ]; then
          log "[FAIL] CREDENTIALS_DIRECTORY is not set"
          report_failed=1
          return 1
        fi

        url_file="$CREDENTIALS_DIRECTORY/${cfg.report.urlCredential}"
        if [ ! -r "$url_file" ]; then
          log "[FAIL] monitoring report URL credential is missing: ${cfg.report.urlCredential}"
          report_failed=1
          return 1
        fi

        url="$(cat "$url_file")"
        printf '%s\n' "''${url%/}"
      }

      post_healthchecks() {
        if [ "$report_enabled" != "true" ]; then
          return 0
        fi

        suffix="$1"
        body_file="''${2:-}"

        url="$(report_url)" || return 1
        target="$url$suffix"

        if [ -n "$body_file" ]; then
          curl --retry 3 --fail --show-error --silent \
            --header 'Content-Type: text/plain; charset=utf-8' \
            --data-binary "@$body_file" \
            "$target" >/dev/null || report_failed=1
        else
          curl --retry 3 --fail --show-error --silent \
            --request POST \
            "$target" >/dev/null || report_failed=1
        fi
      }

      check_unit_recent() {
        label="$1"
        unit="$2"
        max_age="$3"
        max_seconds="$(parse_duration_seconds "$max_age")"

        # Alert when there has been no successful run within max_age. The unit
        # records its last success time (epoch) into this marker via OnSuccess;
        # failed runs in between never touch it, so they are correctly ignored.
        marker="${successDir}/$unit.last-success"
        if [ ! -r "$marker" ]; then
          fail "$label: $unit has no successful run recorded"
          return 0
        fi

        last_seconds="$(cat "$marker")"
        now_seconds="$(date +%s)"
        age_seconds="$((now_seconds - last_seconds))"

        if [ "$age_seconds" -gt "$max_seconds" ]; then
          fail "$label: $unit last succeeded ''${age_seconds}s ago, older than $max_age"
        else
          ok "$label: $unit last succeeded ''${age_seconds}s ago"
        fi
      }

      check_smart() {
        if [ "$smart_enabled" != "true" ]; then
          skip "smart: disabled"
          return 0
        fi

        scan_json="$(smartctl --scan-open --json 2>/dev/null || true)"
        devices="$(printf '%s' "$scan_json" | jq -r '.devices[]? | [.name, (.type // "")] | @tsv' 2>/dev/null || true)"

        if [ -z "$devices" ]; then
          skip "smart: no SMART-capable devices discovered"
          return 0
        fi

        while IFS=$'\t' read -r device type; do
          [ -n "$device" ] || continue

          if [ -n "$type" ]; then
            health_json="$(smartctl --json --health --all -d "$type" "$device" 2>/dev/null || true)"
          else
            health_json="$(smartctl --json --health --all "$device" 2>/dev/null || true)"
          fi

          if printf '%s' "$health_json" | jq -e '.smart_status.passed == true' >/dev/null 2>&1; then
            ok "smart: $device reports healthy"
          else
            fail "smart: $device does not report healthy SMART status"
          fi
        done <<< "$devices"
      }

      check_restic() {
        if [ "$restic_enabled" != "true" ]; then
          skip "restic: disabled"
          return 0
        fi

        if [ "''${#restic_backups[@]}" -eq 0 ]; then
          skip "restic: no backups configured"
          return 0
        fi

        for backup in "''${restic_backups[@]}"; do
          check_unit_recent "restic $backup" "restic-backups-$backup.service" "${cfg.restic.maxAge}"
        done
      }

      check_disk_space() {
        if [ "$disk_space_enabled" != "true" ]; then
          skip "disk-space: disabled"
          return 0
        fi

        while read -r target fstype pcent; do
          [ -n "$target" ] || continue
          case "$fstype" in
            ${excludeFsTypePattern}) continue ;;
          esac

          used="''${pcent%\%}"
          if [ "$used" -gt "${toString cfg.diskSpace.maxUsedPercent}" ]; then
            fail "disk-space: $target is $used% full, above ${toString cfg.diskSpace.maxUsedPercent}%"
          else
            ok "disk-space: $target is $used% full"
          fi
        done < <(df --local --output=target,fstype,pcent | awk 'NR > 1')
      }

      check_auto_upgrade() {
        if [ "$monitoring_auto_upgrade_enabled" != "true" ]; then
          skip "auto-upgrade: disabled"
          return 0
        fi

        if [ "$system_auto_upgrade_enabled" != "true" ]; then
          skip "auto-upgrade: system.autoUpgrade is disabled"
          return 0
        fi

        check_unit_recent "auto-upgrade" "nixos-upgrade.service" "${cfg.autoUpgrade.maxAge}"
      }

      check_generations() {
        if [ "$generations_enabled" != "true" ]; then
          skip "generations: disabled"
          return 0
        fi

        count="$(find /nix/var/nix/profiles -maxdepth 1 -name 'system-*-link' | wc -l)"
        if [ "$count" -gt "${toString cfg.generations.maxCount}" ]; then
          fail "generations: $count system generations, above ${toString cfg.generations.maxCount}"
        else
          ok "generations: $count system generations"
        fi
      }

      log "host=${config.networking.hostName}"
      log "started=$(date --iso-8601=seconds)"

      post_healthchecks "/start"

      check_smart
      check_restic
      check_disk_space
      check_auto_upgrade
      check_generations

      log "finished=$(date --iso-8601=seconds)"

      if [ "$checks_failed" -eq 0 ]; then
        log "status=ok"
      else
        log "status=failed"
      fi

      log_payload="$(mktemp)"
      trap 'rm -f "$log_file" "$log_payload"' EXIT
      tail -c ${toString cfg.report.maxLogBytes} "$log_file" > "$log_payload"
      post_healthchecks "/log" "$log_payload"

      if [ "$checks_failed" -eq 0 ]; then
        post_healthchecks ""
      else
        post_healthchecks "/fail"
      fi

      if [ "$checks_failed" -ne 0 ] || [ "$report_failed" -ne 0 ]; then
        exit 1
      fi
    '';
  };
in
{
  options.common.monitoring = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to run common laptop health monitoring checks.";
    };

    timerConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "10m";
      };
      description = "systemd timer configuration for common monitoring.";
    };

    report = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to report monitoring results to a Healthchecks-compatible URL.";
      };

      credentialDirectory = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Directory containing the Healthchecks URL credential. Required when
          reporting is enabled; left unset so a host cannot silently forget it.
        '';
      };

      urlCredential = lib.mkOption {
        type = lib.types.str;
        default = "healthchecks-url";
        description = "Credential filename containing the base Healthchecks ping URL.";
      };

      maxLogBytes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 100000;
        description = "Maximum number of log bytes to send to the reporting endpoint.";
      };
    };

    tools = {
      coreutils = lib.mkPackageOption pkgs "coreutils" { };
      curl = lib.mkPackageOption pkgs "curl" { };
      findutils = lib.mkPackageOption pkgs "findutils" { };
      gawk = lib.mkPackageOption pkgs "gawk" { };
      gnugrep = lib.mkPackageOption pkgs "gnugrep" { };
      jq = lib.mkPackageOption pkgs "jq" { };
      smartmontools = lib.mkPackageOption pkgs "smartmontools" { };
      systemd = lib.mkPackageOption pkgs "systemd" { };
    };

    smart.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to auto-discover SMART-capable disks and check their health.";
    };

    diskSpace = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to check local filesystem usage.";
      };

      maxUsedPercent = lib.mkOption {
        type = lib.types.ints.between 1 99;
        default = 85;
        description = "Maximum allowed used percentage for local filesystems.";
      };

      excludeFsTypes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "tmpfs"
          "devtmpfs"
          "efivarfs"
          "proc"
          "sysfs"
          "devpts"
          "cgroup"
          "cgroup2"
          "pstore"
          "securityfs"
          "debugfs"
          "tracefs"
          "fusectl"
          "configfs"
        ];
        description = "Filesystem types ignored by the disk-space check.";
      };
    };

    restic = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to check configured restic backup services.";
      };

      maxAge = lib.mkOption {
        type = lib.types.str;
        default = "14d";
        description = "Maximum age of the last successful restic backup run. Supports Ns, Nm, Nh, Nd.";
      };
    };

    autoUpgrade = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to check the automatic NixOS upgrade service.";
      };

      maxAge = lib.mkOption {
        type = lib.types.str;
        default = "14d";
        description = "Maximum age of the last successful auto-upgrade run. Supports Ns, Nm, Nh, Nd.";
      };
    };

    generations = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to check the number of NixOS system generations.";
      };

      maxCount = lib.mkOption {
        type = lib.types.ints.positive;
        default = 20;
        description = "Maximum allowed number of NixOS system generations.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.report.enable || cfg.report.credentialDirectory != null;
        message = "common.monitoring.report.credentialDirectory must be set when monitoring reporting is enabled (or set common.monitoring.report.enable = false).";
      }
    ];

    systemd.tmpfiles.rules = [ "d ${successDir} 0755 root root -" ];

    systemd.services = lib.mkMerge ([
      {
        common-monitoring = {
          description = "Common system health monitoring";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe monitorScript;
            # The report URL is a systemd-creds-encrypted blob on disk (create with
            # `systemd-creds encrypt --name=<urlCredential> …`); systemd decrypts it into
            # $CREDENTIALS_DIRECTORY at runtime. Encrypted at rest; never in git/the store.
            LoadCredentialEncrypted = lib.mkIf (cfg.report.enable && cfg.report.credentialDirectory != null) [
              "${cfg.report.urlCredential}:${cfg.report.credentialDirectory}/${cfg.report.urlCredential}"
            ];
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = "read-only";
            PrivateTmp = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectControlGroups = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
            SystemCallArchitectures = "native";
          };
        };
      }
    ] ++ map (m: {
      # Record the unit's last successful run; started by the unit's OnSuccess.
      ${recordServiceName m.name} = {
        description = "Record last successful run of ${m.unit}";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${lib.getExe recordSuccess} ${markerPath m.unit}";
        };
      };
      # Have the monitored unit record success without touching its own ExecStart.
      ${m.name} = {
        unitConfig.OnSuccess = "${recordServiceName m.name}.service";
      };
    }) monitoredUnits);

    systemd.timers.common-monitoring = {
      wantedBy = [ "timers.target" ];
      timerConfig = cfg.timerConfig // {
        Unit = "common-monitoring.service";
      };
    };
  };
}
