{ config, lib, pkgs, ... }:

let
  cfg = config.common.restic;

  credentialPath = backup: credentialName:
    "${backup.credentialDirectory}/${credentialName}";

  wrapperFor = name: backup:
    let
      sandbox = lib.getExe (sandboxFor name backup);
    in
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

        # Every restic run is sandboxed; only `backup` gets the backup paths and the capability.
        if [ "''${1:-}" = "backup" ]; then
          exec ${sandbox} backup ${lib.getExe pkgs.restic} "$@"
        fi

        exec ${sandbox} repository ${lib.getExe pkgs.restic} "$@"
      '';
    };

  # Landlock rights (setpriv(1) names) on a directory the unit owns.
  ownDirectoryRights = "read-file,read-dir,write-file,make-dir,make-reg,remove-dir,remove-file,truncate,refer";

  # Runs a command under this backup's Landlock ruleset: setpriv applies it right before the exec,
  # and everything the command starts inherits it. Landlock decides on top of file permissions, so
  # it holds against CAP_DAC_READ_SEARCH, opens by file handle included. It restricts opening
  # files, not looking them up: names and metadata stay visible.
  #
  # Readable in either phase: the store, the unit's credentials and name resolution. Writable: the
  # unit's cache and its private /tmp, nothing else.
  #   repository: no backup paths, and the unit's CAP_DAC_READ_SEARCH is dropped.
  #   backup: the backup paths and the runtime directory (upstream's --files-from list) too,
  #     read-only, with the capability.
  sandboxFor = name: backup:
    pkgs.writeShellApplication {
      name = "restic-${name}-sandbox";
      text = ''
        phase=$1
        shift
        args=(
          --no-new-privs
          --landlock-access fs
          --landlock-rule "path-beneath:execute,read-file,read-dir:/nix/store"
          --landlock-rule "path-beneath:read-file,read-dir:$CREDENTIALS_DIRECTORY"
          --landlock-rule "path-beneath:${ownDirectoryRights}:$CACHE_DIRECTORY"
          --landlock-rule "path-beneath:${ownDirectoryRights}:/tmp"
        )
        # A rule on a missing path fails the run, so these are only added where they exist.
        for file in /etc/resolv.conf /etc/hosts; do
          if [ -e "$file" ]; then
            args+=(--landlock-rule "path-beneath:read-file:$file")
          fi
        done

        case "$phase" in
          repository)
            # Clearing the inheritable set clears the ambient one with it, so the command starts
            # with no capabilities at all.
            args+=(--inh-caps=-all --ambient-caps=-all)
            ;;
          backup)
            args+=(--landlock-rule "path-beneath:read-file,read-dir:$RUNTIME_DIRECTORY")
            paths=(${lib.escapeShellArgs backup.paths})
            for path in "''${paths[@]}"; do
              # read-dir is rejected on a file.
              if [ -d "$path" ]; then
                args+=(--landlock-rule "path-beneath:read-file,read-dir:$path")
              else
                args+=(--landlock-rule "path-beneath:read-file:$path")
              fi
            done
            ;;
          *)
            echo "unknown sandbox phase: $phase" >&2
            exit 2
            ;;
        esac

        exec ${pkgs.util-linux}/bin/setpriv "''${args[@]}" -- "$@"
      '';
    };

  backupToResticConfig = name: rawBackup:
    let
      backup = rawBackup // { inherit name; };
    in
    {
      inherit (backup) paths;
      exclude = backup.exclude;
      extraBackupArgs = [ "--group-by=" ];
      # Opens (or creates) the repository in upstream's pre-start, before anything is stopped.
      initialize = true;
      package = wrapperFor name backup;
      passwordFile = "$CREDENTIALS_DIRECTORY/repository-password";
      # The repository location comes from the credential, so the unit carries a path to it
      # rather than the location itself. Not "$CREDENTIALS_DIRECTORY/repository" like
      # passwordFile above: repositoryFile is typed as an absolute path, so it has to name
      # systemd's documented runtime location for the unit's credentials directly. Upstream
      # asserts exactly one of repository/repositoryFile/environmentFile is set.
      repository = null;
      repositoryFile = "/run/credentials/restic-backups-${name}.service/repository";
      # Upstream's `restic-<name>` PATH script bakes the unit's environment into a
      # world-readable store path, and cannot decrypt systemd credentials anyway.
      createWrapper = false;
      pruneOpts = [ ];
      runCheck = false;
      timerConfig = backup.timerConfig;
      # The dynamic user the unit runs as (DynamicUser below).
      user = "restic-${name}";
    };

  resticFor = name: backup: lib.getExe (wrapperFor name backup);

  # Retention, then check. The check runs whatever retention did, so the repository is verified
  # after every backup; a retention failure fails the unit afterwards unless prune.ignoreErrors
  # (useful for append-only repositories).
  maintenanceScript = name: backup:
    let
      restic = resticFor name backup;
      opts = lib.concatStringsSep " " ([ "--group-by=" ] ++ backup.prune.opts);
    in
    pkgs.writeShellApplication {
      name = "restic-${name}-maintenance";
      text = ''
        retention=0
        ${restic} unlock || retention=$?
        ${restic} forget --prune ${opts} || retention=$?
        ${restic} check
        ${if backup.prune.ignoreErrors then ''
          if [ "$retention" -ne 0 ]; then
            echo "retention failed (exit $retention), ignored: prune.ignoreErrors" >&2
          fi
        '' else ''
          exit "$retention"
        ''}
      '';
    };

  # stopServices are stopped and started again through systemd units, so that backups sharing a
  # unit share its downtime rather than each restarting it under the others:
  #   restic-quiesce-<unit>: one per stopped unit, shared by every backup that lists it. Starting
  #     it stops the unit; stopping it starts the unit again. StopWhenUnneeded= has systemd stop
  #     it once no active unit requires it any more.
  #   restic-hold-<name>: one per backup, requiring the quiesce units of its stopServices. The
  #     backup starts it before reading and stops it right after; BindsTo= stops it whenever
  #     the backup ends, failed or killed included.
  # So the unit is down from the first backup's start of reading to the last one's end of it.

  # systemctl's reading of a name: one without a unit type suffix is a service. Normalised so
  # that "foo" and "foo.service" in two backups share one quiesce unit.
  unitTypes = [ "service" "socket" "device" "mount" "automount" "swap" "target" "path" "timer" "slice" "scope" ];
  normalizeUnit = unit:
    if lib.any (type: lib.hasSuffix ".${type}" unit) unitTypes then unit else "${unit}.service";

  quiesceName = unit: "restic-quiesce-${lib.replaceStrings [ "@" ] [ "-" ] (lib.removeSuffix ".service" (normalizeUnit unit))}";
  holdName = name: "restic-hold-${name}";
  recoverName = "restic-recover-quiesced";

  quiescingBackups = lib.filterAttrs (_: backup: backup.stopServices != [ ]) cfg.backups;
  quiescedUnits = lib.unique (lib.concatMap (backup: map normalizeUnit backup.stopServices) (lib.attrValues quiescingBackups));

  # Starting the quiesce unit. "restart" in its RuntimeDirectory marks the unit for starting
  # again; RuntimeDirectory goes away with the quiesce unit, so the mark cannot outlive it.
  quiesceStopScript = unit:
    pkgs.writeShellApplication {
      name = "${quiesceName unit}-stop";
      runtimeInputs = [ pkgs.coreutils config.systemd.package ];
      text = ''
        unit=${lib.escapeShellArg unit}
        # A unit still starting is let finish first. `is-active` reports it as not running, so
        # it would be neither stopped nor restarted while it came up and wrote under restic --
        # the monitoring platform migrates its database before READY=1, for up to hours. Stopping
        # it instead would roll a migration back only to restart it from scratch afterwards.
        # `start` joins the pending job and returns when it does; a failed start leaves nothing
        # running, which the check below then sees.
        if [ "$(systemctl show --property=ActiveState --value "$unit")" = activating ]; then
          systemctl start "$unit" || true
        fi
        # A unit stopped by hand is inactive and stays stopped. A failed one is started again
        # afterwards, like a running one: that is how a start that failed after the last backup
        # is retried rather than forgotten.
        if systemctl is-active --quiet "$unit" || systemctl is-failed --quiet "$unit"; then
          touch /run/${quiesceName unit}/restart
          systemctl stop "$unit"
        fi
      '';
    };

  # Stopping the quiesce unit. A failed start fails it, which leaves the quiesce unit failed:
  # the recovery timer's cue.
  quiesceStartScript = unit:
    pkgs.writeShellApplication {
      name = "${quiesceName unit}-start";
      runtimeInputs = [ config.systemd.package ];
      text = ''
        if [ -e /run/${quiesceName unit}/restart ]; then
          systemctl start ${lib.escapeShellArg unit}
        fi
      '';
    };

  quiesceServiceFor = unit: {
    description = "Keep ${unit} stopped while restic backups read it";
    # A switch must not restart it under a running backup: its stop starts the unit.
    restartIfChanged = false;
    # Ordered after the recovery run, so a backup starting while it runs cannot have the unit
    # stopped and then started again underneath it.
    after = [ "${recoverName}.service" ];
    unitConfig.StopWhenUnneeded = true;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      RuntimeDirectory = quiesceName unit;
      ExecStart = lib.getExe (quiesceStopScript unit);
      ExecStop = lib.getExe (quiesceStartScript unit);
      # Starting the unit again takes as long as its start does: hours for a migration.
      TimeoutStopSec = "infinity";
    };
  };

  holdServiceFor = name: backup: {
    description = "restic backup ${name} reading its stopServices";
    restartIfChanged = false;
    requires = map (unit: "${quiesceName unit}.service") backup.stopServices;
    after = map (unit: "${quiesceName unit}.service") backup.stopServices;
    # Not After= as well: the backup starts this from its own pre-start, so that would deadlock.
    bindsTo = [ "restic-backups-${name}.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/true";
    };
  };

  # Retries a start that failed when a quiesce unit stopped, without waiting for the next backup
  # of that unit.
  recoverScript = pkgs.writeShellApplication {
    name = recoverName;
    runtimeInputs = [ config.systemd.package ];
    text = ''
      status=0
      recover() {
        if systemctl is-failed --quiet "$1"; then
          if systemctl start "$2"; then
            systemctl reset-failed "$1"
          else
            status=1
          fi
        fi
      }
      ${lib.concatMapStrings (unit: ''
        recover ${quiesceName unit}.service ${lib.escapeShellArg unit}
      '') quiescedUnits}
      exit "$status"
    '';
  };

  # One unit per backup, upstream's restic-backups-<name> with its timer. The unit runs as a
  # dynamic user holding only CAP_DAC_READ_SEARCH (read any file, whatever its owner and mode),
  # and what restic may touch is decided per run by the Landlock sandbox above, not by mounts:
  # an empty root would also apply to the "+" hold commands, where systemctl, chrooted,
  # ignores its command and exits 0. The systemd hardening below is the second layer.
  serviceConfigFor = name: rawBackup:
    let
      backup = rawBackup // { inherit name; };
      credentials = [ "repository" "repository-password" ] ++ backup.backend.credentials;
      quiesce = backup.stopServices != [ ];
      # "+" runs the command fully privileged: systemd then skips User=, the capability and
      # namespacing options and the seccomp filters for it, which is what lets systemctl
      # (root, AF_UNIX to PID 1) work from inside this otherwise sandboxed unit.
      hold = verb: "+${config.systemd.package}/bin/systemctl ${verb} ${holdName name}.service";
    in
    {
      environment = {
        # The system CA store: security.pki.caBundle is the bundle /etc/ssl/certs points at, built
        # from security.pki.certificateFiles, so a test CA added there is trusted here too.
        SSL_CERT_FILE = config.security.pki.caBundle;
      };
      unitConfig.ConditionPathExists = map (credentialPath backup) credentials;
      serviceConfig = {
        # Backend/repo secrets are systemd-creds-encrypted blobs on disk, decrypted at
        # runtime into $CREDENTIALS_DIRECTORY (never plaintext at rest, never in git/store).
        LoadCredentialEncrypted = map (credential: "${credential}:${credentialPath backup credential}") credentials;
        DynamicUser = true;
        AmbientCapabilities = [ "CAP_DAC_READ_SEARCH" ];
        CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" ];
        # The capability does not apply to files of uids outside a user namespace.
        PrivateUsers = false;
        # @sandbox for Landlock, capset for setpriv (it sets capabilities even when told to change
        # none), which ~@privileged would take. ~@privileged also takes open_by_handle_at, the
        # other way CAP_DAC_READ_SEARCH reaches files by handle rather than by path.
        SystemCallFilter = [ "@system-service" "@sandbox" "~@privileged" "capset" ];
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
        ProtectHome = "read-only";
        UMask = "0077";
        # After upstream's pre-start (repository init): build the backup's sandbox once, which
        # fails on a missing backup path, so nothing is stopped for a backup that cannot run. Then
        # clear stale locks, which the backup would trip over: a backend round-trip that retries
        # for minutes on a flaky link, so it too runs before anything is stopped.
        ExecStartPre = lib.mkAfter (
          [
            "${lib.getExe (sandboxFor name backup)} backup ${pkgs.coreutils}/bin/true"
            "${resticFor name backup} unlock"
          ]
          ++ lib.optional quiesce (hold "start")
        );
        # Appended to upstream's backup command: release the stopped units, then retention and
        # check, so the check does not run with the units down. A failed backup never gets here;
        # BindsTo= on the hold unit releases them then.
        ExecStart = lib.mkAfter (
          lib.optional quiesce (hold "stop")
          ++ [ (lib.getExe (maintenanceScript name backup)) ]
        );
      };
    };
