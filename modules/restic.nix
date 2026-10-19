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
          ${sandbox} repository ${lib.getExe pkgs.restic} unlock
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
  # The runtime directory also holds the list of units the root start script starts again, so it
  # is never writable here.
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

  # The units that were running when the backup started, so a unit someone stopped for
  # maintenance is not started again. RuntimeDirectory exists before the first Exec* runs
  # and is removed with the unit, so this cannot outlive a run. restic cannot write it: the
  # sandbox gives it the directory read-only, in the backup phase only.
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

  # One unit per backup, upstream's restic-backups-<name> with its timer. The unit runs as a
  # dynamic user holding only CAP_DAC_READ_SEARCH (read any file, whatever its owner and mode),
  # and what restic may touch is decided per run by the Landlock sandbox above, not by mounts:
  # an empty root would also apply to the "+" stop/start scripts, where systemctl, chrooted,
  # ignores its command and exits 0. The systemd hardening below is the second layer.
  serviceConfigFor = name: rawBackup:
    let
      backup = rawBackup // { inherit name; };
      credentials = [ "repository" "repository-password" ] ++ backup.backend.credentials;
      quiesce = backup.stopServices != [ ];
      # "+" runs the command fully privileged: systemd then skips User=, the capability and
      # namespacing options and the seccomp filters for it, which is what lets systemctl
      # (root, AF_UNIX to PID 1) work from inside this otherwise sandboxed unit.
      startServices = "+${lib.getExe (startScript name backup)}";
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
        # fails on a missing backup path, so nothing is stopped for a backup that cannot run.
        ExecStartPre = lib.mkAfter (
          [ "${lib.getExe (sandboxFor name backup)} backup ${pkgs.coreutils}/bin/true" ]
          ++ lib.optional quiesce "+${lib.getExe (stopScript name backup)}"
        );
        # Appended to upstream's backup command: restart the stopped units, then retention and
        # check, so the check does not run with the units down.
        ExecStart = lib.mkAfter (
          lib.optional quiesce startServices
          ++ [ (lib.getExe (maintenanceScript name backup)) ]
        );
      } // lib.optionalAttrs quiesce {
        # An ExecStart list aborts at the first failing command, so without this a failed
        # backup would leave the units stopped. Stopping the unit kills restic first.
        ExecStopPost = lib.mkAfter [ startServices ];
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
          assertion = !lib.any (unit: unit == "restic-backups-${name}" || unit == "restic-backups-${name}.service") backup.stopServices;
          message = "common.restic.backups.${name}.stopServices must not contain its own unit, restic-backups-${name}.service.";
        }
        {
          # systemd checks the dynamic user's name only when the unit starts, and then refuses
          # to run it at all.
          assertion = builtins.match "[A-Za-z0-9_-]+" name != null && lib.stringLength "restic-${name}" <= 31;
          message = "common.restic.backups.${name}: the backup runs as the dynamic user restic-${name}, so its name must be at most 24 characters of [A-Za-z0-9_-].";
        }
      ])
      cfg.backups);

    services.restic.backups = lib.mapAttrs backupToResticConfig cfg.backups;
    systemd.services = lib.mapAttrs'
      (name: backup: lib.nameValuePair "restic-backups-${name}" (serviceConfigFor name backup))
      cfg.backups;
  };
}
