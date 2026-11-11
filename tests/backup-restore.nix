{ nixpkgs, pkgs, machineModule, stateVersion }:

# Disaster recovery on the REAL Raspberry Pi 5 config (hosts/rpi5): the borgbase backup of the
# receiver (monitoring-platform), pw-mgr and media-store, restored into a host whose state is gone.
#
# tests/monitoring/rpi.nix proves the backup *runs* on the deployed config (timer, credentials,
# the services held down while restic reads them, the append-only prune) but never reads a
# snapshot back. This one does: data goes in through each app's own API, the Pi's backup runs,
# more data goes in after it as a control, the three state directories are deleted, and a
# `restic restore` brings them back. Then each app is asked, through its API again, for what it
# holds: everything from before the backup, byte for byte, and nothing from after it.
#
# The only test-only parts are the backup's target -- an append-only rest-server on loopback,
# reached by provisioning the deployed credential directory with a blob that names it, as
# tests/monitoring/rpi.nix does -- and the restore, run the way an operator would after losing
# the SD card: with the repository location and passwords in hand, not with the Pi's
# host-key-encrypted blobs, which go down with the card.
#
# Not covered, on purpose: media-store's tracks. hosts/rpi5 sends offloadable blobs to S3 alone,
# so they are not in this backup at all; what restic carries is the library's database (users,
# refs and the blobs refs point to), which is what is seeded here.

let
  inherit (nixpkgs) lib;

  # What the operator keeps off the Pi to restore with.
  repository = "rest:http://127.0.0.1:8000/borgbase";
  repositoryPassword = "repo-secret";
  backendUser = "test-user";
  backendPassword = "backend-secret";