in
{
  options.common.restic.backups = lib.mkOption {
    description = "Named restic backups using systemd credentials.";
    default = { };
    type = lib.types.attrsOf (lib.types.submodule ({ name, config, ... }: {
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

            Nothing is stopped until the repository has been opened and unlocked, so an
            unreachable backend leaves the units alone. Only units that were running (or
            had failed) when the backup started are started again, so a unit stopped for
            maintenance stays stopped. A unit still starting counts as running: the backup
            waits for it to finish starting, then stops it. They are also started again
            when the backup fails. A start that fails is retried every 15 minutes.

            Backups that list the same unit share its downtime: it is stopped once, and
            started again only after the last of them has finished reading. "foo" means
            "foo.service", as for systemctl.
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

        sandbox = lib.mkOption {
          type = lib.types.package;
          readOnly = true;
          internal = true;
          description = ''
            The launcher every restic run of this backup goes through:
            `restic-<name>-sandbox repository|backup <command>...` runs the command under the
            backup's Landlock ruleset for that phase. Exposed so tests can probe the sandbox
            from inside.
          '';
        };
      };

      config.sandbox = sandboxFor name config;
    }));
  };

  config = lib.mkIf (cfg.backups != { }) {
    assertions = lib.concatLists (lib.mapAttrsToList
      (name: backup: [
        {
          assertion = !lib.any (unit: normalizeUnit unit == "restic-backups-${name}.service") backup.stopServices;
          message = "common.restic.backups.${name}.stopServices must not contain its own unit, restic-backups-${name}.service.";
        }
        {
          # systemd checks the dynamic user's name only when the unit starts, and then refuses
          # to run it at all.
          assertion = builtins.match "[A-Za-z0-9_-]+" name != null && lib.stringLength "restic-${name}" <= 31;
          message = "common.restic.backups.${name}: the backup runs as the dynamic user restic-${name}, so its name must be at most 24 characters of [A-Za-z0-9_-].";
        }
      ])
      cfg.backups)
    ++ [
      {
        # "@" is folded into "-" in the quiesce unit's name.
        assertion = lib.length (lib.unique (map quiesceName quiescedUnits)) == lib.length quiescedUnits;
        message = "common.restic.backups: two stopServices units map to the same quiesce unit name: ${lib.concatStringsSep ", " quiescedUnits}.";
      }
    ];

    services.restic.backups = lib.mapAttrs backupToResticConfig cfg.backups;
    systemd.services =
      lib.mapAttrs'
        (name: backup: lib.nameValuePair "restic-backups-${name}" (serviceConfigFor name backup))
        cfg.backups
      // lib.mapAttrs'
        (name: backup: lib.nameValuePair (holdName name) (holdServiceFor name backup))
        quiescingBackups
      // lib.listToAttrs (map (unit: lib.nameValuePair (quiesceName unit) (quiesceServiceFor unit)) quiescedUnits)
      // lib.optionalAttrs (quiescedUnits != [ ]) {
        ${recoverName} = {
          description = "Start units again whose restart after a restic backup failed";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe recoverScript;
          };
        };
      };
    systemd.timers = lib.optionalAttrs (quiescedUnits != [ ]) {
      ${recoverName} = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "15min";
          OnUnitActiveSec = "15min";
        };
      };
    };
  };
}
