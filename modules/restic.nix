{ config, lib, pkgs, ... }:

let
  cfg = config.common.restic;

  credentialPath = backup: credentialName:
    "${backup.credentialDirectory}/${credentialName}";

  wrapperFor = name: backup:
    let
      sandbox = lib.getExe backup.sandbox;
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

  backupToResticConfig = name: backup:
    {
      inherit (backup) paths;
      exclude = backup.exclude;
      extraBackupArgs = [ "--group-by=" ];
      # Opens (or creates) the repository in upstream's pre-start, before anything is stopped.
      initialize = true;
      package = wrappers.${name};
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

  # One wrapper per backup, shared by every restic run of it.
  wrappers = lib.mapAttrs wrapperFor cfg.backups;
  resticFor = name: lib.getExe wrappers.${name};

  # Retention, then check. The check runs whatever retention did, so the repository is verified
  # after every backup; a retention failure fails the unit afterwards unless prune.ignoreErrors
  # (useful for append-only repositories).
  maintenanceScript = name: backup:
    let
      restic = resticFor name;
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
  #   restic-restart-<unit>: one per stopped unit, the start again after the backup. While that
  #     fails it is retried every 15 minutes, until it succeeds, the next backup of the unit
  #     takes the retry over, or someone stops it.
  # So the unit is down from the first backup's start of reading to the last one's end of it.

  # systemctl's reading of a name: one without a unit type suffix is a service. Normalised so
  # that "foo" and "foo.service" in two backups share one quiesce unit.
  unitTypes = [ "service" "socket" "device" "mount" "automount" "swap" "target" "path" "timer" "slice" "scope" ];
  normalizeUnit = unit:
    if lib.any (type: lib.hasSuffix ".${type}" unit) unitTypes then unit else "${unit}.service";

  # The unit's part in the names of its quiesce and restart units: "foo.service" -> "foo".
  unitSuffix = unit: lib.replaceStrings [ "@" ] [ "-" ] (lib.removeSuffix ".service" (normalizeUnit unit));
  quiesceName = unit: "restic-quiesce-${unitSuffix unit}";
  restartName = unit: "restic-restart-${unitSuffix unit}";
  holdName = name: "restic-hold-${name}";

  quiescingBackups = lib.filterAttrs (_: backup: backup.stopServices != [ ]) cfg.backups;
  quiescedUnits = lib.unique (lib.concatMap (backup: map normalizeUnit backup.stopServices) (lib.attrValues quiescingBackups));

  # Starting the quiesce unit. "restart" in its RuntimeDirectory marks the unit for starting
  # again; RuntimeDirectory goes away with the quiesce unit, so the mark cannot outlive it.
  quiesceStopScript = unit:
    pkgs.writeShellApplication {
      name = "${quiesceName unit}-stop";
      runtimeInputs = [ pkgs.coreutils pkgs.gawk config.systemd.package ];
      text = ''
        unit=${lib.escapeShellArg unit}
        restart=${lib.escapeShellArg "${restartName unit}.service"}
        mark="$RUNTIME_DIRECTORY/restart"

        # A start that failed after an earlier backup and is still being retried: taken over, so
        # the retry cannot start the unit under restic, and the unit is started after this backup.
        if [ "$(systemctl show --property=ActiveState --value "$restart")" = activating ]; then
          touch "$mark"
        fi
        systemctl stop "$restart"

        state=$(systemctl show --property=ActiveState --value "$unit")
        substate=$(systemctl show --property=SubState --value "$unit")
        # A start or restart job: the restart's stop half shows the unit deactivating, and between
        # its halves the unit is inactive.
        starting=false
        if systemctl list-jobs --full --no-legend \
          | awk -v unit="$unit" '$2 == unit && ($3 == "start" || $3 == "restart") { found = 1 } END { exit !found }'; then
          starting=true
        fi

        # Started again afterwards: a unit that is up or on its way up, a crash loop waiting out
        # RestartSec included. A unit stopped by hand, or failed, is left as it is.
        case "$state" in
          active | reloading | refreshing | activating) touch "$mark" ;;
        esac
        if [ "$starting" = true ]; then
          touch "$mark"
        fi

        # A start or restart under way is let finish first. The monitoring platform migrates its
        # database before READY=1, for up to hours: stopping it would roll the migration back only
        # to redo it afterwards, and cancelling a restart fails whoever asked for it (a switch,
        # say). `start` joins the pending job and returns when it does. A crash loop waiting out
        # RestartSec has nothing under way.
        if [ "$starting" = true ] || { [ "$state" = activating ] && [[ "$substate" != auto-restart* ]]; }; then
          systemctl start "$unit" || true
        fi

        # Unconditionally: this also cancels a pending automatic restart and waits out a stop
        # under way. On a unit already down it does nothing, failed state included.
        systemctl stop "$unit"
      '';
    };

  # Stopping the quiesce unit. The restart unit's first run is the start; the quiesce unit is done
  # whether that fails or not, as retrying it is the restart unit's.
  quiesceStartScript = unit:
    pkgs.writeShellApplication {
      name = "${quiesceName unit}-start";
      runtimeInputs = [ config.systemd.package ];
      text = ''
        if [ -e "$RUNTIME_DIRECTORY/restart" ]; then
          systemctl start ${lib.escapeShellArg "${restartName unit}.service"} || true
        fi
      '';
    };

  quiesceServiceFor = unit: {
    description = "Keep ${unit} stopped while restic backups read it";
    # A switch must not restart it under a running backup: its stop starts the unit.
    restartIfChanged = false;
    # Not ordered against the restart unit: this one's stop waits for that one's start, which
    # an ordering would hold until the stop is done.
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

  # The unit's start after a backup. Retried while it fails, without waiting for the next backup
  # of the unit; nothing runs while there is nothing to retry. Stopping it gives up.
  restartScript = unit:
    pkgs.writeShellApplication {
      name = restartName unit;
      runtimeInputs = [ config.systemd.package ];
      text = "systemctl start ${lib.escapeShellArg unit}";
    };

  restartServiceFor = unit: {
    description = "Start ${unit} again after restic backups read it";
    restartIfChanged = false;
    # Retried for as long as the start fails.
    unitConfig.StartLimitIntervalSec = 0;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe (restartScript unit);
      Restart = "on-failure";
      RestartSec = "15min";
    };
  };

  # One unit per backup, upstream's restic-backups-<name> with its timer. The unit runs as a
  # dynamic user holding only CAP_DAC_READ_SEARCH (read any file, whatever its owner and mode),
  # and what restic may touch is decided per run by the Landlock sandbox above, not by mounts:
  # an empty root would also apply to the "+" hold commands, where systemctl, chrooted,
  # ignores its command and exits 0. The systemd hardening below is the second layer.
  serviceConfigFor = name: backup:
    let
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
            "${lib.getExe backup.sandbox} backup ${pkgs.coreutils}/bin/true"
            "${resticFor name} unlock"
          ]
          ++ lib.optional quiesce (hold "start")
        );
        # Appended to upstream's backup command: release the stopped units, then retention and
        # check, so the units are not held down through them. The release only sets their start
        # off (systemd then stops the quiesce units, which starts them); the check does not wait
        # for it. A failed backup never gets here; BindsTo= on the hold unit releases them then.
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
            finishes: their start is set off before prune and check, which do not wait for
            it. Use this for services whose on-disk state is only consistent while they are
            down, such as a database with a write-ahead log.

            Nothing is stopped until the repository has been opened and unlocked, so an
            unreachable backend leaves the units alone. Only units that were running or on
            their way up when the backup started are started again, a crash loop waiting
            out RestartSec included; a unit stopped by hand, or failed, is left as it is. A
            start or restart under way is waited for, then the unit is stopped. They are also
            started again when the backup fails. A start that fails is retried every 15
            minutes by `restic-restart-<unit>`, until it succeeds or that unit is stopped.

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

        # Removed: the backup runs as a dynamic user now. Kept, hidden, so that a configuration
        # still setting it is told why below, rather than that the option does not exist.
        # (lib.mkRemovedOptionModule cannot be used in a submodule: it asserts through
        # `assertions`, which a submodule does not have.)
        user = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          visible = false;
          description = "Removed; the backup runs as the dynamic user `restic-<name>`.";
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
        {
          assertion = backup.user == null;
          message = "common.restic.backups.${name}.user has been removed: the backup runs as the dynamic user restic-${name}, which reads its paths whatever their owner (CAP_DAC_READ_SEARCH, confined by Landlock). Remove the setting.";
        }
      ])
      cfg.backups)
    ++ [
      {
        # "@" is folded into "-" in the quiesce and restart units' names.
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
      // lib.listToAttrs (map (unit: lib.nameValuePair (restartName unit) (restartServiceFor unit)) quiescedUnits);
  };
}
