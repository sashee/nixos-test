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

  backupToResticConfig = name: rawBackup:
    let
      backup = rawBackup // { inherit name; };
      requiredPrune = !backup.prune.ignoreErrors;
    in
    {
      inherit (backup) paths;
      exclude = backup.exclude;
      extraBackupArgs = [ "--group-by=" ];
      initialize = true;
      package = wrapperFor name backup;
      passwordFile = "$CREDENTIALS_DIRECTORY/repository-password";
      repository = backup.repository;
      pruneOpts = lib.optionals requiredPrune ([ "--group-by=" ] ++ backup.prune.opts);
      runCheck = true;
      checkOpts = [ ];
      timerConfig = backup.timerConfig;
      user = backup.user;
    };

  ignoredPruneCommand = name: backup:
    let
      restic = lib.getExe (wrapperFor name backup);
    in
    "-${restic} forget --prune --group-by= ${lib.concatStringsSep " " backup.prune.opts}";

  serviceConfigFor = name: rawBackup:
    let
      backup = rawBackup // { inherit name; };
      credentials = [ "repository-password" ] ++ backup.backend.credentials;
    in
    {
      environment = backendEnvironment backup;
      unitConfig.ConditionPathExists = map (credentialPath backup) credentials;
      serviceConfig = {
        LoadCredential = map (credential: "${credential}:${credentialPath backup credential}") credentials;
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
      } // lib.optionalAttrs backup.prune.ignoreErrors {
        ExecStartPost = ignoredPruneCommand name backup;
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
    services.restic.backups = lib.mapAttrs backupToResticConfig cfg.backups;
    systemd.services = lib.mapAttrs'
      (name: backup: lib.nameValuePair "restic-backups-${name}" (serviceConfigFor name backup))
      cfg.backups;
  };
}
