{ config, lib, pkgs, ... }:

let
  cfg = config.common.restic;

  credentialPath = backup: credentialName:
    "${backup.credentialDirectory}/${credentialName}";

  wrapperFor = name: backup:
    pkgs.writeShellApplication {
      name = "restic-${name}";
      runtimeInputs = [ pkgs.coreutils ];
      text = ''
        if [ -z "''${CREDENTIALS_DIRECTORY:-}" ]; then
          echo "CREDENTIALS_DIRECTORY is not set" >&2
          exit 1
        fi

        RESTIC_PASSWORD_FILE="$CREDENTIALS_DIRECTORY/repository-password"
        export RESTIC_PASSWORD_FILE

        ${
          if backup.backend.type == "rest" then ''
            RESTIC_REST_USERNAME="$(cat "$CREDENTIALS_DIRECTORY/backend-username")"
            RESTIC_REST_PASSWORD="$(cat "$CREDENTIALS_DIRECTORY/backend-password")"
            export RESTIC_REST_USERNAME RESTIC_REST_PASSWORD
          '' else if backup.backend.type == "s3" then ''
            AWS_ACCESS_KEY_ID="$(cat "$CREDENTIALS_DIRECTORY/aws-access-key-id")"
            AWS_SECRET_ACCESS_KEY="$(cat "$CREDENTIALS_DIRECTORY/aws-secret-access-key")"
            export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
          '' else ''
            echo "unsupported restic backend: ${backup.backend.type}" >&2
            exit 1
          ''
        }

        if [ "''${1:-}" = "backup" ]; then
          ${lib.getExe pkgs.restic} unlock
        fi

        exec ${lib.getExe pkgs.restic} "$@"
      '';
    };

  backendEnvironment = backup:
    {
      RESTIC_CACHE_DIR = "/var/cache/restic-backups-${backup.name}";
    };

  # Only the backup phase itself comes from services.restic.backups; prune and check are
  # emitted below, so the stopServices restart can sit between the backup and the prune.
  backupToResticConfig = name: rawBackup:
    let
      backup = rawBackup // { inherit name; };
    in
    {
      inherit (backup) paths;
      exclude = backup.exclude;
      extraBackupArgs = [ "--group-by=" ];
      initialize = true;
      package = wrapperFor name backup;
      passwordFile = "$CREDENTIALS_DIRECTORY/repository-password";
      repository = backup.repository;
      pruneOpts = [ ];
      runCheck = false;
      timerConfig = backup.timerConfig;
      user = backup.user;
    };

  resticFor = name: backup: lib.getExe (wrapperFor name backup);

  # prune.ignoreErrors becomes a "-" prefix (useful for append-only repositories): the
  # commands still run, their failure does not fail the unit.
  pruneCommands = name: backup:
    let
      restic = resticFor name backup;
      prefix = lib.optionalString backup.prune.ignoreErrors "-";
      opts = lib.concatStringsSep " " ([ "--group-by=" ] ++ backup.prune.opts);
    in
    [
      "${prefix}${restic} unlock"
      "${prefix}${restic} forget --prune ${opts}"
    ];

  # The units that were running when the backup started, so a unit someone stopped for
  # maintenance is not started again. RuntimeDirectory exists before the first Exec* runs
  # and is removed with the unit, so this cannot outlive a run.
  stoppedUnitsFile = name: "/run/restic-backups-${name}/stopped-units";

  stopScript = name: backup:
    pkgs.writeShellApplication {
      name = "restic-${name}-stop-services";
      runtimeInputs = [ pkgs.coreutils pkgs.findutils config.systemd.package ];
      # An array rather than a literal word list: with a single unit, `for u in 'a.service'`
      # is a shellcheck error (SC2043) and writeShellApplication runs shellcheck.
      text = ''
        units=(${lib.escapeShellArgs backup.stopServices})

        : > ${stoppedUnitsFile name}
        for unit in "''${units[@]}"; do
          if systemctl is-active --quiet "$unit"; then
            printf '%s\n' "$unit" >> ${stoppedUnitsFile name}
          fi
        done
        xargs -r systemctl stop -- < ${stoppedUnitsFile name}
      '';
    };

  # Idempotent: the file is removed once the units are back, so the ExecStopPost safety net
  # is a no-op after the ExecStart run succeeded, and retries it when it did not.
  startScript = name: _backup:
    pkgs.writeShellApplication {
      name = "restic-${name}-start-services";
      runtimeInputs = [ pkgs.coreutils pkgs.findutils config.systemd.package ];
      text = ''
        if [ -e ${stoppedUnitsFile name} ]; then
          xargs -r systemctl start -- < ${stoppedUnitsFile name}
          rm -f ${stoppedUnitsFile name}
        fi
      '';
    };

  serviceConfigFor = name: rawBackup:
    let
      backup = rawBackup // { inherit name; };
      credentials = [ "repository-password" ] ++ backup.backend.credentials;
      quiesce = backup.stopServices != [ ];
      # "+" runs the command fully privileged: systemd then skips User=, the capability and
      # namespacing options and the seccomp filters for it, which is what lets systemctl
      # (root, AF_UNIX to PID 1) work from inside this otherwise sandboxed unit.
      startServices = "+${lib.getExe (startScript name backup)}";
    in
    {
      environment = backendEnvironment backup;
      unitConfig.ConditionPathExists = map (credentialPath backup) credentials;
      serviceConfig = {
        # Backend/repo secrets are systemd-creds-encrypted blobs on disk, decrypted at
        # runtime into $CREDENTIALS_DIRECTORY (never plaintext at rest, never in git/store).
        LoadCredentialEncrypted = map (credential: "${credential}:${credentialPath backup credential}") credentials;
        SystemCallFilter = [ "@system-service" ];
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        KeyringMode = "private";
        ProtectClock = true;
        RestrictRealtime = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectHostname = true;
        SystemCallArchitectures = "native";
        CapabilityBoundingSet = "";
        RestrictNamespaces = true;
        LockPersonality = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
        ProtectProc = "noaccess";
        RemoveIPC = true;
        PrivateUsers = true;
        ProtectSystem = "strict";
        ProtectHome = "tmpfs";
        BindReadOnlyPaths = backup.paths;
        CacheDirectory = "restic-backups-${name}";

        # Appended to what services.restic.backups generated (its preStart and its backup
        # command come first): restart the stopped units, then prune, then check.
        ExecStart = lib.mkAfter (
          lib.optional quiesce startServices
          ++ pruneCommands name backup
          ++ [ "${resticFor name backup} check" ]
        );
      } // lib.optionalAttrs quiesce {
        ExecStartPre = lib.mkAfter [ "+${lib.getExe (stopScript name backup)}" ];
        # An ExecStart list aborts at the first failing command, so without this a failed
        # backup would leave the units stopped.
        ExecStopPost = lib.mkAfter [ startServices ];
      };
    };