in
nixpkgs.lib.nixos.runTest {
  name = "backup-restore";
  hostPkgs = pkgs;
  # Ceiling, not a wait: the aarch64 variant runs under TCG on the KVM-less CI runner.
  globalTimeout = 1800;

  nodes.machine = { config, lib, pkgs, ... }:
    let
      credentials = config.common.restic.backups.borgbase.credentialDirectory;
      creds = "${pkgs.systemd}/bin/systemd-creds";
    in
    {
      imports = [ machineModule ];

      networking.hostName = "backup-restore";
      virtualisation.memorySize = lib.mkDefault 2048;
      # media-store keeps 2 GiB free on the database's file system (hosts/rpi5), and refuses a
      # write into it with 507 otherwise: the default 1 GiB disk could not take a single blob.
      virtualisation.diskSize = 4096;

      # Stand-in for the deployed backend, append-only like it: restore must work against the
      # repository as the Pi's backup leaves it, with nothing it was refused to delete cleaned up.
      systemd.services.test-restic-rest-server = {
        description = "Append-only restic REST server (test stand-in for BorgBase)";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        serviceConfig.StateDirectory = "test-restic-rest-server";
        script = ''
          ${pkgs.apacheHttpd}/bin/htpasswd -Bbc /var/lib/test-restic-rest-server/.htpasswd \
            ${backendUser} ${backendPassword}
          exec ${pkgs.restic-rest-server}/bin/rest-server --append-only \
            --listen 127.0.0.1:8000 --path /var/lib/test-restic-rest-server
        '';
      };

      # The out-of-band provisioning hosts/rpi5 documents, into the directory it names. At boot,
      # not at build time: the blobs are bound to the host key, which only exists on the guest.
      systemd.services.test-backup-credentials = {
        description = "Provision the borgbase backup's credentials (test only)";
        wantedBy = [ "multi-user.target" ];
        before = [ "restic-backups-borgbase.service" ];
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
        script = ''
          install -d -m 0700 ${credentials}
          printf '%s' '${repository}'         | ${creds} encrypt --name=repository - ${credentials}/repository
          printf '%s' '${repositoryPassword}' | ${creds} encrypt --name=repository-password - ${credentials}/repository-password
          printf '%s' '${backendUser}'        | ${creds} encrypt --name=backend-username - ${credentials}/backend-username
          printf '%s' '${backendPassword}'    | ${creds} encrypt --name=backend-password - ${credentials}/backend-password
          chmod 0600 ${credentials}/*
        '';
      };

      system.stateVersion = stateVersion;
    };

  testScript = { nodes, ... }:
    let
      node = nodes.machine;
      mp = node.services.monitoring-platform;
      units = [ "monitoring-platform" "pw-mgr" "media-store" ];
      # Each app's state as its unit declares it, so the wipe below does not depend on what the
      # backup claims to cover: a directory the backup missed stays gone, and the test fails.
      stateDir = unit: "/var/lib/${node.systemd.services.${unit}.serviceConfig.StateDirectory}";
      unitUser = unit: node.systemd.services.${unit}.serviceConfig.User;
    in
    ''
    import json
    import re

    UNITS = ${builtins.toJSON (map (u: "${u}.service") units)}
    # State directory -> the user that must own everything in it.
    STATE = ${builtins.toJSON (lib.listToAttrs (map (u: lib.nameValuePair (stateDir u) (unitUser u)) units))}

    MP_SOCKET = "${mp.socketPath}"
    MP_DB = "${mp.databasePath}"
    MP_USER = "${mp.user}"

    # The two e2ee-store apps; their options name the socket, the CLI is named after the app.
    APPS = {
        "pw-mgr": "${node.services.pw-mgr.socketPath}",
        "media-store": "${node.services.media-store.socketPath}",
    }

    RESTIC = (
        "RESTIC_REPOSITORY='${repository}' RESTIC_PASSWORD='${repositoryPassword}' "
        "RESTIC_REST_USERNAME='${backendUser}' RESTIC_REST_PASSWORD='${backendPassword}' "
        "${pkgs.restic}/bin/restic --no-cache"
    )
    SQLITE = "${pkgs.sqlite}/bin/sqlite3"


    def wait_until_serving():
        for unit in UNITS:
            machine.wait_for_unit(unit)
        # e2ee-store backends are Type=simple: active before the socket is bound.
        for socket in [MP_SOCKET, *APPS.values()]:
            machine.wait_until_succeeds(f"curl -sf --unix-socket {socket} http://localhost/healthz")


    # --- monitoring-platform: API keys and measurements, through the receiver's own API -----

    def mp_issue_key(label):
        # As the service user, so SQLite's -wal/-shm stay the receiver's (lib/test-mp-auth.nix).
        token = machine.succeed(
            f"runuser -u {MP_USER} -- monitoring-platform create-api-key "
            f"--db {MP_DB} --label {label} 2>/dev/null"
        ).strip()
        assert token.startswith("mpk_"), token
        return token


    def mp_curl(key, args):
        return machine.succeed(
            f"curl -sS --fail-with-body -H 'Authorization: Bearer {key}' "
            f"--unix-socket {MP_SOCKET} {args}"
        )


    def mp_post_sample(key, device):
        # mp-make-sample: three measurements stamped with this device.id, built by the
        # receiver's own package.
        machine.succeed(f"mp-make-sample --device-id {device} /tmp/{device}.pb")
        mp_curl(
            key,
            "-X POST -H 'Content-Type: application/x-protobuf' "
            f"--data-binary @/tmp/{device}.pb http://localhost/v1/logs",
        )


    def mp_ids(key, device):
        body = mp_curl(
            key,
            f"'http://localhost/v1/measurements?attr.resource.attributes.device.id={device}&limit=1000'",
        )
        return sorted(m["id"] for m in json.loads(body)["measurements"])


    def mp_status(key):
        return machine.succeed(
            f"curl -s -o /dev/null -w '%{{http_code}}' -H 'Authorization: Bearer {key}' "
            f"--unix-socket {MP_SOCKET} 'http://localhost/v1/measurements?limit=1'"
        )


    # --- pw-mgr and media-store: users through the admin CLI, blobs and refs through the API --

    def api(app, args):
        return machine.succeed(
            f"curl -sS --fail-with-body --unix-socket {APPS[app]} -H 'Origin: http://localhost' "
            f"-b /tmp/{app}.jar -c /tmp/{app}.jar {args}"
        )


    def log_in(app, user):
        # A setup token from the admin CLI, exchanged for a session: no passkey needed.
        link = re.search(r"#setup=(\S+)", machine.succeed(f"{app} setup-token create {user}"))
        assert link, f"{app} printed no setup link"
        machine.succeed(f"rm -f /tmp/{app}.jar")
        api(
            app,
            f"-H 'Content-Type: application/json' -d '{{\"token\": \"{link.group(1)}\"}}' "
            "http://localhost/api/v1/auth/setup-token",
        )


    def put_blob_and_ref(app, path):
        # Not offloadable, the default: it stays in the database, which is what restic carries.
        machine.succeed(f"head -c 100000 /dev/urandom > {path}")
        blob = machine.succeed(f"sha256sum {path}").split()[0]
        api(
            app,
            "-X PUT -H 'Content-Type: application/octet-stream' "
            f"--data-binary @{path} http://localhost/api/v1/blobs/{blob}",
        )
        api(
            app,
            f"-X PUT -H 'Content-Type: application/json' -d '{{\"blob\": \"{blob}\"}}' "
            "http://localhost/api/v1/refs/head",
        )
        return blob


    def listing(app):
        # Timestamps included: a restored row has to be the same row, not a lookalike.
        return (
            json.loads(api(app, "http://localhost/api/v1/blobs")),
            json.loads(api(app, "http://localhost/api/v1/refs")),
        )


    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("test-backup-credentials.service")
    machine.wait_for_unit("test-restic-rest-server.service")
    machine.wait_for_open_port(8000, "127.0.0.1")
    wait_until_serving()

    with subtest("data goes into all three"):
        mp_key = mp_issue_key("before-backup")
        mp_post_sample(mp_key, "before-backup")
        mp_kept = mp_ids(mp_key, "before-backup")
        assert len(mp_kept) == 3, mp_kept
        kept = {}
        for app in APPS:
            machine.succeed(f"{app} user create alice")
            log_in(app, "alice")
            blob = put_blob_and_ref(app, f"/tmp/{app}-kept")
            blobs, refs = listing(app)
            assert [b["id"] for b in blobs["blobs"]] == [blob], blobs
            assert [(r["name"], r["blob"]) for r in refs["refs"]] == [("head", blob)], refs
            kept[app] = (blob, (blobs, refs))

    with subtest("the Pi's backup runs"):
        # By hand: its schedule is tests/monitoring/rpi.nix's subject. Type=oneshot, so this
        # returns when the backup, retention and check are done.
        machine.succeed("systemctl start restic-backups-borgbase.service")
        # A missing credential makes ConditionPathExists skip the unit, and a skipped start
        # still exits 0.
        ran = machine.succeed("systemctl show restic-backups-borgbase.service -p ConditionResult --value")
        assert ran.strip() == "yes", "the backup was skipped"
        snapshots = json.loads(machine.succeed(f"{RESTIC} snapshots --json"))
        assert len(snapshots) == 1, snapshots
        # The backup stopped all three to read them, and started them again.
        wait_until_serving()

    with subtest("more data after the backup, which the restore must not bring back"):
        mp_post_sample(mp_key, "after-backup")
        assert len(mp_ids(mp_key, "after-backup")) == 3
        mp_later_key = mp_issue_key("after-backup")
        assert mp_status(mp_later_key) == "200"
        for app in APPS:
            machine.succeed(f"{app} user create bob")
            log_in(app, "alice")
            put_blob_and_ref(app, f"/tmp/{app}-lost")

    with subtest("the state is lost"):
        machine.succeed("systemctl stop " + " ".join(UNITS))
        for state in STATE:
            machine.succeed(f"rm -rf {state}")
            machine.fail(f"test -e {state}")

    with subtest("restored from the repository"):
        machine.succeed(f"{RESTIC} restore latest --target /")
        for state, user in STATE.items():
            foreign = machine.succeed(f"find {state} ! -user {user}").strip()
            assert foreign == "", f"files in {state} not owned by {user}:\n{foreign}"
        machine.succeed("systemctl start " + " ".join(UNITS))
        wait_until_serving()

    with subtest("monitoring-platform: the measurements and keys from before, nothing after"):
        assert mp_ids(mp_key, "before-backup") == mp_kept
        assert mp_ids(mp_key, "after-backup") == []
        assert mp_status(mp_later_key) == "401", "a key issued after the backup still works"
        machine.succeed(
            f"runuser -u {MP_USER} -- {SQLITE} 'file:{MP_DB}?mode=ro' 'pragma integrity_check' | grep -Fx ok"
        )

    for app in APPS:
        with subtest(f"{app}: the user, blob and ref from before, nothing after"):
            users = machine.succeed(f"{app} user list")
            assert "alice" in users and "bob" not in users, users
            log_in(app, "alice")
            blob, before = kept[app]
            assert listing(app) == before, (listing(app), before)
            api(app, f"-o /tmp/{app}-back http://localhost/api/v1/blobs/{blob}")
            machine.succeed(f"cmp /tmp/{app}-kept /tmp/{app}-back")
            machine.succeed(
                f"runuser -u {app} -- {SQLITE} 'file:/var/lib/{app}/backend.sqlite3?mode=ro' "
                "'pragma integrity_check' | grep -Fx ok"
            )
    '';
}
