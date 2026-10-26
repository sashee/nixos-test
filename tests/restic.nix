{ nixpkgs, pkgs, commonDesktopModule, stateVersion }:

let
  resticLib = import ../lib/restic.nix { lib = nixpkgs.lib; };
  nixpkgsDate = nixpkgs.lastModifiedDate;
  testClockDate = "${builtins.substring 0 4 nixpkgsDate}-${builtins.substring 4 2 nixpkgsDate}-${builtins.substring 6 2 nixpkgsDate}";
  testClockBase = "${testClockDate}T23:00:00";

  pruneOpts = [ "--keep-last 1" ];
  # kvmclock is an x86-only CPU property: on aarch64 qemu exits at startup with
  # "Property 'host-arm-cpu.kvmclock' not found", and -cpu host needs KVM, which
  # the CI arm64 runner lacks (TCG). ARM guests keep the default CPU model;
  # date -s clock jumps work there without disabling a paravirt clock.
  cpuTuning = nixpkgs.lib.optionals pkgs.stdenv.hostPlatform.isx86_64 [
    "-cpu"
    "host,kvmclock=off"
  ];

  # Stand-in for a service whose on-disk state is only consistent while it is down (the
  # real case being the monitoring platform's WAL-mode SQLite DB). It records its own state
  # into the directory that gets backed up, so the snapshot content proves whether it was
  # running while restic read the files. StartLimitIntervalSec=0: the test stops and starts
  # these back to back, which otherwise trips start-limit-hit. Its start fails while
  # /run/quiesce-fail-<unit> exists.
  quiescedService = unit:
    let
      record = state: ''
        install -d -m 0755 -o backup-user -g users /home/backup-user/quiesce
        printf '%s\n' '${state}' > /home/backup-user/quiesce/${unit}
        chown backup-user:users /home/backup-user/quiesce/${unit}
      '';
    in
    {
      wantedBy = [ "multi-user.target" ];
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        if [ -e /run/quiesce-fail-${unit} ]; then exit 1; fi
        ${record "running"}
      '';
      postStop = record "stopped";
    };

  # A quiesced service that can be held mid-start while /run/quiesce-hold exists, the way the
  # monitoring platform is held in `activating` by a schema migration before READY=1, and mid-stop
  # while /run/quiesce-stop-hold exists. It appends rather than overwrites, so a snapshot shows
  # whether the start or restart it was caught in ran to the end before the backup stopped it,
  # rather than being cut short or not stopped at all.
  startingService = unit:
    let
      log = state: ''
        install -d -m 0755 -o backup-user -g users /home/backup-user/quiesce
        printf '%s\n' '${state}' >> /home/backup-user/quiesce/${unit}
        chown backup-user:users /home/backup-user/quiesce/${unit}
      '';
    in
    {
      wantedBy = [ "multi-user.target" ];
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        ${log "starting"}
        while [ -e /run/quiesce-hold ]; do sleep 0.2; done
        ${log "running"}
      '';
      postStop = ''
        ${log "stopped"}
        while [ -e /run/quiesce-stop-hold ]; do sleep 0.2; done
      '';
    };

  # An HTTPS REST backend signed by a test CA that the client trusts only through the system CA
  # store (security.pki.certificateFiles) -- the bundle the unit's SSL_CERT_FILE points at.
  tlsCert = import ./test-cert.nix { inherit pkgs; } { name = "restic-backend"; sans = [ "restic-backend" ]; };

  # Runs inside the backup's Landlock sandbox -- through the module's own launcher, as an extra
  # ExecStartPre -- and fails the unit on any breach of spec/features/backups.md's hardening: only
  # what the phase needs is readable, nothing is writable but the unit's own directories. Checked
  # from the inside because a sandbox can be weaker than its configuration reads, and no
  # config-shape assertion would notice. Not every denial is Landlock's alone: in the repository
  # phase, which drops CAP_DAC_READ_SEARCH, file permissions deny the root-only paths too, and no
  # phase may write / or the backup paths anyway. Landlock is what denies the world-readable file
  # outside the backup paths (and in the repository phase the one inside), /proc, listing /,
  # writes to the runtime directory and /var/tmp, and, in the backup phase, every read.
  sandboxProbe = phase: pkgs.writeShellScript "restic-sandbox-probe-${phase}" ''
    export PATH=${nixpkgs.lib.makeBinPath [ pkgs.coreutils pkgs.util-linux ]}
    fail() { echo "sandbox probe (${phase}): $*"; exit 1; }
    # Never into /dev/null: it is outside the sandbox, so the redirect would fail before the
    # command ran, and pass for a denial.
    quiet() { "$@" > /tmp/sandbox-probe-out 2>&1; }
    for path in /etc/shadow /var/lib/systemd/credential.secret /etc/credentials/restic/sandbox/repository /root/sandbox-outside /var/lib/sandbox-outside/world-readable /proc/self/status; do
      if quiet cat "$path"; then fail "$path is readable"; fi
    done
    if quiet ls /; then fail "/ can be listed"; fi
    quiet cat "$CREDENTIALS_DIRECTORY/repository-password" || fail "cannot read its credentials"
    for path in /sandbox-probe "$RUNTIME_DIRECTORY/sandbox-probe" /var/tmp/sandbox-probe; do
      if quiet touch "$path"; then fail "$path is writable"; fi
    done
    quiet touch "$CACHE_DIRECTORY/sandbox-probe" || fail "its cache directory is not writable"
    rm -f "$CACHE_DIRECTORY/sandbox-probe"
    # Raising the inheritable set only works for a capability the process holds: a test of the
    # capability that does not need /proc.
    ${if phase == "backup" then ''
      quiet setpriv --inh-caps=+dac_read_search true || fail "does not hold CAP_DAC_READ_SEARCH"
      quiet cat /home/backup-user/sandbox/root-only || fail "cannot read a root-only file in its backup path"
      quiet cat "$RUNTIME_DIRECTORY/includes" || fail "cannot read its --files-from list"
      if quiet touch /home/backup-user/sandbox/sandbox-probe; then fail "its backup path is writable"; fi
    '' else ''
      if quiet setpriv --inh-caps=+dac_read_search true; then fail "holds CAP_DAC_READ_SEARCH"; fi
      if quiet cat /var/lib/sandbox-inside/world-readable; then fail "the backup paths are readable"; fi
    ''}
    echo "sandbox probe (${phase}): ok"
  '';