in
{
  options.common.restic.backups = lib.mkOption {
    description = "Named restic backups using systemd credentials.";
    default = { };
    type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
      options = {
        credentialDirectory = lib.mkOption {
          type = lib.types.str;
          example = "/etc/credentials/restic/${name}";
          description = "Directory containing repository-password and backend credential files.";
        };

        user = lib.mkOption {
          type = lib.types.str;
          example = "sashee";
          description = "User to run the backup service as.";
        };

        repository = lib.mkOption {
          type = lib.types.str;
          example = "rest:https://backup.example.com/home";
          description = "Restic repository URL without embedded secrets.";
        };

        backend = lib.mkOption {
          type = lib.types.submodule {
            options = {
              type = lib.mkOption {
                type = lib.types.enum [ "rest" "s3" ];
              };

              credentials = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                description = "Backend credential filenames in credentialDirectory.";
              };
            };
          };
        };

        paths = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          example = [ "/home/sashee" ];
          description = "Directories to back up.";
        };

        exclude = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ ".stversions" "/home/*/.cache" ];
          description = "Patterns to exclude from backups.";
        };

        stopServices = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "monitoring-platform.service" ];
          description = ''
            Units to stop before the backup phase and start again as soon as the backup
            finishes, before prune and check. Use this for services whose on-disk state is
            only consistent while they are down, such as a database with a write-ahead log.

            Only units that were running when the backup started are started again, so a
            unit stopped for maintenance stays stopped. They are also started again when
            the backup fails. Names are passed to systemctl verbatim, so "foo" means
            "foo.service".
          '';
        };

        prune = {
          ignoreErrors = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether prune failures should be ignored, useful for append-only repositories.";
          };

          opts = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [
              "--keep-daily 7"
              "--keep-weekly 4"
              "--keep-monthly 12"
            ];
            description = "Options passed to restic forget --prune.";
          };
        };

        timerConfig = lib.mkOption {
          type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
          default = {
            OnCalendar = "daily";
            Persistent = true;
            RandomizedDelaySec = "1h";
          };
          description = "systemd timer configuration for the backup.";
        };
      };
    }));
  };

  config = lib.mkIf (cfg.backups != { }) {
    assertions = lib.mapAttrsToList
      (name: backup: {
        assertion = !lib.any (unit: unit == "restic-backups-${name}" || unit == "restic-backups-${name}.service") backup.stopServices;
        message = "common.restic.backups.${name}.stopServices must not contain its own unit, restic-backups-${name}.service.";
      })
      cfg.backups;

    services.restic.backups = lib.mapAttrs backupToResticConfig cfg.backups;
    systemd.services = lib.mapAttrs'
      (name: backup: lib.nameValuePair "restic-backups-${name}" (serviceConfigFor name backup))
      cfg.backups;
  };
}
