{ config, lib, pkgs, ... }:

# Push the newest solar/battery readings to a ThingSpeak channel, once a minute.
#
# A reader, not a producer. Everything it sends was already collected by
# modules/inverter-monitoring.nix and modules/bms-monitoring.nix and already stored by the
# monitoring platform; this only lifts the latest value of a handful of fields back out through
# the receiver's read API and forwards them off-box. Nothing here is a source of truth, so a
# missed minute costs a gap in a chart and nothing else -- which is why every failure path below
# ends in "log it and let the next tick try", never in retrying harder or spooling to disk.
#
# Not to be confused with common.monitoring, which reports *this host's health* to Healthchecks,
# or with common.mpTunnel, which is the collector's own path to the receiver. This module owns a
# second, independent iroh hop: its own ticket, its own socket, its own group. The point of the
# separation is that the two consumers can be pointed at different receivers -- or one moved --
# by re-encrypting one blob, with no change to the other.
#
# Bash rather than a Rust binary, unlike the producers. They are Rust because they speak OTLP
# protobuf over a socket and parse serial protocols; this is two JSON GETs and one POST with a
# query string, which is what modules/monitoring.nix already does with curl and jq.

let
  cfg = config.common.thingspeak;

  pkg = pkgs.callPackage ../packages/iroh-ssh/package.nix { };

  ticketPath = "${cfg.tunnel.credentialDirectory}/iroh-ticket";
  platformKeyPath = "${cfg.platform.credentialDirectory}/${cfg.platform.apiKeyCredential}";
  channelKeyPath = "${cfg.credentialDirectory}/${cfg.keyCredential}";

  # The socket lives in a systemd-provisioned RuntimeDirectory, which is named rather than
  # pathed -- so the directory the option implies has to be recovered from the path, and
  # constrained to a shape RuntimeDirectory= can express. Same reasoning, and the same
  # assertion, as modules/monitoring-platform-tunnel.nix.
  tunnelRuntimeDir = builtins.dirOf cfg.tunnel.socketPath;
  tunnelRuntimeName = builtins.baseNameOf tunnelRuntimeDir;

  tunnelUser = "thingspeak-tunnel";

  # One read per distinct measurement type, not one per field: the eight fields the spec lists
  # live in two records, and the read API filters on `type` with no field selector at all. Each
  # type gets a numbered slot so the script can name its response file without ever
  # interpolating a type into a path.
  types = lib.unique (map (m: m.type) cfg.measurements);
  typeSlots = lib.listToAttrs (lib.imap1 (i: t: lib.nameValuePair t (toString i)) types);

  readTable = lib.concatStringsSep "\n" (lib.imap1 (i: t: "${toString i} ${t}") types);

  # The ThingSpeak field number is the position in `measurements`, resolved here rather than in
  # the script so the wire format is a function of the option and nothing else. Each line is
  # `<field-number> <slot> <body-field>`.
  fieldTable = lib.concatStringsSep "\n" (
    lib.imap1 (n: m: "${toString n} ${typeSlots.${m.type}} ${m.field}") cfg.measurements
  );

  reportScript = pkgs.writeShellApplication {
    name = "thingspeak-report";
    runtimeInputs = [ cfg.tools.coreutils cfg.tools.curl cfg.tools.jq ];
    text = ''
      socket=${lib.escapeShellArg cfg.platform.socketPath}
      update_url=${lib.escapeShellArg cfg.updateUrl}
      interval=${toString cfg.intervalSeconds}

      log() {
        echo "thingspeak: $*"
      }

      # Both keys come from systemd, decrypted in PID 1 before this sandbox existed. The
      # explicit unset/unreadable branches are not defensive noise: the unit is conditioned on
      # the blobs existing, so reaching either of these means the credential machinery itself
      # is misconfigured, and that has to read differently in the journal from "nothing to
      # send".
      if [ -z "''${CREDENTIALS_DIRECTORY:-}" ]; then
        log "CREDENTIALS_DIRECTORY is not set"
        exit 1
      fi
      platform_key_file="$CREDENTIALS_DIRECTORY/${cfg.platform.apiKeyCredential}"
      channel_key_file="$CREDENTIALS_DIRECTORY/${cfg.keyCredential}"
      for f in "$platform_key_file" "$channel_key_file"; do
        if [ ! -r "$f" ]; then
          log "credential is missing or unreadable: $f"
          exit 1
        fi
      done

      work="$(mktemp -d)"
      trap 'rm -rf "$work"' EXIT

      # Secrets go into curl config files, never argv. /proc/<pid>/cmdline is world-readable and
      # the ThingSpeak key would otherwise sit in it inside the URL, which is where the spec
      # puts it on the wire. The files are inside a 0700 mktemp directory on a PrivateTmp mount
      # owned by this run's DynamicUser, and the trap above takes them with it.
      #
      # The URL is passed as an argument for the reads (an address, not a secret) and through
      # the config file for the POST (the key is in its query string).
      auth_conf="$work/auth.conf"
      printf 'header = "Authorization: Bearer %s"\n' "$(cat "$platform_key_file")" > "$auth_conf"

      # The window is [start, end), which is exactly the read API's inclusive `from` and
      # exclusive `to`. `end` is the current time truncated to the interval, so consecutive runs
      # cover consecutive windows with no overlap and no gap -- and the timestamp reported to
      # ThingSpeak is a grid point rather than whenever this unit happened to be scheduled.
      #
      # Integer nanoseconds rather than RFC 3339 for the bounds: the API accepts both, and an
      # integer cannot be misparsed. `created_at` has to be a string, and the spec fixes its
      # shape -- ISO 8601, seconds, Z.
      now="$(date -u +%s)"
      end=$(( now - now % interval ))
      start=$(( end - interval ))
      created_at="$(date -u -d "@$end" +%Y-%m-%dT%H:%M:%SZ)"

      while read -r slot kind <&3; do
        [ -n "$slot" ] || continue
        # --fail-with-body, not --fail: curl exits 0 on a 401, so without it an unauthorised
        # read would look like a record with every field null -- i.e. like a quiet inverter.
        if ! curl --silent --show-error --fail-with-body \
             --config "$auth_conf" \
             --unix-socket "$socket" \
             --output "$work/read-$slot" \
             "http://localhost/v1/measurements?type=$kind&from=''${start}000000000&to=''${end}000000000&limit=1"; then
          log "reading $kind from the monitoring platform failed"
          exit 1
        fi
      done 3<<'READS'
      ${readTable}
      READS

      # The read API orders event_time DESC, so row 0 is the newest record in the window and
      # "the last value" is a field of that record. A field that is null there is omitted, not
      # searched for further back: the producers never drop a key, they null it, so a null means
      # the device did not answer for that reading and the previous value is not a substitute.
      #
      # `select(type == "number")` is what keeps the request well-formed -- a ThingSpeak field
      # takes a number, and an absent record indexes to null rather than erroring.
      params="$work/params"
      : > "$params"
      while read -r number slot field <&3; do
        [ -n "$number" ] || continue
        value="$(jq -r --arg f "$field" \
          '.measurements[0].body[$f] | if type == "number" then . else empty end' \
          "$work/read-$slot")"
        if [ -n "$value" ]; then
          printf 'field%s=%s\n' "$number" "$value" >> "$params"
        fi
      done 3<<'FIELDS'
      ${fieldTable}
      FIELDS

      count="$(wc -l < "$params")"
      if [ "$count" -eq 0 ]; then
        log "no values in [$start, $end); nothing to send"
        exit 0
      fi

      query="api_key=$(cat "$channel_key_file")&created_at=$created_at"
      while read -r param; do
        query="$query&$param"
      done < "$params"

      post_conf="$work/post.conf"
      printf 'url = "%s?%s"\n' "$update_url" "$query" > "$post_conf"

      # Success is the response, not curl's exit status -- the same rule as the DNS probe in
      # modules/connectivity-watchdog.nix, and for a sharper reason here: ThingSpeak rejects an
      # update with a body of "0" under HTTP 200, so a status check alone would report every
      # rejected write as a success. `|| true` keeps a connection failure in this branch too,
      # where it gets a log line, instead of letting errexit kill the script silently.
      # Created before the request, not after: curl opens its --output file only when data
      # arrives, so on a connection failure there is no file at all -- and under errexit the
      # `cat` below would then kill the script one line before the log that explains why.
      body="$work/response"
      : > "$body"
      code="$(curl --silent --show-error --request POST --retry 3 \
        --config "$post_conf" \
        --output "$body" \
        --write-out '%{http_code}' || true)"
      response="$(cat "$body")"

      case "$code" in
        2??) ;;
        *)
          log "update failed: HTTP $code (''${response:-no body})"
          exit 1
          ;;
      esac

      if [ "$response" = "0" ]; then
        log "update rejected by ThingSpeak (HTTP $code, body 0)"
        exit 1
      fi

      log "sent $count field(s) at $created_at (entry $response)"
    '';
  };

  # Lifted from modules/monitoring-platform-tunnel.nix: same binary, same threat model, and
  # nothing this endpoint does needs more than that one.
  tunnelHardening = {
    NoNewPrivileges = true;
    CapabilityBoundingSet = "";
    SystemCallFilter = [ "@system-service" "~@resources" ];
    SystemCallArchitectures = "native";
    MemoryDenyWriteExecute = true;
    ProcSubset = "pid";
    # AF_NETLINK: iroh's network monitor watches route/interface changes.
    # AF_UNIX: both the forwarded socket and glibc NSS lookups via nscd.
    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_NETLINK" "AF_UNIX" ];
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
    ProtectProc = "invisible";
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    RemoveIPC = true;
    KeyringMode = "private";
    UMask = "0077";
  };
