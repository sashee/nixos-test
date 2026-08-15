# The API key the VM tests present to the receiver, issued at test-script time rather than at
# boot (SPEC.md §13). Every endpoint but /healthz refuses an unauthenticated request, on the read
# path as well as the write path, so a test that reads the receiver back needs a real key and a
# collector holding a copy of it.
#
# Why at runtime, which is the whole shape of this file: mp-collector reads its key ONCE, at
# startup, and it starts before almost everything else -- DefaultDependencies=false, ordered only
# after local-fs.target, and deliberately ahead of the time daemons -- whereas the key it has to
# present cannot exist until the receiver's StateDirectory= has made the database directory.
# Issuing it declaratively would therefore mean ordering the collector after the receiver, which
# dismantles the very boot ordering tests/boot-clock.nix and the upstream `ordering` and
# `collector-clock` cases exist to prove. So the collector boots holding the placeholder that
# flake.nix's testNodeCollectorApiKey provisions, forwards nothing that the receiver will keep,
# and is re-credentialled here exactly once. Upstream's own harness makes the same trade for the
# same reason (nix/tests/lib.nix, `authenticate`).
#
# One string shared by the three tests that read the receiver back, rather than a fourth copy of
# a helper that already exists three times: the procedure is subtle in three separate places --
# the user the key is issued as, the encryption round-trip, and the outbox a restart discards --
# and three copies would drift apart. Same shape as lib/test-rtc-base.nix, which is the existing
# precedent for sharing a chunk of test setup from lib/.
#
# Interpolates no store paths, so this one string serves the aarch64 and the x86 node sets alike:
# `install`, `runuser` and `systemd-creds` are all on root's PATH in any NixOS guest, the last
# because nixpkgs puts systemd itself in environment.systemPackages.
''
  # Imported inside the functions below rather than at the top. This string is concatenated ahead
  # of a test script that does its own `import json`, and the driver lints the result with ruff,
  # which fails the build on the redefinition -- so a module-level import here would make every
  # caller delete an import it plainly needs, coupling the two files for no reason.

  # Hardcoded rather than passed in: these are the module defaults, and the credential path is the
  # one flake.nix's testNodeCollectorApiKey provisions and hosts/rpi5/configuration.nix names. A
  # node that moved any of them would have to say so here too, which is the point -- there is one
  # place to look rather than an argument threaded through three test files.
  MP_DB = "/var/lib/monitoring-platform/measurements.db"
  MP_USER = "monitoring-platform"
  MP_CREDENTIAL = "/etc/credentials/mp-collector/mp-api-key"
  MP_COLLECTOR_SOCKET = "/run/mp-collector/mp-collector.sock"

  # The key in force, set by authenticate(). `None` means the query helpers present nothing at
  # all -- which is what makes a test that forgets to authenticate fail on the 401 it deserves,
  # rather than quietly reading rows back under someone else's credential.
  API_KEY = None


  def auth_header():
      return "" if API_KEY is None else f"-H 'Authorization: Bearer {API_KEY}' "


  def _collector_ever_synchronized(node):
      import json

      # The collector's own /healthz, which is unauthenticated on both services and stays
      # readable across everything this file does.
      raw = node.succeed(
          f"curl -sS --fail-with-body --unix-socket {MP_COLLECTOR_SOCKET} http://localhost/healthz"
      )
      return json.loads(raw)["clock"]["ever_synchronized"]


  def authenticate(node):
      # Issues a key in the receiver's own database and hands the collector a copy.
      #
      # MUST be called before any batch has been posted through the collector: step three
      # restarts it, and a restart discards whatever is in its outbox. In tests/system-metrics.nix
      # that is not a formality -- its first subtest is *about* what the collector is holding
      # while the clock is unset, so this belongs in the preamble, above the subtests.
      import shlex

      global API_KEY

      # What StateDirectory= would have made. The receiver has normally started by the time this
      # runs and the directory is already there, but `create-api-key` cannot create its own
      # parent, so a caller that authenticates before the first start would fail without this.
      node.succeed(f"install -d -m 0700 -o {MP_USER} -g {MP_USER} $(dirname {MP_DB})")

      # As the service user, NOT root: SQLite writes -wal and -shm beside the database, and
      # root-owned ones in that 0700 directory would be files the receiver itself could no longer
      # write. Same reason the out-of-band recipe in hosts/rpi5/configuration.nix issues the Pi's
      # key under `sudo -u monitoring-platform`.
      #
      # `create-api-key` prints the token and nothing else on stdout, so this captures it alone --
      # but it warns on stderr when the database did not already exist, and that warning would
      # land in the captured token without the redirect.
      token = node.succeed(
          f"runuser -u {MP_USER} -- monitoring-platform create-api-key "
          f"--db {MP_DB} --label harness 2>/dev/null"
      ).strip()
      if not token.startswith("mpk_"):
          raise Exception(f"create-api-key did not print a token: {token!r}")
      API_KEY = token

      # Read BEFORE the restart, because the restart resets it: the flag is per-process and has
      # to be re-earned by several consecutive good clock polls, so a test asserting on the clock
      # straight after this would otherwise race them. Asked rather than assumed, since a test
      # whose clock is deliberately unset never had it and must not wait for something that is
      # never going to happen.
      was_synchronized = _collector_ever_synchronized(node)

      # Re-encrypted to the same path under the same credential name the boot-time fixture used,
      # so LoadCredentialEncrypted= keeps decrypting exactly what it decrypted at boot and the
      # credential wiring stays under test instead of being switched off for the sake of an
      # easier rewrite. `--name` is authenticated into the blob and decryption compares it, so it
      # has to stay `mp-api-key` -- as does the file name.
      node.succeed(
          f"printf '%s' {shlex.quote(token)} "
          f"| systemd-creds encrypt --name=mp-api-key - {MP_CREDENTIAL}.new",
          f"chmod 0600 {MP_CREDENTIAL}.new",
          f"mv {MP_CREDENTIAL}.new {MP_CREDENTIAL}",
      )

      # The collector reads its credential once, at startup, so a restart is the only way it
      # picks this up. See the outbox warning at the top of this function.
      node.succeed("systemctl restart mp-collector.service")
      node.wait_for_unit("mp-collector.service")

      if was_synchronized:
          retry(
              lambda _: _collector_ever_synchronized(node),
              timeout_seconds=120,
          )
''
