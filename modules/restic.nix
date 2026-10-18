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

        # The repository location is a credential like the rest; restic reads it from the file
        # via RESTIC_REPOSITORY_FILE (set on the unit, see repositoryFile below), so it never
        # lands in the environment or in the store. The scheme lives in the blob, but
        # backend.type selects which backend credentials get loaded, so a mismatch would
        # otherwise surface as an opaque "unable to open repository".
        case "$(cat "$CREDENTIALS_DIRECTORY/repository")" in
          ${backup.backend.type}:*) ;;
          *)
            echo "repository credential does not name a ${backup.backend.type} repository" >&2
            exit 1
            ;;
        esac

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

  # restic-backups-<name> is a root orchestrator that only drives systemd; the restic work runs in
  # sandboxed oneshot workers it starts in turn (preflight, backup, maintenance). They are separate
  # units because the workers live in an empty root, and an empty root (RootDirectory=,
  # TemporaryFileSystem=) also applies to "+" commands: in the same unit, the stop/start scripts
  # would run chrooted, where systemctl ignores its command and exits 0.
  systemctl = "${config.systemd.package}/bin/systemctl";
  workerName = name: phase: "restic-backups-${name}-${phase}";
  phases = [ "preflight" "backup" "maintenance" ];
  unitsFor = name: [ "restic-backups-${name}" ] ++ map (workerName name) phases;
  cacheDir = name: "restic-backups-${name}";
  credentialsFor = backup: [ "repository" "repository-password" ] ++ backup.backend.credentials;
  # What name resolution reads; the workers' empty root has no /etc otherwise.
  nameResolution = [ "/etc/resolv.conf" "/etc/hosts" ];

  # The workers share one cache, so prune reuses the index the backup just downloaded.
  workerEnvironment = name: {
    RESTIC_CACHE_DIR = lib.mkForce "/var/cache/${cacheDir name}";
    # The system CA store: security.pki.caBundle is the bundle /etc/ssl/certs points at, built
    # from security.pki.certificateFiles, so a test CA added there is trusted here too.
    SSL_CERT_FILE = config.security.pki.caBundle;
  };

  # Only the backup phase itself comes from services.restic.backups (as "<name>-backup", with
  # no timer of its own); the orchestrator and the maintenance worker are emitted below.
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
      repository = null;
      repositoryFile = "/run/credentials/${workerName name "backup"}.service/repository";
      createWrapper = false;
      pruneOpts = [ ];
      runCheck = false;
      # The orchestrator owns the schedule; this unit is only ever started by it.
      timerConfig = null;
      # The name of the dynamic user the workers share (DynamicUser below).
      user = "restic-${name}";
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
  # maintenance is not started again. The orchestrator's RuntimeDirectory: root-owned, and not
  # mounted into either worker, so nothing restic runs can add names to it.
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
          # A unit still starting is let finish first. `is-active` reports it as not running, so
          # it would be neither stopped nor restarted while it came up and wrote under restic --
          # the monitoring platform migrates its database before READY=1, for up to hours. Stopping
          # it instead would roll a migration back only to restart it from scratch afterwards.
          # `start` joins the pending job and returns when it does; a failed start leaves nothing
          # running, which the check below then sees.
          if [ "$(systemctl show --property=ActiveState --value "$unit")" = activating ]; then
            systemctl start "$unit" || true
          fi
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

  # The sandbox the workers share: a throwaway uid in an empty root (NixOS confinement) that holds
  # only the closures of the unit's Exec* commands, the CA bundle and the binds below. Nothing in
  # it is writable except the unit's own cache, runtime and private tmp directories.
  workerFor = name: backup: {
    unitConfig.ConditionPathExists = map (credentialPath backup) (credentialsFor backup);
    confinement = {
      enable = true;
      packages = [ config.security.pki.caBundle ];
    };
    serviceConfig = {
      # Backend/repo secrets are systemd-creds-encrypted blobs on disk, decrypted at
      # runtime into $CREDENTIALS_DIRECTORY (never plaintext at rest, never in git/store).
      LoadCredentialEncrypted = map (credential: "${credential}:${credentialPath backup credential}") (credentialsFor backup);
      DynamicUser = true;
      User = "restic-${name}";
      # ~@privileged also takes open_by_handle_at, which would let CAP_DAC_READ_SEARCH (backup
      # worker) open files outside the empty root by handle.
      SystemCallFilter = [ "@system-service" "~@privileged" ];
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
      RestrictNamespaces = true;
      LockPersonality = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
      ProtectProc = "noaccess";
      RemoveIPC = true;
      ProtectSystem = "strict";
      ProtectHome = "tmpfs";
      CacheDirectory = lib.mkForce (cacheDir name);
      CacheDirectoryMode = "0700";
    };
  };

  # Reads the backup paths: the only unit that holds CAP_DAC_READ_SEARCH (read any file, whatever
  # its owner and mode), and the only one they are mounted into.
  backupWorkerFor = name: backup: lib.recursiveUpdate (workerFor name backup) {
    environment = workerEnvironment name;
    serviceConfig = {
      AmbientCapabilities = [ "CAP_DAC_READ_SEARCH" ];
      CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" ];
      # The capability does not apply to files of uids outside a user namespace.
      PrivateUsers = false;
      BindReadOnlyPaths = backup.paths ++ nameResolution;
    };
  };

  # Opens (or creates) the repository before anything is stopped. restic retries an unreachable
  # backend for ~15 minutes, so without this a backend, TLS or DNS outage would keep the
  # stopServices units down for that long before the backup worker gave up.
  preflightWorkerFor = name: backup: lib.recursiveUpdate (workerFor name backup) {
    description = "restic repository preflight for ${name}";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    environment = workerEnvironment name // {
      RESTIC_REPOSITORY_FILE = "/run/credentials/${workerName name "preflight"}.service/repository";
    };
    serviceConfig = {
      Type = "oneshot";
      CapabilityBoundingSet = "";
      PrivateUsers = true;
      BindReadOnlyPaths = nameResolution;
      ExecStart = lib.getExe (pkgs.writeShellApplication {
        name = "restic-${name}-preflight";
        text = ''
          ${resticFor name backup} cat config > /dev/null || ${resticFor name backup} init
        '';
      });
    };
  };

  # Retention and check talk to the repository only: no backup paths, no capability.
  maintenanceWorkerFor = name: backup: lib.recursiveUpdate (workerFor name backup) {
    description = "restic prune and check for ${name}";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    environment = workerEnvironment name // {
      RESTIC_REPOSITORY_FILE = "/run/credentials/${workerName name "maintenance"}.service/repository";
    };
    serviceConfig = {
      Type = "oneshot";
      CapabilityBoundingSet = "";
      PrivateUsers = true;
      BindReadOnlyPaths = nameResolution;
      ExecStart = pruneCommands name backup ++ [ "${resticFor name backup} check" ];
    };
  };

  # Root, because it drives systemd, and needs nothing else: no network, no capabilities. Each
  # `systemctl start` of a oneshot worker returns when the worker has finished, and fails if it
  # failed. The workers must never be ordered After= this unit: it waits on them.
  #
  # Not ProtectProc=: systemctl tells a chroot from the host by PID 1's /proc entry, and inside a
  # chroot it ignores its command and exits 0 -- the units would silently never be stopped.
  orchestratorFor = name: backup:
    let
      quiesce = backup.stopServices != [ ];
      startServices = lib.getExe (startScript name backup);
    in
    {
      description = "restic backup ${name}";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      unitConfig.ConditionPathExists = map (credentialPath backup) (credentialsFor backup);
      serviceConfig = {
        Type = "oneshot";
        RuntimeDirectory = "restic-backups-${name}";
        ExecStartPre =
          [ "${systemctl} start ${workerName name "preflight"}.service" ]
          ++ lib.optional quiesce (lib.getExe (stopScript name backup));
        # The restart sits between the backup and the prune, so the check does not run with the
        # units down.
        ExecStart =
          [ "${systemctl} start ${workerName name "backup"}.service" ]
          ++ lib.optional quiesce startServices
          ++ [ "${systemctl} start ${workerName name "maintenance"}.service" ];
        # An ExecStart list aborts at the first failing command, so without this a failed
        # backup would leave the units stopped.
        ExecStopPost = lib.optional quiesce startServices;
        PrivateNetwork = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        CapabilityBoundingSet = "";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        KeyringMode = "private";
        UMask = "0077";
        SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
        SystemCallArchitectures = "native";
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
          description = ''
            Directory holding the systemd-creds-encrypted blobs this backup needs: `repository`
            (the full restic repository string, scheme included), `repository-password`, and the
            files named by {option}`backend.credentials`. The repository location lives here
            rather than in the configuration so it stays out of the store and out of git.
          '';
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

            Nothing is stopped until the repository has been opened, so an unreachable
            backend leaves the units alone. Only units that were running when the backup
            started are started again, so a unit stopped for maintenance stays stopped. A
            unit still starting counts as running: the backup waits for it to finish
            starting, then stops it. They are also started again when the backup fails.
            Names are passed to systemctl verbatim, so "foo" means "foo.service".
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
    assertions =
      let
        allUnits = lib.concatMap unitsFor (lib.attrNames cfg.backups);
      in
      lib.mapAttrsToList
        (name: backup: {
          assertion = !lib.any (unit: lib.elem (lib.removeSuffix ".service" unit) (unitsFor name)) backup.stopServices;
          message = "common.restic.backups.${name}.stopServices must not contain its own units (${lib.concatStringsSep ", " (unitsFor name)}).";
        })
        cfg.backups
      ++ [{
        # A backup named "x-backup" would otherwise be the backup worker of a backup named "x".
        assertion = lib.length allUnits == lib.length (lib.unique allUnits);
        message = "common.restic.backups: the names ${lib.concatStringsSep ", " (lib.attrNames cfg.backups)} generate colliding units (each backup owns ${lib.concatStringsSep ", " (map (p: "restic-backups-<name>-${p}") phases)}).";
      }];

    services.restic.backups = lib.mapAttrs'
      (name: backup: lib.nameValuePair "${name}-backup" (backupToResticConfig name backup))
      cfg.backups;
    systemd.services = lib.mkMerge [
      (lib.mapAttrs' (name: backup: lib.nameValuePair (workerName name "preflight") (preflightWorkerFor name backup)) cfg.backups)
      (lib.mapAttrs' (name: backup: lib.nameValuePair (workerName name "backup") (backupWorkerFor name backup)) cfg.backups)
      (lib.mapAttrs' (name: backup: lib.nameValuePair (workerName name "maintenance") (maintenanceWorkerFor name backup)) cfg.backups)
      (lib.mapAttrs' (name: backup: lib.nameValuePair "restic-backups-${name}" (orchestratorFor name backup)) cfg.backups)
    ];
    systemd.timers = lib.mapAttrs'
      (name: backup: lib.nameValuePair "restic-backups-${name}" {
        wantedBy = [ "timers.target" ];
        timerConfig = backup.timerConfig;
      })
      (lib.filterAttrs (_: backup: backup.timerConfig != null) cfg.backups);
  };
}
