{ nixpkgs, pkgs, machineModule, stateVersion }:

# The media library's storage settings as hosts/rpi5 deploys them (spec/features/media-store): the
# tracks go to the "s3" backend alone, and writes into the database keep 2 GiB free.
#
# Upstream's checks boot media-store on this config with testNodeMediaStoreS3's placeholder
# credential, which nothing answers, so none of them sees a track reach S3. Here the placeholder is
# replaced the way the operator does it (hosts/rpi5: encrypt with the backend's name, restart), with
# one for a one-node Garage behind nginx for TLS on the same machine -- the shape of e2ee-store's
# own nix/tests/s3.nix, which runs the module's offloading in depth on a `demo` instance.
#
# The credential has the keys the Pi's has: virtual-host URLs, and reads through a CloudFront
# distribution (e2ee-store's aws/s3-backend.yml). A second nginx vhost stands in for CloudFront as
# that stack configures it: it forwards everything to S3 with the Host replaced by the bucket's
# virtual-host name and caches nothing. Upstream's Rust suite tests which requests go to the read
# endpoint, against a path-style fake; what this adds is the Pi's keys surviving a media-store bump
# (the backend refuses unknown ones at startup) and virtual-host signatures surviving the Host
# rewrite.

let
  certs = import ./test-cert.nix { inherit pkgs; } {
    name = "s3";
    sans = [ "localhost" "media.localhost" "reads.localhost" ];
  };

  # Garage's key format: GK and 24 hex digits, and 64 hex digits. Imported into Garage by the test.
  keyId = "GK0123456789abcdef01234567";
  secret = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
  bucket = "media";

  # The credential file hosts/rpi5 tells the operator to write. Plaintext in the store, as a
  # test's may be.
  credentialFile = pkgs.writeText "s3.toml" ''
    endpoint = "https://localhost:9000"
    region = "garage"
    bucket = "${bucket}"
    prefix = "media-store/"
    access_key_id = "${keyId}"
    secret_access_key = "${secret}"
    url_style = "virtual-host"
    read_endpoint = "https://reads.localhost:9001"
  '';

  # What a read is signed for: the bucket's virtual-host name at the endpoint.
  bucketHost = "${bucket}.localhost:9000";