in
{
  options.common.thingspeak = {
    enable = lib.mkEnableOption "reporting the latest solar and battery readings to a ThingSpeak channel";

    intervalSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = ''
        The interval, in seconds. One value because it is one thing: it is both how often the
        timer fires and the width of the window each run reads, so every run covers exactly the
        interval that ended when it started and consecutive runs tile the timeline.

        Worth knowing what it costs to leave at the default. Both producers emit once a minute,
        so a 60-second window holds either one record or -- if a serial cycle ran long, or the
        producer restarted -- none, and a window with none sends nothing. Widening this trades
        chart resolution for immunity to that jitter; it does not backfill, because nothing here
        does (see the timer).

        Seconds rather than a systemd duration string because the script does integer arithmetic
        on it and the assertions below relate it to timeoutSeconds.
      '';
    };

    timeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 45;
      description = ''
        TimeoutStartSec on the reporting unit, in seconds.

        Must stay below intervalSeconds, which is asserted: systemd will not start a second
        instance while one is running, so a run allowed to outlive its own interval does not
        merely overlap the next tick, it *replaces* it -- a single wedged socket read would then
        silently halve the reporting rate, or stop it entirely.
      '';
    };

    updateUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://api.thingspeak.com/update";
      description = ''
        The ThingSpeak update endpoint. The channel is identified by the write API key, not by
        this URL, so there is nothing host-specific in it.

        An option rather than a constant only so a VM test can point it at a local recorder;
        this repo's tests have no internet at all, and the alternative is intercepting DNS and
        TLS for a hostname (tests/doh-interceptor.nix) to prove something about query-string
        assembly.
      '';
    };

    measurements = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          type = lib.mkOption {
            type = lib.types.str;
            example = "bms.status";
            description = "The measurement `type` to read, matched exactly by the read API.";
          };
          field = lib.mkOption {
            type = lib.types.str;
            example = "soc_percent";
            description = "The key to take out of that record's `body`.";
          };
        };
      });
      default = [
        { type = "bms.status"; field = "soc_percent"; }
        { type = "bms.status"; field = "pack_power_watts"; }
        { type = "bms.status"; field = "temperature_1_celsius"; }
        { type = "bms.status"; field = "pack_voltage_volts"; }
        { type = "inverter.status"; field = "pv1_charging_power_watts"; }
        { type = "inverter.status"; field = "pv2_charging_power_watts"; }
        { type = "inverter.status"; field = "output_active_power_watts"; }
        { type = "inverter.status"; field = "battery_voltage_volts"; }
      ];
      description = ''
        What to send, in ThingSpeak field order. **The position in this list is the field
        number**: the first entry is `field1`, the second `field2`, and so on.

        Which makes the list order part of the wire format, and reordering it a silent
        rewrite of history -- every entry already in the channel keeps the number it was sent
        under, so `field2` would mean one thing before the change and another after, with
        nothing in the data to mark where. Append; do not reorder. A channel has exactly eight
        fields, so the list is capped at eight (asserted) rather than having a ninth entry
        dropped by the API without comment.

        Note this is a `type` plus a key inside that record's `body`, which is two things and
        not one dotted name: `bms.status.cell` and `bms.status.alarm` are themselves record
        types, so `bms.status.temperature_1_celsius` would be ambiguous. Entries sharing a type
        cost nothing extra -- the reads are per distinct type.
      '';
    };

    platform = {
      credentialDirectory = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Directory containing the systemd-creds-encrypted monitoring-platform API key.
          Required when enabled; left unset so a host cannot silently forget it.

          Its own key rather than the collector's, so that revoking this reader cannot take the
          measurement path down with it. The receiver's keys carry no scope, so this is a
          separation of blast radius, not of permission.
        '';
      };

      apiKeyCredential = lib.mkOption {
        type = lib.types.str;
        default = "mp-api-key";
        description = ''
          Credential id, and file name, of the API key. The name is authenticated into the blob
          by `systemd-creds encrypt --name=`, so the two cannot differ.
        '';
      };

      socketPath = lib.mkOption {
        type = lib.types.str;
        default = cfg.tunnel.socketPath;
        defaultText = lib.literalExpression "config.common.thingspeak.tunnel.socketPath";
        description = ''
          The unix socket the read API is served on. Defaults to this module's own tunnel, which
          is the deployed topology: the receiver is reached over iroh even when it is on the
          same box, so moving it off-box changes a credential rather than this option.

          Separate from the tunnel's own option so a host -- or a VM test with no relay -- can
          point the reader straight at a local receiver instead.
        '';
      };

      socketGroup = lib.mkOption {
        type = lib.types.str;
        default = tunnelUser;
        description = ''
          Group owning [](#opt-common.thingspeak.platform.socketPath), joined as a supplementary
          group. The socket sits in a 0750 group-owned runtime directory, and that mode is the
          actual access control -- so this is what grants the reader access, not tidiness.
        '';
      };
    };

    credentialDirectory = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Directory containing the systemd-creds-encrypted ThingSpeak *write* API key. Required
        when enabled; left unset so a host cannot silently forget it.

        Outside the store, and outside the Nix configuration entirely, for the reason
        modules/restic.nix states about backup repositories: the key identifies the channel, so
        having it in the config would put an identifiable part of this host's telemetry in a
        public repository.
      '';
    };

    keyCredential = lib.mkOption {
      type = lib.types.str;
      default = "thingspeak-key";
      description = "Credential id, and file name, of the ThingSpeak write API key.";
    };

    tunnel = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Serve a local unix socket that forwards over iroh to the receiver named by an
          encrypted ticket.

          On by default because it is the deployed shape and the reader is useless without
          something answering [](#opt-common.thingspeak.platform.socketPath). Turn it off only
          when that socket is provided some other way, which the assertions below check for.
        '';
      };

      credentialDirectory = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Directory containing the systemd-creds-encrypted `iroh-ticket`: the address to dial,
          as printed by `iroh-ssh-ticket`. Required when the tunnel is enabled.

          Not a secret -- anyone holding it can open the pipe, and the API key behind the socket
          is what authenticates. It is encrypted anyway because that is what makes moving the
          far side a credential swap: re-encrypt this blob with the new host's ticket and
          restart, with no change to this configuration at all.
        '';
      };

      socketPath = lib.mkOption {
        type = lib.types.path;
        default = "/run/${tunnelUser}/upstream.sock";
        description = ''
          Where the tunnel listens. The socket is mode 0660 inside a 0750 directory owned by the
          `${tunnelUser}` group, so reaching it means joining that group.

          Must be one level under /run: the directory is provisioned by RuntimeDirectory=, which
          names a directory rather than taking a path.
        '';
      };
    };

    requireClockSync = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Skip runs until the clock is reported synchronised, by conditioning the unit on
        [](#opt-common.thingspeak.syncedMarker).

        This is the spec's "if the clock is not synchronized, exit early", and a condition is
        what makes it a skip rather than a failure -- nothing is broken, the host just does not
        yet know what time it is. It matters more here than for a local producer: `created_at`
        is sent to a third party that has no notion of an uncertain timestamp and no way to
        correct one later, so a Pi that boots near the epoch would stamp real readings into 1970
        in a channel that cannot be edited.

        Unlike [](#opt-common.systemMetrics.requireClockSync) this stays on when the collector's
        clock-correction path is available, because that path cannot help: it rewrites
        timestamps on their way *into* the store, and this reads them back out.
      '';
    };

    syncedMarker = lib.mkOption {
      type = lib.types.path;
      default = "/run/systemd/timesync/synchronized";
      description = ''
        The path whose existence means "the clock is synchronised". Which daemon owns the clock
        decides this, so it is an option rather than a constant; modules/time-sync.nix points it
        at chrony's marker on hosts where chrony owns the clock.
      '';
    };

    tools = {
      coreutils = lib.mkPackageOption pkgs "coreutils" { };
      curl = lib.mkPackageOption pkgs "curl" { };
      jq = lib.mkPackageOption pkgs "jq" { };
    };
  };

  config = lib.mkIf cfg.enable {
    # Every one of these fails invisibly if left to the runtime: a skipped unit, an empty
    # request, or a field number that silently means something new. Same reasoning as the timing
    # assertions in modules/connectivity-watchdog.nix.
    assertions = [
      {
        assertion = cfg.platform.credentialDirectory != null;
        message = "common.thingspeak.platform.credentialDirectory must be set: the reader needs a monitoring-platform API key, and the receiver enforces one on the read path.";
      }
      {
        assertion = cfg.credentialDirectory != null;
        message = "common.thingspeak.credentialDirectory must be set: it holds the ThingSpeak write API key, which also identifies the channel and so must not live in the Nix configuration.";
      }
      {
        assertion = !cfg.tunnel.enable || cfg.tunnel.credentialDirectory != null;
        message = "common.thingspeak.tunnel.credentialDirectory must be set when the tunnel is enabled (or set common.thingspeak.tunnel.enable = false and point common.thingspeak.platform.socketPath at a socket something else serves).";
      }
      {
        # Otherwise the reader posts at a socket this module was going to serve and now does
        # not, and every run fails on a connection refused.
        assertion = cfg.tunnel.enable || cfg.platform.socketPath != cfg.tunnel.socketPath;
        message = ''
          common.thingspeak.tunnel is disabled but common.thingspeak.platform.socketPath still
          points at ${cfg.tunnel.socketPath}, which nothing now serves. Point it at another
          receiver's socket, or enable the tunnel.
        '';
      }
      {
        assertion = tunnelRuntimeDir == "/run/${tunnelRuntimeName}";
        message = "common.thingspeak.tunnel.socketPath (${cfg.tunnel.socketPath}) must be one level under /run: the directory is provisioned by RuntimeDirectory=, which takes a name and not a path.";
      }
      {
        assertion = cfg.platform.socketGroup != "";
        message = "common.thingspeak.platform.socketGroup must name the group owning common.thingspeak.platform.socketPath; the socket's 0750 directory is what gates access to it.";
      }
      {
        assertion = cfg.measurements != [ ];
        message = "common.thingspeak.measurements is empty, so every run would have nothing to send. List at least one measurement, or disable common.thingspeak.";
      }
      {
        assertion = lib.length cfg.measurements <= 8;
        message = "common.thingspeak.measurements has ${toString (lib.length cfg.measurements)} entries, but a ThingSpeak channel has exactly 8 fields: everything past the eighth would be accepted by the API and silently discarded.";
      }
      {
        # The type goes into a query string unencoded, and an unknown query parameter is a hard
        # 400 from the read API -- so a `&` in a type name would not misread a field, it would
        # fail the whole run.
        assertion = lib.all (m: builtins.match "[A-Za-z0-9._-]+" m.type != null) cfg.measurements;
        message = "every common.thingspeak.measurements type must match [A-Za-z0-9._-]+: it is interpolated into the read API's query string, where an unknown parameter is a 400.";
      }
      {
        assertion = cfg.timeoutSeconds < cfg.intervalSeconds;
        message = "common.thingspeak.timeoutSeconds (${toString cfg.timeoutSeconds}) must be below intervalSeconds (${toString cfg.intervalSeconds}): systemd will not start a second instance while one is running, so a run that can outlive its interval replaces the next tick rather than overlapping it.";
      }
    ];

    systemd.services.thingspeak = {
      description = "Report the latest solar and battery readings to ThingSpeak";
      # Ordering only, never Requires. The tunnel is Type=simple, so After= means its process
      # forked, not that its socket is bound -- the first run of a boot may well find nothing
      # there. That is the right outcome: it fails, says so, and the next tick is one interval
      # away. A wait loop would buy a few seconds of chart at the cost of a unit that can hang.
      after = [
        "thingspeak-tunnel.service"
        "mp-collector.service"
        "monitoring-platform.service"
        "time-sync.target"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];

      # The clock gate, plus the credentials. Conditions rather than checks inside the script
      # because systemd already knows how to skip a unit without calling it a failure, and an
      # unprovisioned host should be quiet rather than failing every minute forever.
      unitConfig.ConditionPathExists = [ platformKeyPath channelKeyPath ]
        ++ lib.optional cfg.requireClockSync cfg.syncedMarker;

      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe reportScript;

        LoadCredentialEncrypted = [
          "${cfg.platform.apiKeyCredential}:${platformKeyPath}"
          "${cfg.keyCredential}:${channelKeyPath}"
        ];

        # No identity of its own and no state; the one privilege it needs is membership of the
        # group gating the socket it reads from.
        DynamicUser = true;
        SupplementaryGroups = [ cfg.platform.socketGroup ];

        TimeoutStartSec = "${toString cfg.timeoutSeconds}s";

        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
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
        ProtectProc = "invisible";
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RemoveIPC = true;
        KeyringMode = "private";
        UMask = "0077";
        SystemCallFilter = [ "@system-service" ];
        SystemCallArchitectures = "native";
        # AF_UNIX reaches the receiver's socket and nscd; AF_INET/AF_INET6 are the outbound
        # HTTPS; AF_NETLINK is what glibc's resolver uses to find the local interfaces.
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" "AF_NETLINK" ];
      };
    };

    systemd.timers.thingspeak = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "${toString cfg.intervalSeconds}s";
        OnUnitActiveSec = "${toString cfg.intervalSeconds}s";
        # Tight on purpose, unlike the watchdog's: the window a run reads is one interval wide,
        # so slack that approaches the interval starts producing runs whose window has already
        # been covered by the previous one.
        AccuracySec = "1s";
        # No Persistent. Catching up after downtime would mean posting a burst of stale
        # created_at stamps to a third party, and the missing minutes are the honest record of
        # a host that was off.
        Unit = "thingspeak.service";
      };
    };

    environment.systemPackages = lib.mkIf cfg.tunnel.enable [ pkg ];

    # A real user and group, not DynamicUser, for the two reasons modules/monitoring-platform-tunnel.nix
    # gives: a dynamic group does not exist at evaluation time, so nothing can assert against it
    # or join it from another unit's Nix config, and a dynamic user's RuntimeDirectory can land
    # behind /run/private, a 0700 root:root gate no group membership gets through.
    users.users.${tunnelUser} = lib.mkIf cfg.tunnel.enable {
      isSystemUser = true;
      group = tunnelUser;
      description = "ThingSpeak reporter's tunnel to the monitoring platform";
    };
    users.groups = lib.mkIf cfg.tunnel.enable { ${tunnelUser} = { }; };

    systemd.services.thingspeak-tunnel = lib.mkIf cfg.tunnel.enable {
      description = "Local socket forwarding to the monitoring platform over iroh, for ThingSpeak reporting";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      # Skip (instead of crash-loop) until the operator provisions the blob.
      unitConfig.ConditionPathExists = [ ticketPath ];
      serviceConfig = tunnelHardening // {
        ExecStart = "${lib.getExe' pkg "iroh-uds-connect"} ${cfg.tunnel.socketPath}";
        LoadCredentialEncrypted = [ "iroh-ticket:${ticketPath}" ];
        User = tunnelUser;
        Group = tunnelUser;
        RuntimeDirectory = tunnelRuntimeName;
        RuntimeDirectoryMode = "0750";
        Restart = "always";
        RestartSec = 5;
      };
    };
  };
}