in
nixpkgs.lib.nixos.runTest {
  name = "restic";
  hostPkgs = pkgs;
  skipTypeCheck = true;

  nodes.client = { config, ... }: {
    imports = [ commonDesktopModule ];

    networking.hostName = "restic-client";
    security.pki.certificateFiles = [ tlsCert.caFile ];
    common.autoUpgrade.enable = false;
    common.monitoring.enable = false;
    common.irohSsh.enable = false;
    # The test advances the clock; keep the Persistent nix-gc.timer from firing mid-test.
    nix.gc.automatic = nixpkgs.lib.mkForce false;
    system.stateVersion = stateVersion;

    users.users.backup-user = {
      isNormalUser = true;
      home = "/home/backup-user";
    };

    # Restic secrets are systemd-creds-encrypted blobs (LoadCredentialEncrypted); encrypt at
    # boot runtime (the host key isn't set up during activation), before the timer-rest backup.
    systemd.services.restic-timer-test-credentials = {
      wantedBy = [ "multi-user.target" ];
      before = [ "restic-backups-timer-rest.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        install -d -m 0700 /etc/credentials/restic/timer-rest
        install -d -m 0755 -o backup-user -g users /home/backup-user/timer-rest

        printf '%s' 'rest:http://restic-backend:8002/timer-rest' | ${pkgs.systemd}/bin/systemd-creds encrypt --name=repository - /etc/credentials/restic/timer-rest/repository
        printf '%s' 'repo-secret'    | ${pkgs.systemd}/bin/systemd-creds encrypt --name=repository-password - /etc/credentials/restic/timer-rest/repository-password
        printf '%s' 'test-user'      | ${pkgs.systemd}/bin/systemd-creds encrypt --name=backend-username - /etc/credentials/restic/timer-rest/backend-username
        printf '%s' 'backend-secret' | ${pkgs.systemd}/bin/systemd-creds encrypt --name=backend-password - /etc/credentials/restic/timer-rest/backend-password
        printf '%s\n' 'timer-rest payload' > /home/backup-user/timer-rest/payload.txt

        chmod 0600 \
          /etc/credentials/restic/timer-rest/repository \
          /etc/credentials/restic/timer-rest/repository-password \
          /etc/credentials/restic/timer-rest/backend-username \
          /etc/credentials/restic/timer-rest/backend-password
        chown backup-user:users /home/backup-user/timer-rest/payload.txt
      '';
    };

    systemd.services.quiesced-one = quiescedService "quiesced-one";
    systemd.services.quiesced-two = quiescedService "quiesced-two";
    systemd.services.quiesced-starting = startingService "quiesced-starting";
    # Crash-loops while /run/quiesce-fail-quiesced-crashing exists, "activating" between attempts.
    systemd.services.quiesced-crashing = nixpkgs.lib.mkMerge [
      (quiescedService "quiesced-crashing")
      { serviceConfig = { Restart = "on-failure"; RestartSec = "2s"; }; }
    ];

    virtualisation.qemu.options = [
      "-rtc"
      "base=${testClockBase},clock=vm"
    ] ++ cpuTuning;

    common.restic.backups.append-ignored = resticLib.rest {
      credentialDirectory = "/etc/credentials/restic/append-ignored";
      paths = [ "/home/backup-user/append-ignored" ];
      prune = {
        ignoreErrors = true;
        opts = pruneOpts;
      };
      timerConfig = null;
    };

    common.restic.backups.append-strict = resticLib.rest {
      credentialDirectory = "/etc/credentials/restic/append-strict";
      paths = [ "/home/backup-user/append-strict" ];
      prune = {
        ignoreErrors = false;
        opts = pruneOpts;
      };
      timerConfig = null;
    };

    common.restic.backups.normal-strict = resticLib.rest {
      credentialDirectory = "/etc/credentials/restic/normal-strict";
      paths = [ "/home/backup-user/normal-strict" ];
      prune = {
        ignoreErrors = false;
        opts = pruneOpts;
      };
      timerConfig = null;
    };

    common.restic.backups.check-damaged = resticLib.rest {
      credentialDirectory = "/etc/credentials/restic/check-damaged";
      paths = [ "/home/backup-user/check-damaged" ];
      prune.opts = [ "--keep-last 99" ];
      timerConfig = null;
    };

    common.restic.backups.timer-rest = resticLib.rest {
      credentialDirectory = "/etc/credentials/restic/timer-rest";
      paths = [ "/home/backup-user/timer-rest" ];
      prune.opts = [ "--keep-last 99" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };

    common.restic.backups.quiesce = resticLib.rest {
      credentialDirectory = "/etc/credentials/restic/quiesce";
      paths = [ "/home/backup-user/quiesce" ];
      stopServices = [ "quiesced-one.service" "quiesced-two.service" "quiesced-starting.service" "quiesced-crashing.service" ];
      prune.opts = [ "--keep-last 99" ];
      timerConfig = null;
    };

    # The same files to a second repository, on the other server, sharing quiesced-two with the
    # backup above. Named without the suffix, so it also shows "foo" and "foo.service" share one
    # quiesce unit.
    common.restic.backups.quiesce-shared = resticLib.rest {
      credentialDirectory = "/etc/credentials/restic/quiesce-shared";
      paths = [ "/home/backup-user/quiesce" ];
      stopServices = [ "quiesced-two" ];
      prune = {
        ignoreErrors = true;
        opts = [ "--keep-last 99" ];
      };
      timerConfig = null;
    };

    common.restic.backups.tls = resticLib.rest {
      credentialDirectory = "/etc/credentials/restic/tls";
      paths = [ "/home/backup-user/tls" ];
      prune.opts = [ "--keep-last 99" ];
      timerConfig = null;
    };

    common.restic.backups.sandbox = resticLib.rest {
      credentialDirectory = "/etc/credentials/restic/sandbox";
      # The second path is world-readable: only Landlock can keep the repository phase out of it.
      paths = [ "/home/backup-user/sandbox" "/var/lib/sandbox-inside" ];
      timerConfig = null;
    };
    # After upstream's pre-start (repository init, the --files-from list), right before the backup.
    systemd.services.restic-backups-sandbox.serviceConfig.ExecStartPre =
      let
        sandbox = nixpkgs.lib.getExe config.common.restic.backups.sandbox.sandbox;
      in
      nixpkgs.lib.mkOrder 2000 (map (phase: "${sandbox} ${phase} ${sandboxProbe phase}") [ "repository" "backup" ]);

    common.restic.backups.s3 = resticLib.s3 {
      credentialDirectory = "/etc/credentials/restic/s3";
      paths = [ "/home/backup-user/s3" ];
      exclude = [ "excluded.txt" ];
      timerConfig = null;
    };
  };

  nodes.backend = { pkgs, ... }: {
    networking = {
      firewall.allowedTCPPorts = [ 3900 8001 8002 8003 ];
      hostName = "restic-backend";
    };

    services.garage = {
      enable = true;
      package = pkgs.garage_1;
      settings = {
        replication_mode = "none";
        rpc_bind_addr = "[::]:3901";
        rpc_public_addr = "[::1]:3901";
        rpc_secret = "5c1915fa04d0b6739675c61bf5907eb0fe3d9c69850c83820f51b4d25d13868c";
        s3_api = {
          s3_region = "us-east-1";
          api_bind_addr = "[::]:3900";
          root_domain = ".s3.garage";
        };
      };
    };

    services.restic.server = {
      enable = true;
      appendOnly = true;
      extraFlags = [ "--no-auth" ];
      listenAddress = "8001";
      dataDir = "/var/lib/restic-append";
    };

    systemd.sockets.restic-rest-normal = {
      listenStreams = [ "8002" ];
      wantedBy = [ "sockets.target" ];
    };

    systemd.services.restic-rest-normal = {
      description = "Normal Restic REST Server";
      after = [ "network.target" "restic-rest-normal.socket" ];
      requires = [ "restic-rest-normal.socket" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = pkgs.writeShellScript "restic-rest-normal" ''
          set -eu
          if [ ! -e /var/lib/restic-normal/.htpasswd ]; then
            ${pkgs.apacheHttpd}/bin/htpasswd -Bbc /var/lib/restic-normal/.htpasswd test-user backend-secret
          fi
          exec ${pkgs.restic-rest-server}/bin/rest-server --path /var/lib/restic-normal
        '';
        Type = "simple";
        User = "restic";
        Group = "restic";
      };
    };

    systemd.services.restic-rest-tls = {
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.restic-rest-server}/bin/rest-server --path /var/lib/restic-tls --listen :8003 --no-auth --tls --tls-cert ${tlsCert.certFile} --tls-key ${tlsCert.keyFile}";
        User = "restic";
        Group = "restic";
      };
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/restic-normal 0750 restic restic -"
      "d /var/lib/restic-tls 0750 restic restic -"
    ];

    virtualisation.diskSize = 3 * 1024;
    virtualisation.qemu.options = [
      "-rtc"
      "base=${testClockBase},clock=vm"
    ] ++ cpuTuning;
    system.stateVersion = stateVersion;
  };

  testScript = ''
    import re

    start_all()

    for node in machines:
        node.wait_for_unit("multi-user.target")

    def by_hostname(hostname):
        for node in machines:
            if node.succeed("hostname").strip() == hostname:
                return node
        raise Exception(f"No machine with hostname {hostname}")

    def service_result(name):
        return client.succeed(f"systemctl show restic-backups-{name}.service -p Result --value").strip()

    # The repository location is a credential like the rest, so it is provisioned at runtime and
    # appears nowhere in the units. Single source for both the blobs and this script's own
    # out-of-band restic calls. append-* are the append-only server, the others the normal one.
    REPOS = {
        "append-ignored": "rest:http://restic-backend:8001/append-ignored",
        "append-strict": "rest:http://restic-backend:8001/append-strict",
        "normal-strict": "rest:http://restic-backend:8002/normal-strict",
        "check-damaged": "rest:http://restic-backend:8002/check-damaged",
        "timer-rest": "rest:http://restic-backend:8002/timer-rest",
        "quiesce": "rest:http://restic-backend:8002/quiesce",
        "quiesce-shared": "rest:http://restic-backend:8001/quiesce-shared",
        "sandbox": "rest:http://restic-backend:8002/sandbox",
        "s3": "s3:http://restic-backend:3900/restic-s3",
    }

    def write_rest_credentials(name, backend_password="backend-secret", repository=None):
        client.succeed(f"mkdir -p /etc/credentials/restic/{name} /home/backup-user/{name}")
        client.succeed(f"printf '%s' '{repository or REPOS[name]}' | ${pkgs.systemd}/bin/systemd-creds encrypt --name=repository - /etc/credentials/restic/{name}/repository")
        client.succeed(f"printf '%s' 'repo-secret' | ${pkgs.systemd}/bin/systemd-creds encrypt --name=repository-password - /etc/credentials/restic/{name}/repository-password")
        client.succeed(f"printf '%s' 'test-user' | ${pkgs.systemd}/bin/systemd-creds encrypt --name=backend-username - /etc/credentials/restic/{name}/backend-username")
        client.succeed(f"printf '%s' '{backend_password}' | ${pkgs.systemd}/bin/systemd-creds encrypt --name=backend-password - /etc/credentials/restic/{name}/backend-password")
        client.succeed(f"chmod 0700 /etc/credentials/restic/{name}")
        client.succeed(f"chmod 0600 /etc/credentials/restic/{name}/repository /etc/credentials/restic/{name}/repository-password /etc/credentials/restic/{name}/backend-username /etc/credentials/restic/{name}/backend-password")
        client.succeed(f"chown -R backup-user:users /home/backup-user/{name}")

    def write_payload(name, content):
        client.succeed(f"runuser -u backup-user -- sh -c \"printf '%s\\n' '{content}' > /home/backup-user/{name}/payload.txt\"")

    client = by_hostname("restic-client")
    backend = by_hostname("restic-backend")

    # Plaintext repo password for the test's own manual restic invocations (every repo uses
    # 'repo-secret'); the on-disk creds are systemd-creds-encrypted blobs the services decrypt.
    client.succeed("printf %s repo-secret > /tmp/plain-repo-pw")

    def fire_timer(delay_s, margin=120):
        # A fresh Persistent OnCalendar=daily timer fires at the next LOCAL midnight
        # plus a machine-seeded offset in [0, RandomizedDelaySec]. Jump the clock
        # past (next local midnight + full delay), in the guest's own timezone, to
        # fire the real timer deterministically (re-roll-safe: any offset <= delay
        # is then in the past).
        slot = int(client.succeed("date -d 'tomorrow 00:00' +%s").strip())
        target = slot + delay_s + margin
        for node in [client, backend]:
            node.succeed(f"date -s @{target}")
        return target

    backend.wait_for_unit("restic-rest-server.socket")
    backend.wait_for_unit("restic-rest-normal.socket")
    backend.wait_for_unit("garage.service")
    backend.wait_for_open_port(8001)
    backend.wait_for_open_port(8002)
    backend.wait_for_open_port(3900)

    def garage_node_id():
        return backend.succeed("garage node id").split("@")[0]

    def garage_layout_version():
        output = backend.succeed("garage layout show")
        for line in output.splitlines():
            if line.startswith("Current cluster layout version:"):
                return int(line.rsplit(" ", 1)[1]) + 1
        raise Exception("could not determine Garage layout version")

    backend.succeed(f"garage layout assign -z qemutest -c 1G {garage_node_id()}")
    backend.succeed(f"garage layout apply --version {garage_layout_version()}")
    backend.succeed("garage bucket create restic-s3")
    s3_key_output = backend.succeed("garage key create restic-s3")
    s3_key_id = None
    s3_secret_key = None
    for line in s3_key_output.splitlines():
        if line.strip().startswith("Key ID:"):
            s3_key_id = line.split(":", 1)[1].strip()
        if line.strip().startswith("Secret key:"):
            s3_secret_key = line.split(":", 1)[1].strip()
    if s3_key_id is None or s3_secret_key is None:
        raise Exception(f"could not parse Garage key output: {s3_key_output}")
    backend.succeed("garage bucket allow --read --write restic-s3 --key restic-s3")

    # The store paths of a unit's ExecStart commands, in order.
    def exec_paths(unit, prop="ExecStart"):
        return re.findall(r"path=(\S+) ;", client.succeed(f"systemctl show {unit} -p {prop} --value"))

    def only_index(cmds, needle):
        matches = [i for i, cmd in enumerate(cmds) if needle in cmd]
        assert len(matches) == 1, f"expected exactly one {needle!r} in {cmds}"
        return matches[0]

    # Each backup is one unit, run as a dynamic user holding only CAP_DAC_READ_SEARCH. What restic
    # may touch is decided per run by the Landlock sandbox the wrapper starts it in, not by mounts.
    unit = "restic-backups-append-ignored.service"
    for line in ["User=restic-append-ignored", "DynamicUser=true", "AmbientCapabilities=CAP_DAC_READ_SEARCH", "CapabilityBoundingSet=CAP_DAC_READ_SEARCH", "PrivateUsers=false", "ProtectSystem=strict", "ProtectHome=read-only", "X-RestartIfChanged=false"]:
        client.succeed(f"systemctl cat {unit} | grep -Fx '{line}'")
    client.fail(f"systemctl cat {unit} | grep -E '^(RootDirectory|BindReadOnlyPaths|BindPaths|TemporaryFileSystem)='")
    client.succeed(f"systemctl cat {unit} | grep -F 'RestrictAddressFamilies=' | grep -F 'AF_INET' | grep -F 'AF_INET6'")
    client.fail(f"systemctl cat {unit} | grep -F 'RestrictAddressFamilies=' | grep -F 'AF_UNIX'")
    client.succeed(f"systemctl cat {unit} | grep -F 'RESTIC_PASSWORD_FILE=$CREDENTIALS_DIRECTORY/repository-password'")
    client.fail(f"systemctl cat {unit} | grep -F '/run/credentials/{unit}/repository-password'")
    client.succeed(f"systemctl cat {unit} | grep -F 'backup --group-by='")
    # Every restic run goes through the sandbox; only the backup itself in the backup phase.
    wrapper = next(p for p in exec_paths(unit) if p.endswith("/bin/restic-append-ignored"))
    # unlock is a pre-start step of its own (ordered below), not part of the backup command.
    client.fail(f"grep -F 'restic unlock' {wrapper}")
    client.succeed(f"grep -E '^ *exec .*restic-append-ignored-sandbox backup ${pkgs.restic}/bin/restic \"[$]@\"$' {wrapper}")
    client.succeed(f"grep -E '^ *exec .*restic-append-ignored-sandbox repository ${pkgs.restic}/bin/restic \"[$]@\"$' {wrapper}")
    for name in ["append-ignored", "normal-strict"]:
        maintenance = next(p for p in exec_paths(f"restic-backups-{name}.service") if p.endswith("-maintenance"))
        client.succeed(f"grep -F 'forget --prune --group-by=' {maintenance}")
        client.succeed(f"grep -E ' check$' {maintenance}")
    client.succeed("systemctl cat restic-backups-s3.service | grep -F 'LoadCredentialEncrypted=aws-access-key-id:/etc/credentials/restic/s3/aws-access-key-id'")
    client.succeed("systemctl cat restic-backups-s3.service | grep -F 'LoadCredentialEncrypted=aws-secret-access-key:/etc/credentials/restic/s3/aws-secret-access-key'")
    client.succeed("systemctl cat restic-backups-s3.service | grep -F -- '--exclude-file='")

    # --- the repository location is a credential, so it must appear nowhere in the unit ---
    for name in ["append-ignored", "s3"]:
        unit = f"restic-backups-{name}.service"
        client.succeed(f"systemctl cat {unit} | grep -F 'LoadCredentialEncrypted=repository:/etc/credentials/restic/{name}/repository'")
        client.succeed(f"systemctl cat {unit} | grep -F 'RESTIC_REPOSITORY_FILE=/run/credentials/{unit}/repository'")
        client.succeed(f"systemctl cat {unit} | grep -F 'ConditionPathExists=/etc/credentials/restic/{name}/repository'")
        # Upstream would render RESTIC_REPOSITORY= from the (now absent) option; the wrapper
        # points restic at the decrypted file instead, so the location never reaches the unit.
        client.fail(f"systemctl cat {unit} | grep -F 'RESTIC_REPOSITORY='")
        client.fail(f"systemctl cat {unit} | grep -E 'rest:|s3:'")
    # createWrapper=false: no restic-<name> on the system PATH baking the environment into a
    # world-readable store path.
    client.fail("command -v restic-append-ignored")
    client.succeed("systemctl show restic-backups-timer-rest.timer -p TimersCalendar --value | grep -F '*-*-* 00:00:00'")
    client.succeed("systemctl show restic-backups-timer-rest.timer -p Persistent --value | grep -F yes")
    client.succeed("systemctl show restic-backups-timer-rest.timer -p RandomizedDelayUSec --value | grep -F '1h'")
    client.succeed("systemctl cat restic-backups-timer-rest.timer | grep -Fx 'X-OnlyManualStart=true'")
    client.succeed("systemctl is-active --quiet restic-backups-timer-rest.timer")
    client.succeed("test -f /etc/credentials/restic/timer-rest/repository")
    client.succeed("test -f /etc/credentials/restic/timer-rest/repository-password")
    client.succeed("test -f /etc/credentials/restic/timer-rest/backend-username")
    client.succeed("test -f /etc/credentials/restic/timer-rest/backend-password")
    client.succeed("test -f /home/backup-user/timer-rest/payload.txt")

    # --- stopServices: unit shape and, above all, where the release sits in the sequence ---
    # The backup holds its units down through restic-hold-<name>, which requires one shared
    # restic-quiesce-<unit> per unit. "+" runs systemctl as root outside the sandbox, the only way
    # to reach systemd from this unit.
    client.succeed("systemctl cat restic-backups-quiesce.service | grep -E '^ExecStartPre=\\+.*/systemctl start restic-hold-quiesce[.]service$'")
    client.succeed("systemctl cat restic-backups-quiesce.service | grep -E '^ExecStart=\\+.*/systemctl stop restic-hold-quiesce[.]service$'")
    client.fail("systemctl cat restic-backups-quiesce.service | grep -F 'RestrictAddressFamilies=' | grep -F 'AF_UNIX'")
    def unit_list(unit, prop):
        return client.succeed(f"systemctl show {unit} -p {prop} --value").split()
    QUIESCED = ["quiesced-one", "quiesced-two", "quiesced-starting", "quiesced-crashing"]
    quiesce_units = [f"restic-quiesce-{u}.service" for u in QUIESCED]
    # BindsTo= releases the hold however the backup ends; not After= it, which would deadlock.
    assert unit_list("restic-hold-quiesce.service", "BindsTo") == ["restic-backups-quiesce.service"]
    assert "restic-backups-quiesce.service" not in unit_list("restic-hold-quiesce.service", "After")
    held = [u for u in unit_list("restic-hold-quiesce.service", "Requires") if u.startswith("restic-quiesce-")]
    assert sorted(held) == sorted(quiesce_units), held
    for u in quiesce_units:
        client.succeed(f"systemctl show {u} -p StopWhenUnneeded --value | grep -Fx yes")
    # "quiesced-two" without the suffix shares quiesced-two.service's quiesce unit.
    held = [u for u in unit_list("restic-hold-quiesce-shared.service", "Requires") if u.startswith("restic-quiesce-")]
    assert held == ["restic-quiesce-quiesced-two.service"], held
    # A backup without stopServices gets no hold at all.
    client.fail("systemctl cat restic-backups-normal-strict.service | grep -F 'restic-hold-'")
    client.fail("systemctl cat restic-hold-normal-strict.service")
    # Each unit is started again by restic-restart-<unit>, which retries a failed start every 15
    # minutes and is idle otherwise: no timer polls for work.
    for u in QUIESCED:
        assert unit_list(f"restic-restart-{u}.service", "Restart") == ["on-failure"]
        assert unit_list(f"restic-restart-{u}.service", "RestartUSec") == ["15min"]
        assert unit_list(f"restic-restart-{u}.service", "ActiveState") == ["inactive"]
    client.fail("systemctl cat restic-recover-quiesced.timer")

    # The release must come after the backup and before the check, so the units are not held down
    # through it.
    quiesce_cmds = client.succeed("systemctl show restic-backups-quiesce.service -p ExecStart --value").splitlines()
    assert only_index(quiesce_cmds, "/bin/restic-quiesce backup") < only_index(quiesce_cmds, "stop restic-hold-quiesce.service") < only_index(quiesce_cmds, "-maintenance"), quiesce_cmds
    # And the repository is opened, the backup's sandbox built and stale locks cleared before
    # anything is stopped.
    quiesce_pre = client.succeed("systemctl show restic-backups-quiesce.service -p ExecStartPre --value").splitlines()
    assert only_index(quiesce_pre, "-pre-start") < only_index(quiesce_pre, "-sandbox backup") < only_index(quiesce_pre, "/bin/restic-quiesce unlock") < only_index(quiesce_pre, "start restic-hold-quiesce.service"), quiesce_pre

    client.succeed("systemctl start restic-backups-append-ignored.service || true")
    client.fail("systemctl is-failed --quiet restic-backups-append-ignored.service")

    for name in ["append-ignored", "append-strict", "normal-strict", "check-damaged"]:
        write_rest_credentials(name)
        write_payload(name, f"{name} payload")

    # Fire the real restic-backups-timer-rest.timer (RandomizedDelaySec = 1h) by
    # jumping past its next occurrence. Its credentials are provisioned before the
    # service (ordering), so the timer-driven backup succeeds.
    fire_timer(3600)
    client.wait_until_succeeds("systemctl show restic-backups-timer-rest.service -p ActiveState --value | grep -F inactive && systemctl show restic-backups-timer-rest.service -p Result --value | grep -F success && journalctl -u restic-backups-timer-rest.service | grep -F 'snapshot '", timeout=120)
    assert service_result("timer-rest") == "success"
    client.succeed(f"RESTIC_REST_USERNAME=test-user RESTIC_REST_PASSWORD=backend-secret RESTIC_PASSWORD_FILE=/tmp/plain-repo-pw RESTIC_REPOSITORY={REPOS['timer-rest']} ${pkgs.restic}/bin/restic snapshots | grep -F timer-rest")
    client.succeed("systemctl stop restic-backups-timer-rest.timer")

    write_rest_credentials("normal-strict", "wrong-backend-secret")
    client.fail("systemctl start restic-backups-normal-strict.service")
    assert service_result("normal-strict") == "exit-code"
    write_rest_credentials("normal-strict")

    # A repository blob whose scheme disagrees with backend.type is caught by the wrapper's
    # guard, instead of failing later as an opaque "unable to open repository" (the rest
    # credentials would be loaded for an s3 repository).
    write_rest_credentials("normal-strict", repository=REPOS["s3"])
    client.fail("systemctl start restic-backups-normal-strict.service")
    assert service_result("normal-strict") == "exit-code"
    # Upstream's pre-start (repository init) is the first to open the repository, so the guard
    # fires there.
    client.succeed("journalctl -u restic-backups-normal-strict.service -n 30 | grep -F 'does not name a rest repository'")
    client.succeed("systemctl reset-failed restic-backups-normal-strict.service")
    write_rest_credentials("normal-strict")

    client.succeed("mkdir -p /etc/credentials/restic/s3 /home/backup-user/s3")
    client.succeed(f"printf '%s' '{REPOS['s3']}' | ${pkgs.systemd}/bin/systemd-creds encrypt --name=repository - /etc/credentials/restic/s3/repository")
    client.succeed("printf '%s' 'repo-secret' | ${pkgs.systemd}/bin/systemd-creds encrypt --name=repository-password - /etc/credentials/restic/s3/repository-password")
    client.succeed(f"printf '%s' '{s3_key_id}' | ${pkgs.systemd}/bin/systemd-creds encrypt --name=aws-access-key-id - /etc/credentials/restic/s3/aws-access-key-id")
    client.succeed(f"printf '%s' '{s3_secret_key}' | ${pkgs.systemd}/bin/systemd-creds encrypt --name=aws-secret-access-key - /etc/credentials/restic/s3/aws-secret-access-key")
    client.succeed("chmod 0700 /etc/credentials /etc/credentials/restic /etc/credentials/restic/s3")
    client.succeed("chmod 0600 /etc/credentials/restic/s3/repository /etc/credentials/restic/s3/repository-password /etc/credentials/restic/s3/aws-access-key-id /etc/credentials/restic/s3/aws-secret-access-key")
    client.succeed("chown -R backup-user:users /home/backup-user/s3")
    write_payload("s3", "s3 payload")
    client.succeed("runuser -u backup-user -- sh -c \"printf '%s\\n' 'excluded' > /home/backup-user/s3/excluded.txt\"")

    for name in ["append-ignored", "append-strict", "normal-strict", "check-damaged", "s3"]:
        client.succeed(f"systemctl start restic-backups-{name}.service")
        assert service_result(name) == "success"

    for name in ["append-ignored", "append-strict", "normal-strict"]:
        write_payload(name, f"{name} payload updated")
    write_payload("s3", "s3 payload updated")

    # Two snapshots against --keep-last 1: forget now has something to delete, and the append-only
    # server refuses it.
    client.succeed("systemctl start restic-backups-append-ignored.service")
    assert service_result("append-ignored") == "success"
    client.succeed("journalctl -b --no-pager -u restic-backups-append-ignored.service | grep -F 'ignored: prune.ignoreErrors'")
    checks = lambda unit: int(client.succeed(f"journalctl -b --no-pager -u {unit} | grep -c -F 'no errors were found' || true").strip())
    checked_before = checks("restic-backups-append-strict.service")
    client.fail("systemctl start restic-backups-append-strict.service")
    assert service_result("append-strict") == "exit-code"
    # The refusal fails the unit, but only after the check: the repository is verified anyway.
    client.wait_until_succeeds(f"test \"$(journalctl -b --no-pager -u restic-backups-append-strict.service | grep -c -F 'no errors were found')\" -gt {checked_before}", timeout=30)

    client.succeed("runuser -u backup-user -- dd if=/dev/urandom of=/home/backup-user/normal-strict/large.bin bs=1M count=64 status=none")
    client.succeed(f"RESTIC_REST_USERNAME=test-user RESTIC_REST_PASSWORD=backend-secret RESTIC_PASSWORD_FILE=/tmp/plain-repo-pw RESTIC_REPOSITORY={REPOS['normal-strict']} ${pkgs.restic}/bin/restic backup /home/backup-user/normal-strict >/tmp/create-stale-lock.log 2>&1 & printf '%s' $! > /tmp/create-stale-lock.pid")
    backend.wait_until_succeeds("set -- /var/lib/restic-normal/normal-strict/locks/*; test -e \"$1\"", timeout=10)
    client.succeed("kill -9 $(cat /tmp/create-stale-lock.pid) || true")
    backend.succeed("set -- /var/lib/restic-normal/normal-strict/locks/*; test -e \"$1\"")
    client.succeed("systemctl start restic-backups-normal-strict.service")
    assert service_result("normal-strict") == "success"
    backend.succeed("set -- /var/lib/restic-normal/normal-strict/locks/*; test ! -e \"$1\"")
    client.succeed("systemctl start restic-backups-s3.service")
    assert service_result("s3") == "success"

    # --- stopServices: the units are down for the backup phase and up again afterwards ---
    def quiesce_state(unit):
        return client.succeed(f"systemctl show restic-quiesce-{unit}.service -p ActiveState --value").strip()

    # The release is asynchronous: systemd stops a quiesce unit once nothing requires it, and that
    # stop is what starts the unit again. Settled once none is still up or on its way down.
    def released():
        retry(lambda _: all(quiesce_state(u) in ("inactive", "failed") for u in QUIESCED), 120)

    write_rest_credentials("quiesce")
    client.succeed("systemctl start quiesced-one.service quiesced-two.service")
    client.succeed("grep -F running /home/backup-user/quiesce/quiesced-one")

    client.succeed("systemctl start restic-backups-quiesce.service")
    assert service_result("quiesce") == "success"
    released()
    client.succeed("systemctl is-active --quiet quiesced-one.service")
    client.succeed("systemctl is-active --quiet quiesced-two.service")
    # Nothing is left held: the hold went with the backup, the quiesce units with the hold.
    assert unit_list("restic-hold-quiesce.service", "ActiveState") == ["inactive"]
    assert [quiesce_state(u) for u in QUIESCED] == ["inactive"] * len(QUIESCED), [quiesce_state(u) for u in QUIESCED]

    # The snapshot is what proves it: both units wrote "stopped" before restic read the files.
    client.succeed("mkdir -p /tmp/restic-quiesce-restore")
    client.succeed(f"RESTIC_REST_USERNAME=test-user RESTIC_REST_PASSWORD=backend-secret RESTIC_PASSWORD_FILE=/tmp/plain-repo-pw RESTIC_REPOSITORY={REPOS['quiesce']} ${pkgs.restic}/bin/restic restore latest --target /tmp/restic-quiesce-restore")
    client.succeed("grep -F stopped /tmp/restic-quiesce-restore/home/backup-user/quiesce/quiesced-one")
    client.succeed("grep -F stopped /tmp/restic-quiesce-restore/home/backup-user/quiesce/quiesced-two")

    # An unreachable repository fails in upstream's pre-start (repository init), before anything is
    # stopped: restic would otherwise retry it for ~15 minutes with the units down. The inactive-enter timestamp tells
    # whether a unit went down at all, whatever state it is back in.
    stamp = lambda unit: client.succeed(f"systemctl show {unit} -p InactiveEnterTimestampMonotonic --value").strip()
    stopped_before = stamp("quiesced-one.service")
    write_rest_credentials("quiesce", "wrong-backend-secret")
    client.fail("systemctl start restic-backups-quiesce.service")
    assert service_result("quiesce") == "exit-code"
    assert stamp("quiesced-one.service") == stopped_before, "units were stopped although the repository was unreachable"
    client.succeed("systemctl is-active --quiet quiesced-one.service")
    write_rest_credentials("quiesce")
    client.succeed("systemctl reset-failed restic-backups-quiesce.service")

    # A missing backup path fails the dry run of the backup's sandbox, before anything is stopped:
    # there is no bind mount any more to fail the unit as it starts.
    stopped_before = stamp("quiesced-one.service")
    client.succeed("mv /home/backup-user/quiesce /home/backup-user/quiesce.away")
    client.fail("systemctl start restic-backups-quiesce.service")
    assert service_result("quiesce") == "exit-code"
    client.succeed("journalctl -u restic-backups-quiesce.service -n 30 | grep -F 'could not open file for landlock: /home/backup-user/quiesce'")
    assert stamp("quiesced-one.service") == stopped_before, "units were stopped for a backup path that does not exist"
    client.succeed("mv /home/backup-user/quiesce.away /home/backup-user/quiesce")
    client.succeed("systemctl reset-failed restic-backups-quiesce.service")

    # A backup that fails after the units were stopped still brings them back: BindsTo= releases
    # its hold when it fails. The repository is broken after the pre-start opened it -- while the
    # quiesce unit of quiesced-starting waits for that to finish starting -- so restic backup fails
    # with the units already down. (An unreadable file would not do: CAP_DAC_READ_SEARCH reads it.)
    stopped_before = stamp("quiesced-one.service")
    client.succeed("touch /run/quiesce-hold")
    client.succeed("systemctl restart --no-block quiesced-starting.service")
    client.wait_until_succeeds("systemctl show quiesced-starting.service -p ActiveState --value | grep -Fqx activating")
    client.succeed("systemctl start --no-block restic-backups-quiesce.service")
    client.wait_until_succeeds("systemctl show restic-quiesce-quiesced-starting.service -p ActiveState --value | grep -Fqx activating")
    backend.succeed("mkdir /var/lib/restic-normal/quiesce/keys.bak && mv /var/lib/restic-normal/quiesce/keys/* /var/lib/restic-normal/quiesce/keys.bak/")
    client.succeed("rm /run/quiesce-hold")
    # A failed oneshot ends in "failed", not "inactive".
    client.wait_until_succeeds("systemctl show restic-backups-quiesce.service -p ActiveState --value | grep -Eqx 'inactive|failed'", timeout=300)
    assert service_result("quiesce") == "exit-code", service_result("quiesce")
    released()
    assert stamp("quiesced-one.service") != stopped_before, "quiesced-one was never stopped"
    for u in QUIESCED:
        client.succeed(f"systemctl is-active --quiet {u}.service")
    backend.succeed("mv /var/lib/restic-normal/quiesce/keys.bak/* /var/lib/restic-normal/quiesce/keys/ && rmdir /var/lib/restic-normal/quiesce/keys.bak")
    client.succeed("systemctl reset-failed restic-backups-quiesce.service")

    # A unit that was already stopped stays stopped.
    client.succeed("systemctl stop quiesced-two.service")
    client.succeed("systemctl start restic-backups-quiesce.service")
    assert service_result("quiesce") == "success"
    released()
    client.succeed("systemctl is-active --quiet quiesced-one.service")
    client.fail("systemctl is-active --quiet quiesced-two.service")
    client.succeed("systemctl start quiesced-two.service")

    # Runtime confirmation of the ExecStart ordering asserted above, on the last run: the hold is
    # released after the snapshot is saved and before the check, and quiesced-one starts again
    # after the release. Not necessarily before the check: the release only sets the start off.
    quiesce_log = client.succeed("journalctl -b --no-pager -u restic-backups-quiesce.service -u restic-hold-quiesce.service -u quiesced-one.service").splitlines()
    last = lambda match: max(i for i, line in enumerate(quiesce_log) if match(line))
    saved = last(lambda line: "snapshot " in line and " saved" in line)
    hold_released = last(lambda line: "Stopped restic backup quiesce reading its stopServices" in line)
    checked = last(lambda line: "no errors were found" in line)
    restarted = last(lambda line: "Finished" in line and "quiesced-one" in line)
    assert saved < hold_released < checked, quiesce_log[saved:checked + 1]
    assert hold_released < restarted, quiesce_log[hold_released:]

    # A unit still starting when the backup begins is waited for, then stopped like the rest. The
    # monitoring platform migrates its database before READY=1: a backup that took it for stopped
    # would read the files under the migration, one that stopped it would roll the migration back.
    client.succeed("systemctl stop quiesced-starting.service")
    client.succeed("truncate -s 0 /home/backup-user/quiesce/quiesced-starting")
    client.succeed("touch /run/quiesce-hold")
    client.succeed("systemctl start --no-block quiesced-starting.service")
    client.wait_until_succeeds("grep -Fqx starting /home/backup-user/quiesce/quiesced-starting")
    client.succeed("systemctl start --no-block restic-backups-quiesce.service")
    client.wait_until_succeeds("systemctl show restic-quiesce-quiesced-starting.service -p ActiveState --value | grep -Fqx activating")
    # Without the wait, the quiesce unit stops it at once and restic is backing up within a second.
    # With it, nothing moves until the start finishes, so the margin cannot make this flaky.
    client.sleep(5)
    assert client.succeed("systemctl show restic-backups-quiesce.service -p SubState --value").strip() == "start-pre"
    assert client.succeed("systemctl show quiesced-starting.service -p ActiveState --value").strip() == "activating"

    client.succeed("rm /run/quiesce-hold")
    client.wait_until_succeeds("systemctl show restic-backups-quiesce.service -p ActiveState --value | grep -Fqx inactive")
    assert service_result("quiesce") == "success"
    released()
    client.succeed("systemctl is-active --quiet quiesced-starting.service")
    client.succeed("mkdir -p /tmp/restic-quiesce-starting-restore")
    client.succeed(f"RESTIC_REST_USERNAME=test-user RESTIC_REST_PASSWORD=backend-secret RESTIC_PASSWORD_FILE=/tmp/plain-repo-pw RESTIC_REPOSITORY={REPOS['quiesce']} ${pkgs.restic}/bin/restic restore latest --target /tmp/restic-quiesce-starting-restore")
    snapshotted = client.succeed("cat /tmp/restic-quiesce-starting-restore/home/backup-user/quiesce/quiesced-starting").split()
    assert snapshotted == ["starting", "running", "stopped"], snapshotted

    # A restart under way when the backup begins is let finish too, then the unit is stopped.
    # Taking the unit for stopped while it is deactivating would let the restart's start half bring
    # it up under restic; stopping it at once would cancel the restart, failing whoever asked for it.
    client.succeed("truncate -s 0 /home/backup-user/quiesce/quiesced-starting")
    client.succeed("touch /run/quiesce-stop-hold")
    client.succeed("(systemctl restart quiesced-starting.service; echo $? > /tmp/quiesce-restart-rc) > /dev/null 2>&1 &")
    client.wait_until_succeeds("systemctl show quiesced-starting.service -p ActiveState --value | grep -Fqx deactivating")
    client.succeed("systemctl start --no-block restic-backups-quiesce.service")
    client.wait_until_succeeds("systemctl show restic-quiesce-quiesced-starting.service -p ActiveState --value | grep -Fqx activating")
    client.sleep(5)
    assert client.succeed("systemctl show restic-backups-quiesce.service -p SubState --value").strip() == "start-pre"
    assert client.succeed("systemctl show quiesced-starting.service -p ActiveState --value").strip() == "deactivating"

    client.succeed("rm /run/quiesce-stop-hold")
    client.wait_until_succeeds("systemctl show restic-backups-quiesce.service -p ActiveState --value | grep -Fqx inactive")
    assert service_result("quiesce") == "success"
    released()
    assert client.succeed("cat /tmp/quiesce-restart-rc").strip() == "0", "the restart was cancelled"
    client.succeed("systemctl is-active --quiet quiesced-starting.service")
    client.succeed("mkdir -p /tmp/restic-quiesce-restart-restore")
    client.succeed(f"RESTIC_REST_USERNAME=test-user RESTIC_REST_PASSWORD=backend-secret RESTIC_PASSWORD_FILE=/tmp/plain-repo-pw RESTIC_REPOSITORY={REPOS['quiesce']} ${pkgs.restic}/bin/restic restore latest --target /tmp/restic-quiesce-restart-restore")
    snapshotted = client.succeed("cat /tmp/restic-quiesce-restart-restore/home/backup-user/quiesce/quiesced-starting").split()
    assert snapshotted == ["stopped", "starting", "running", "stopped"], snapshotted

    # --- two backups sharing a unit: one downtime, started again after the last reader ---
    # quiesce holds quiesced-two while its restic is stalled on a frozen server; quiesce-shared, on
    # the other server, reads the same files meanwhile and releases its own hold. quiesced-two must
    # stay down for the stalled backup and come back once that is done too. The server is frozen
    # while quiesce's quiesce units wait on quiesced-starting: after its repository was opened,
    # before restic backup talks to it.
    write_rest_credentials("quiesce-shared")
    client.succeed("touch /run/quiesce-hold")
    client.succeed("systemctl restart --no-block quiesced-starting.service")
    client.wait_until_succeeds("systemctl show quiesced-starting.service -p ActiveState --value | grep -Fqx activating")
    client.succeed("systemctl start --no-block restic-backups-quiesce.service")
    client.wait_until_succeeds("systemctl show restic-quiesce-quiesced-starting.service -p ActiveState --value | grep -Fqx activating")
    backend.succeed("systemctl kill --signal=SIGSTOP restic-rest-normal.service")
    client.succeed("rm /run/quiesce-hold")
    client.wait_until_succeeds("systemctl show restic-hold-quiesce.service -p ActiveState --value | grep -Fqx active")
    client.fail("systemctl is-active --quiet quiesced-two.service")

    client.succeed("systemctl start restic-backups-quiesce-shared.service")
    assert service_result("quiesce-shared") == "success"
    assert client.succeed("systemctl show restic-backups-quiesce.service -p ActiveState --value").strip() == "activating"
    # quiesce-shared released its hold before its check, seconds ago: had that started quiesced-two
    # again, it would be running by now.
    assert quiesce_state("quiesced-two") == "active", quiesce_state("quiesced-two")
    client.fail("systemctl is-active --quiet quiesced-two.service")
    client.succeed("mkdir -p /tmp/restic-quiesce-shared-restore")
    client.succeed(f"RESTIC_PASSWORD_FILE=/tmp/plain-repo-pw RESTIC_REPOSITORY={REPOS['quiesce-shared']} ${pkgs.restic}/bin/restic restore latest --target /tmp/restic-quiesce-shared-restore")
    client.succeed("grep -Fx stopped /tmp/restic-quiesce-shared-restore/home/backup-user/quiesce/quiesced-two")

    backend.succeed("systemctl kill --signal=SIGCONT restic-rest-normal.service")
    client.wait_until_succeeds("systemctl show restic-backups-quiesce.service -p ActiveState --value | grep -Eqx 'inactive|failed'", timeout=300)
    assert service_result("quiesce") == "success", service_result("quiesce")
    released()
    for u in QUIESCED:
        client.succeed(f"systemctl is-active --quiet {u}.service")

    # --- a unit crash-looping when the backup begins ---
    # Waiting out RestartSec it is "activating", with nothing under way: it is stopped, which cancels
    # the pending restart, and started after the backup. The backup phase is stalled on a frozen
    # server, as above, for several RestartSec, and the start is made to succeed meanwhile: a
    # restart nobody cancelled would bring the unit up under restic.
    client.succeed("touch /run/quiesce-fail-quiesced-crashing")
    client.succeed("systemctl restart --no-block quiesced-crashing.service")
    client.wait_until_succeeds("systemctl show quiesced-crashing.service -p SubState --value | grep -q '^auto-restart'")
    client.succeed("touch /run/quiesce-hold")
    client.succeed("systemctl restart --no-block quiesced-starting.service")
    client.wait_until_succeeds("systemctl show quiesced-starting.service -p ActiveState --value | grep -Fqx activating")
    client.succeed("systemctl start --no-block restic-backups-quiesce.service")
    client.wait_until_succeeds("systemctl show restic-quiesce-quiesced-starting.service -p ActiveState --value | grep -Fqx activating")
    backend.succeed("systemctl kill --signal=SIGSTOP restic-rest-normal.service")
    client.succeed("rm /run/quiesce-hold")
    client.wait_until_succeeds("systemctl show restic-hold-quiesce.service -p ActiveState --value | grep -Fqx active")
    client.succeed("rm /run/quiesce-fail-quiesced-crashing")
    client.sleep(6)
    # "failed" when the automatic restart came due between the quiesce unit's look and its stop: the
    # stop then lands on a start under way, which fails, and a stop job leaves a failure as "failed".
    crashing = client.succeed("systemctl show quiesced-crashing.service -p ActiveState --value").strip()
    assert crashing in ("inactive", "failed"), crashing
    assert client.succeed("systemctl show restic-backups-quiesce.service -p ActiveState --value").strip() == "activating"

    backend.succeed("systemctl kill --signal=SIGCONT restic-rest-normal.service")
    client.wait_until_succeeds("systemctl show restic-backups-quiesce.service -p ActiveState --value | grep -Eqx 'inactive|failed'", timeout=300)
    assert service_result("quiesce") == "success", service_result("quiesce")
    released()
    for u in QUIESCED:
        client.succeed(f"systemctl is-active --quiet {u}.service")

    # --- a start that fails after the backup ---
    # restic-restart-<unit> owns it: the quiesce unit is done, and the start is retried every 15
    # minutes. `restart` rather than `start` below: a start would wait the 15 minutes out.
    def restart_state(unit):
        return client.succeed(f"systemctl show restic-restart-{unit}.service -p ActiveState --value").strip()

    def failed_start():
        client.succeed("touch /run/quiesce-fail-quiesced-one")
        client.succeed("systemctl start restic-backups-quiesce.service")
        assert service_result("quiesce") == "success"
        released()
        assert quiesce_state("quiesced-one") == "inactive", quiesce_state("quiesced-one")
        client.succeed("systemctl is-failed --quiet quiesced-one.service")
        # Waiting out RestartSec.
        assert restart_state("quiesced-one") == "activating", restart_state("quiesced-one")

    failed_start()
    client.fail("systemctl restart restic-restart-quiesced-one.service")
    assert restart_state("quiesced-one") == "activating", restart_state("quiesced-one")
    client.succeed("rm /run/quiesce-fail-quiesced-one")
    client.succeed("systemctl restart restic-restart-quiesced-one.service")
    client.succeed("systemctl is-active --quiet quiesced-one.service")
    assert restart_state("quiesced-one") == "inactive", restart_state("quiesced-one")

    # The next backup of the unit takes a pending retry over and starts the unit after itself. The
    # unit is failed by then, which by itself would not get it started.
    failed_start()
    client.succeed("rm /run/quiesce-fail-quiesced-one")
    client.succeed("systemctl start restic-backups-quiesce.service")
    assert service_result("quiesce") == "success"
    released()
    client.succeed("systemctl is-active --quiet quiesced-one.service")
    assert restart_state("quiesced-one") == "inactive", restart_state("quiesced-one")

    # Stopping the retry gives up on it. What is left is a unit failed for whatever reason, and a
    # backup leaves that alone: it is not the unit's supervisor.
    failed_start()
    client.succeed("systemctl stop restic-restart-quiesced-one.service")
    client.succeed("rm /run/quiesce-fail-quiesced-one")
    client.succeed("systemctl start restic-backups-quiesce.service")
    assert service_result("quiesce") == "success"
    released()
    client.succeed("systemctl is-failed --quiet quiesced-one.service")
    assert restart_state("quiesced-one") == "inactive", restart_state("quiesced-one")
    client.succeed("systemctl reset-failed quiesced-one.service")
    client.succeed("systemctl start quiesced-one.service")
    for u in QUIESCED:
        client.succeed(f"systemctl is-active --quiet {u}.service")

    backend.succeed("set -- /var/lib/restic-normal/check-damaged/data/*/*; rm \"$1\"")
    client.fail("systemctl start restic-backups-check-damaged.service")
    assert service_result("check-damaged") == "exit-code"
    client.succeed("journalctl -u restic-backups-check-damaged.service -n 80 | grep -E 'check|Fatal|not found|repository contains errors|does not exist'")

    backend.succeed("test -d /var/lib/restic-append/append-ignored/data")
    backend.succeed("test -d /var/lib/restic-normal/normal-strict/data")

    client.succeed(f"AWS_ACCESS_KEY_ID={s3_key_id} AWS_SECRET_ACCESS_KEY={s3_secret_key} RESTIC_PASSWORD_FILE=/tmp/plain-repo-pw RESTIC_REPOSITORY={REPOS['s3']} ${pkgs.restic}/bin/restic snapshots")
    client.succeed("mkdir -p /tmp/restic-restore")
    client.succeed(f"AWS_ACCESS_KEY_ID={s3_key_id} AWS_SECRET_ACCESS_KEY={s3_secret_key} RESTIC_PASSWORD_FILE=/tmp/plain-repo-pw RESTIC_REPOSITORY={REPOS['s3']} ${pkgs.restic}/bin/restic restore latest --target /tmp/restic-restore")
    client.succeed("grep -F 's3 payload updated' /tmp/restic-restore/home/backup-user/s3/payload.txt")
    client.fail("test -e /tmp/restic-restore/home/backup-user/s3/excluded.txt")

    # --- the sandbox, from the inside: each phase's probe fails the unit on a breach ---
    write_rest_credentials("sandbox")
    write_payload("sandbox", "sandbox payload")
    client.succeed("install -m 0600 -o root -g root /dev/null /home/backup-user/sandbox/root-only")
    client.succeed("install -d -m 0755 /var/lib/sandbox-outside && echo visible > /var/lib/sandbox-outside/world-readable && chmod 0644 /var/lib/sandbox-outside/world-readable")
    client.succeed("echo secret > /root/sandbox-outside")
    client.succeed("install -d -m 0755 /var/lib/sandbox-inside && echo inside > /var/lib/sandbox-inside/world-readable && chmod 0644 /var/lib/sandbox-inside/world-readable")
    rc, _ = client.execute("systemctl start restic-backups-sandbox.service")
    probe_log = client.succeed("journalctl -b --no-pager -o cat -u restic-backups-sandbox.service | grep -F 'sandbox probe' || true")
    assert rc == 0 and service_result("sandbox") == "success", probe_log
    for phase in ["repository", "backup"]:
        assert f"sandbox probe ({phase}): ok" in probe_log, probe_log
    # The root-only file was read: it is in the snapshot.
    sandbox_env = f"RESTIC_REST_USERNAME=test-user RESTIC_REST_PASSWORD=backend-secret RESTIC_PASSWORD_FILE=/tmp/plain-repo-pw RESTIC_REPOSITORY={REPOS['sandbox']}"
    client.succeed(f"{sandbox_env} ${pkgs.restic}/bin/restic ls latest | grep -Fx /home/backup-user/sandbox/root-only")

    # --- TLS through the system CA store, test CA included ---
    backend.wait_for_open_port(8003)
    # The nodes boot at nixpkgs' date, before the test CA was minted at build time: move both past
    # the certificates' notBefore (Go checks the root's dates as well as the leaf's).
    not_before = max(int(client.succeed(f"date -d \"$(${pkgs.openssl}/bin/openssl x509 -in {cert} -noout -startdate | cut -d= -f2)\" +%s").strip()) for cert in ["${tlsCert.caFile}", "${tlsCert.certFile}"])
    if int(client.succeed("date +%s").strip()) < not_before + 60:
        for node in [client, backend]:
            node.succeed(f"date -s @{not_before + 3600}")
    tls_repo = "rest:https://restic-backend:8003/tls"
    write_rest_credentials("tls", repository=tls_repo)
    write_payload("tls", "tls payload")
    client.succeed("systemctl start restic-backups-tls.service")
    assert service_result("tls") == "success"
    # The unit trusts exactly the bundle /etc/ssl/certs points at.
    bundle = client.succeed("readlink -f /etc/ssl/certs/ca-certificates.crt").strip()
    client.succeed(f"systemctl show restic-backups-tls.service -p Environment --value | tr ' ' '\\n' | grep -Fx SSL_CERT_FILE={bundle}")
    tls_env = f"RESTIC_REST_USERNAME=test-user RESTIC_REST_PASSWORD=backend-secret RESTIC_PASSWORD_FILE=/tmp/plain-repo-pw RESTIC_REPOSITORY={tls_repo}"
    client.succeed(f"{tls_env} ${pkgs.restic}/bin/restic snapshots | grep -F /home/backup-user/tls")
    # Control: the stock nixpkgs bundle lacks the test CA, so it is the system store that made the
    # backup work. SSL_CERT_DIR too, as Go also loads every file under /etc/ssl/certs. restic retries
    # the failure for ~15 minutes, so cut it short and read what it logged (not piped into grep -m1:
    # the test shell runs with pipefail, and restic dies of SIGPIPE).
    client.succeed(f"{tls_env} SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt SSL_CERT_DIR=/var/empty timeout 30 ${pkgs.restic}/bin/restic snapshots > /tmp/tls-control.log 2>&1 || true")
    client.succeed("grep -F 'certificate signed by unknown authority' /tmp/tls-control.log")
  '';
}