in
nixpkgs.lib.nixos.runTest {
  name = "media-store-s3";
  hostPkgs = pkgs;
  # Ceiling, not a wait: the aarch64 variant runs under TCG on the KVM-less CI runner.
  globalTimeout = 1800;

  nodes.machine = { lib, pkgs, ... }: {
    imports = [ machineModule ];

    networking.hostName = "media-store-s3";
    virtualisation.memorySize = lib.mkDefault 2048;
    # Garage wants 1 GiB free. Less than media-store's 2 GiB reserve is left either way, which
    # the reserve's subtest relies on: the size is set, not a default.
    virtualisation.diskSize = 2048;
    security.pki.certificateFiles = [ certs.caFile ];
    environment.systemPackages = [ pkgs.minio-client pkgs.curl ];
    networking.hosts."127.0.0.1" = [ "${bucket}.localhost" "reads.localhost" ];

    services.garage = {
      enable = true;
      package = pkgs.garage;
      settings = {
        rpc_bind_addr = "127.0.0.1:3901";
        rpc_public_addr = "127.0.0.1:3901";
        rpc_secret = "5c1915fa04d0b6739675c61bf5907eb0fe3d9c69850c83820f51b4d25d13868c";
        s3_api = {
          s3_region = "garage";
          api_bind_addr = "[::1]:3900";
          # <bucket>.localhost names a bucket; plain localhost stays path-style, for mc.
          root_domain = ".localhost";
        };
      }
      // (
        if lib.versionAtLeast pkgs.garage.version "2" then
          {
            replication_factor = 1;
            consistency_mode = "consistent";
          }
        else
          { replication_mode = "none"; }
      );
    };

    services.nginx = {
      enable = true;
      # Per vhost, which requests reached it: "<method> <path> range=<Range> <status>".
      commonHttpConfig = ''
        log_format s3 '$request_method $uri range=$http_range $status';
      '';
      virtualHosts.localhost = {
        serverAliases = [ "${bucket}.localhost" ];
        onlySSL = true;
        listen = [
          {
            addr = "127.0.0.1";
            port = 9000;
            ssl = true;
          }
        ];
        sslCertificate = certs.certFile;
        sslCertificateKey = certs.keyFile;
        extraConfig = "access_log /var/log/nginx/s3.log s3;";
        locations."/" = {
          proxyPass = "http://[::1]:3900";
          # The client signs the Host it sent, port included.
          extraConfig = ''
            proxy_set_header Host $host:$server_port;
            client_max_body_size 64m;
          '';
        };
      };
      # The CloudFront stand-in: Managed-AllViewerExceptHostHeader passes on the path, the query
      # (the signature) and the headers (Range), and the origin's name replaces the Host.
      # Managed-CachingDisabled: nothing cached, as nginx caches nothing unless told to.
      virtualHosts."reads.localhost" = {
        onlySSL = true;
        listen = [
          {
            addr = "127.0.0.1";
            port = 9001;
            ssl = true;
          }
        ];
        sslCertificate = certs.certFile;
        sslCertificateKey = certs.keyFile;
        extraConfig = "access_log /var/log/nginx/reads.log s3;";
        locations."/" = {
          proxyPass = "http://[::1]:3900";
          extraConfig = "proxy_set_header Host ${bucketHost};";
        };
      };
    };

    system.stateVersion = stateVersion;
  };

  testScript = { nodes, ... }:
    let
      backend = nodes.machine.services.media-store;
      s3 = nodes.machine.services.media-store.storageBackends.s3;
    in
    ''
    import re

    # Read off the node's own options rather than restated, so this asserts the deployed wiring.
    SOCKET = "${backend.socketPath}"
    CRED = "${s3.credentialFile}"
    API = f"curl -sS --unix-socket {SOCKET} -H 'Origin: http://localhost' -b /tmp/jar -c /tmp/jar"


    def wait_until_serving():
        machine.wait_for_unit("media-store.service")
        # Type=simple: the unit is active before the socket is bound.
        machine.wait_for_file(SOCKET)


    def upload(path, offloadable):
        """PUTs the file as a blob; -> (HTTP status, its ID)."""
        blob = machine.succeed(f"sha256sum {path}").split()[0]
        flag = "-H 'Blob-Offloadable: true' " if offloadable else ""
        status = machine.succeed(
            f"{API} -o /dev/null -w '%{{http_code}}' -X PUT -H 'Content-Type: application/octet-stream' "
            f"{flag}--data-binary @{path} http://localhost/api/v1/blobs/{blob}"
        )
        return status, blob


    def objects():
        return machine.succeed("mc ls --recursive s3/${bucket}")


    wait_until_serving()

    with subtest("the deployed settings: tracks to s3 alone, 2 GiB kept free"):
        # The admin command reads the configuration the service runs with.
        report = machine.succeed("media-store storage")
        assert "target: s3 (" in report, report
        assert "of which 2.0 GiB stays free" in report, report

    with subtest("S3 is up: a one-node Garage with a bucket and the key"):
        machine.wait_for_unit("garage.service")
        machine.wait_for_open_port(3900)
        machine.wait_for_open_port(3901)
        node = machine.succeed("garage node id -q").strip().split("@")[0]
        machine.succeed(f"garage layout assign -z vm -c 1G {node}")
        machine.succeed("garage layout apply --version 1")
        machine.succeed("garage key import --yes -n media-store ${keyId} ${secret}")
        machine.succeed("garage bucket create ${bucket}")
        machine.succeed("garage bucket allow --read --write ${bucket} --key media-store")
        machine.wait_for_unit("nginx.service")
        machine.succeed("mc alias set s3 https://localhost:9000 ${keyId} ${secret} --api S3v4")

    with subtest("the operator's credential replaces the placeholder"):
        # As hosts/rpi5 tells the operator: the backend's name as --name=, then a restart.
        machine.succeed(f"systemd-creds encrypt --name=s3 ${credentialFile} {CRED}")
        machine.systemctl("restart media-store.service")
        wait_until_serving()
        machine.fail(f"grep -q ${secret} {CRED}")

    with subtest("a track goes to S3 alone, and plays back from there"):
        machine.succeed("media-store user create alice")
        link = re.search(r"#setup=(\S+)", machine.succeed("media-store setup-token create alice"))
        assert link is not None, "the CLI prints a setup link"
        machine.succeed(
            f"{API} -f -H 'Content-Type: application/json' -d '{{\"token\": \"{link.group(1)}\"}}' "
            "http://localhost/api/v1/auth/setup-token"
        )
        machine.succeed("head -c 100000 /dev/urandom > /tmp/track")
        status, track = upload("/tmp/track", offloadable=True)
        assert status == "201", status
        assert re.search(rf"media-store/[0-9a-f-]+/{track}", objects()), objects()
        report = machine.succeed("media-store storage")
        assert re.search(r"^s3\s+1\s", report, re.M), report
        assert re.search(r"^local\s+0\s", report, re.M), f"a copy stayed on the SD card:\n{report}"
        machine.succeed(
            f"{API} -f -o /tmp/whole http://localhost/api/v1/blobs/{track} && cmp /tmp/track /tmp/whole"
        )
        # Seeking: a range is read from S3 as asked, not the whole track.
        machine.succeed(
            f"{API} -f -r 1000-1999 -o /tmp/part http://localhost/api/v1/blobs/{track} "
            "&& cmp -i 1000:0 -n 1000 /tmp/track /tmp/part && test $(stat -c %s /tmp/part) = 1000"
        )

    with subtest("reads go through the read endpoint, everything else to S3 itself"):
        # Virtual-host style: the bucket is in the Host, so a path starts at the prefix.
        key = rf"/media-store/[0-9a-f-]+/{track}"
        # Waited for, not read once: nginx logs a request after its last byte has gone out, by
        # when the backend may already have passed it on to curl. The reads are done by now, so
        # the wait is for that write alone, and a read that went elsewhere fails in a minute.
        for range_, status in (("-", "200"), ("bytes=1000-1999", "206")):
            machine.wait_until_succeeds(
                f"grep -Eq '^GET {key} range={range_} {status}$' /var/log/nginx/reads.log",
                timeout=60,
            )
        reads = machine.succeed("cat /var/log/nginx/reads.log").splitlines()
        assert all(line.startswith(("GET ", "HEAD ")) for line in reads), reads
        direct = machine.succeed("cat /var/log/nginx/s3.log").splitlines()
        assert any(re.fullmatch(rf"PUT {key} range=- 200", line) for line in direct), direct
        # The one-byte reads that tell whether a copy is there stay at S3, and nothing else does.
        stray = [
            line for line in direct
            if re.match(rf"GET {key} ", line) and " range=bytes=0-0 " not in line
        ]
        assert not stray, stray

    with subtest("writes into the database keep 2 GiB free"):
        # This disk has less than that free, so a blob that belongs in the database -- every save
        # writes some -- is refused, and the server logs what it needed: twice the blob, as it
        # passes through the WAL, plus the reserve (backend SPEC §7.5).
        machine.succeed("head -c 1000 /dev/urandom > /tmp/directory")
        status, _ = upload("/tmp/directory", offloadable=False)
        assert status == "507", status
        logged = re.findall(
            r"the disk is too full: (\d+) bytes needed free",
            machine.succeed("journalctl -u media-store.service --no-pager"),
        )
        assert logged, "the refusal was not logged"
        assert int(logged[-1]) - 2 * 1000 == 2 * 1024**3, logged
        # The tracks play on.
        machine.succeed(f"{API} -f -o /dev/null http://localhost/api/v1/blobs/{track}")

    with subtest("without its credential the service fails, it is not skipped"):
        # hosts/rpi5 relies on this: a failing unit is reported, a skipped one is not.
        machine.succeed(f"rm {CRED}")
        machine.systemctl("restart media-store.service")
        machine.wait_until_succeeds(
            "journalctl -u media-store.service --no-pager | grep -q 'status=243/CREDENTIALS'"
        )
        result = machine.succeed("systemctl show media-store.service -p ConditionResult --value")
        assert result.strip() == "yes", result
  '';
}
