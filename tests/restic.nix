{ nixpkgs, pkgs, commonDesktopModule, stateVersion }:

let
  resticLib = import ../lib/restic.nix { lib = nixpkgs.lib; };

  pruneOpts = [ "--keep-last 1" ];
in
nixpkgs.lib.nixos.runTest {
  name = "restic";
  hostPkgs = pkgs;
  skipTypeCheck = true;

  nodes.client = { ... }: {
    imports = [ commonDesktopModule ];

    networking.hostName = "restic-client";
    system.stateVersion = stateVersion;

    users.users.backup-user = {
      isNormalUser = true;
      home = "/home/backup-user";
    };

    common.restic.backups.append-ignored = resticLib.rest {
      user = "backup-user";
      credentialDirectory = "/etc/credentials/restic/append-ignored";
      url = "http://restic-backend:8001";
      repository = "append-ignored";
      paths = [ "/home/backup-user/append-ignored" ];
      prune = {
        ignoreErrors = true;
        opts = pruneOpts;
      };
      timerConfig = null;
    };

    common.restic.backups.append-strict = resticLib.rest {
      user = "backup-user";
      credentialDirectory = "/etc/credentials/restic/append-strict";
      url = "http://restic-backend:8001";
      repository = "append-strict";
      paths = [ "/home/backup-user/append-strict" ];
      prune = {
        ignoreErrors = false;
        opts = pruneOpts;
      };
      timerConfig = null;
    };

    common.restic.backups.normal-strict = resticLib.rest {
      user = "backup-user";
      credentialDirectory = "/etc/credentials/restic/normal-strict";
      url = "http://restic-backend:8002";
      repository = "normal-strict";
      paths = [ "/home/backup-user/normal-strict" ];
      prune = {
        ignoreErrors = false;
        opts = pruneOpts;
      };
      timerConfig = null;
    };

    common.restic.backups.check-damaged = resticLib.rest {
      user = "backup-user";
      credentialDirectory = "/etc/credentials/restic/check-damaged";
      url = "http://restic-backend:8002";
      repository = "check-damaged";
      paths = [ "/home/backup-user/check-damaged" ];
      prune.opts = [ "--keep-last 99" ];
      timerConfig = null;
    };

    common.restic.backups.s3 = resticLib.s3 {
      user = "backup-user";
      credentialDirectory = "/etc/credentials/restic/s3";
      endpoint = "http://restic-backend:3900";
      bucket = "restic-s3";
      paths = [ "/home/backup-user/s3" ];
      exclude = [ "excluded.txt" ];
      timerConfig = null;
    };
  };

  nodes.backend = { pkgs, ... }: {
    networking = {
      firewall.allowedTCPPorts = [ 3900 8001 8002 ];
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

    systemd.tmpfiles.rules = [
      "d /var/lib/restic-normal 0750 restic restic -"
    ];

    virtualisation.diskSize = 3 * 1024;
    system.stateVersion = stateVersion;
  };

  testScript = ''
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

    def write_rest_credentials(name, backend_password="backend-secret"):
        client.succeed(f"mkdir -p /etc/credentials/restic/{name} /home/backup-user/{name}")
        client.succeed(f"printf '%s' 'repo-secret' > /etc/credentials/restic/{name}/repository-password")
        client.succeed(f"printf '%s' 'test-user' > /etc/credentials/restic/{name}/backend-username")
        client.succeed(f"printf '%s' '{backend_password}' > /etc/credentials/restic/{name}/backend-password")
        client.succeed(f"chmod 0700 /etc/credentials/restic/{name}")
        client.succeed(f"chmod 0600 /etc/credentials/restic/{name}/repository-password /etc/credentials/restic/{name}/backend-username /etc/credentials/restic/{name}/backend-password")
        client.succeed(f"chown -R backup-user:users /home/backup-user/{name}")

    def write_payload(name, content):
        client.succeed(f"runuser -u backup-user -- sh -c \"printf '%s\\n' '{content}' > /home/backup-user/{name}/payload.txt\"")

    client = by_hostname("restic-client")
    backend = by_hostname("restic-backend")

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

    client.succeed("systemctl cat restic-backups-append-ignored.service | grep -F 'User=backup-user'")
    client.succeed("systemctl cat restic-backups-append-ignored.service | grep -F 'ProtectHome=tmpfs'")
    client.succeed("systemctl cat restic-backups-append-ignored.service | grep -F 'PrivateUsers=true'")
    client.succeed("systemctl cat restic-backups-append-ignored.service | grep -F 'ProtectSystem=strict'")
    client.succeed("systemctl cat restic-backups-append-ignored.service | grep -F 'RESTIC_PASSWORD_FILE=$CREDENTIALS_DIRECTORY/repository-password'")
    client.fail("systemctl cat restic-backups-append-ignored.service | grep -F '/run/credentials/restic-backups-append-ignored.service/repository-password'")
    client.succeed("systemctl cat restic-backups-append-ignored.service | grep -F 'RestrictAddressFamilies=' | grep -F 'AF_INET' | grep -F 'AF_INET6'")
    client.fail("systemctl cat restic-backups-append-ignored.service | grep -F 'RestrictAddressFamilies=' | grep -F 'AF_UNIX'")
    client.succeed("systemctl cat restic-backups-append-ignored.service | grep -F 'BindReadOnlyPaths=/home/backup-user/append-ignored'")
    client.succeed("systemctl cat restic-backups-append-ignored.service | grep -F 'backup --group-by='")
    client.succeed("systemctl cat restic-backups-append-ignored.service | grep -F 'forget --prune --group-by='")
    client.succeed("systemctl cat restic-backups-append-ignored.service | grep -F ' check '")
    client.succeed("grep -F '${pkgs.restic}/bin/restic unlock' /nix/store/*-restic-append-ignored/bin/restic-append-ignored")
    client.succeed("systemctl cat restic-backups-normal-strict.service | grep -F 'forget --prune --group-by='")
    client.succeed("systemctl cat restic-backups-s3.service | grep -F 'LoadCredential=aws-access-key-id:/etc/credentials/restic/s3/aws-access-key-id'")
    client.succeed("systemctl cat restic-backups-s3.service | grep -F 'LoadCredential=aws-secret-access-key:/etc/credentials/restic/s3/aws-secret-access-key'")
    client.succeed("systemctl cat restic-backups-s3.service | grep -F -- '--exclude-file='")

    client.succeed("systemctl start restic-backups-append-ignored.service || true")
    client.fail("systemctl is-failed --quiet restic-backups-append-ignored.service")

    for name in ["append-ignored", "append-strict", "normal-strict", "check-damaged"]:
        write_rest_credentials(name)
        write_payload(name, f"{name} payload")

    write_rest_credentials("normal-strict", "wrong-backend-secret")
    client.fail("systemctl start restic-backups-normal-strict.service")
    assert service_result("normal-strict") == "exit-code"
    write_rest_credentials("normal-strict")

    client.succeed("mkdir -p /etc/credentials/restic/s3 /home/backup-user/s3")
    client.succeed("printf '%s' 'repo-secret' > /etc/credentials/restic/s3/repository-password")
    client.succeed(f"printf '%s' '{s3_key_id}' > /etc/credentials/restic/s3/aws-access-key-id")
    client.succeed(f"printf '%s' '{s3_secret_key}' > /etc/credentials/restic/s3/aws-secret-access-key")
    client.succeed("chmod 0700 /etc/credentials /etc/credentials/restic /etc/credentials/restic/s3")
    client.succeed("chmod 0600 /etc/credentials/restic/s3/repository-password /etc/credentials/restic/s3/aws-access-key-id /etc/credentials/restic/s3/aws-secret-access-key")
    client.succeed("chown -R backup-user:users /home/backup-user/s3")
    write_payload("s3", "s3 payload")
    client.succeed("runuser -u backup-user -- sh -c \"printf '%s\\n' 'excluded' > /home/backup-user/s3/excluded.txt\"")

    for name in ["append-ignored", "append-strict", "normal-strict", "check-damaged", "s3"]:
        client.succeed(f"systemctl start restic-backups-{name}.service")
        assert service_result(name) == "success"

    for name in ["append-ignored", "append-strict", "normal-strict"]:
        write_payload(name, f"{name} payload updated")
    write_payload("s3", "s3 payload updated")

    client.succeed("systemctl start restic-backups-append-ignored.service")
    assert service_result("append-ignored") == "success"
    client.fail("systemctl start restic-backups-append-strict.service")
    assert service_result("append-strict") == "exit-code"

    client.succeed("runuser -u backup-user -- dd if=/dev/urandom of=/home/backup-user/normal-strict/large.bin bs=1M count=64 status=none")
    client.succeed("RESTIC_REST_USERNAME=$(cat /etc/credentials/restic/normal-strict/backend-username) RESTIC_REST_PASSWORD=$(cat /etc/credentials/restic/normal-strict/backend-password) RESTIC_PASSWORD_FILE=/etc/credentials/restic/normal-strict/repository-password RESTIC_REPOSITORY=rest:http://restic-backend:8002/normal-strict ${pkgs.restic}/bin/restic backup /home/backup-user/normal-strict >/tmp/create-stale-lock.log 2>&1 & printf '%s' $! > /tmp/create-stale-lock.pid")
    backend.wait_until_succeeds("set -- /var/lib/restic-normal/normal-strict/locks/*; test -e \"$1\"", timeout=10)
    client.succeed("kill -9 $(cat /tmp/create-stale-lock.pid) || true")
    backend.succeed("set -- /var/lib/restic-normal/normal-strict/locks/*; test -e \"$1\"")
    client.succeed("systemctl start restic-backups-normal-strict.service")
    assert service_result("normal-strict") == "success"
    backend.succeed("set -- /var/lib/restic-normal/normal-strict/locks/*; test ! -e \"$1\"")
    client.succeed("systemctl start restic-backups-s3.service")
    assert service_result("s3") == "success"

    backend.succeed("set -- /var/lib/restic-normal/check-damaged/data/*/*; rm \"$1\"")
    client.fail("systemctl start restic-backups-check-damaged.service")
    assert service_result("check-damaged") == "exit-code"
    client.succeed("journalctl -u restic-backups-check-damaged.service -n 80 | grep -E 'check|Fatal|not found|repository contains errors|does not exist'")

    backend.succeed("test -d /var/lib/restic-append/append-ignored/data")
    backend.succeed("test -d /var/lib/restic-normal/normal-strict/data")

    client.succeed("AWS_ACCESS_KEY_ID=$(cat /etc/credentials/restic/s3/aws-access-key-id) AWS_SECRET_ACCESS_KEY=$(cat /etc/credentials/restic/s3/aws-secret-access-key) RESTIC_PASSWORD_FILE=/etc/credentials/restic/s3/repository-password RESTIC_REPOSITORY=s3:http://restic-backend:3900/restic-s3 ${pkgs.restic}/bin/restic snapshots")
    client.succeed("mkdir -p /tmp/restic-restore")
    client.succeed("AWS_ACCESS_KEY_ID=$(cat /etc/credentials/restic/s3/aws-access-key-id) AWS_SECRET_ACCESS_KEY=$(cat /etc/credentials/restic/s3/aws-secret-access-key) RESTIC_PASSWORD_FILE=/etc/credentials/restic/s3/repository-password RESTIC_REPOSITORY=s3:http://restic-backend:3900/restic-s3 ${pkgs.restic}/bin/restic restore latest --target /tmp/restic-restore")
    client.succeed("grep -F 's3 payload updated' /tmp/restic-restore/home/backup-user/s3/payload.txt")
    client.fail("test -e /tmp/restic-restore/home/backup-user/s3/excluded.txt")
  '';
}
