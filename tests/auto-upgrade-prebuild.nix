{ nixpkgs, pkgs, stateVersion }:

# Covers the prebuild phase of modules/auto-upgrade.nix: instantiate once, then build every
# outstanding derivation in its own `nix` process, in dependency order, with all outputs.
#
# Exercised against a hand-made flake rather than a real NixOS closure. The point under test
# is the loop, and a fake `nixosConfigurations.testhost.config.system.build.toplevel` built
# from raw `derivation` calls evaluates instantly and needs no nixpkgs in the guest -- a real
# system closure would make this test about kernel compiles instead.
#
# Run through the actual unit, not by invoking the script by hand: `nix flake update
# --commit-lock-file` shells out to git, which needs the GIT_AUTHOR_*/GIT_COMMITTER_*
# environment the unit provides. Calling the script directly passes locally and then fails on
# a real host with "Author identity unknown".
let
  system = pkgs.stdenv.hostPlatform.system;
  builder = "${pkgs.bash}/bin/bash";

  # Raw derivations get no PATH, so the builders use only bash builtins (echo) and absolute
  # store paths. Dependencies are declared by putting a derivation in an env var -- `dep`
  # below -- which is what makes nix order the builds, without needing to read the file.
  mkFlake = { midFails ? false }: pkgs.writeText "flake.nix" ''
    {
      inputs.common.url = "path:/etc/common-src";
      outputs = { self, common }:
        let
          leaf = derivation {
            name = "obo-leaf";
            system = "${system}";
            builder = "${builder}";
            outputs = [ "out" "dev" ];
            args = [ "-c" "echo leaf > $out; echo leafdev > $dev" ];
          };
          mid = derivation {
            name = "obo-mid";
            system = "${system}";
            builder = "${builder}";
            dep = leaf;
            args = [ "-c" "${if midFails then "echo boom; exit 1" else "echo mid $dep > $out"}" ];
          };
          top = derivation {
            name = "obo-top";
            system = "${system}";
            builder = "${builder}";
            dep = mid;
            args = [ "-c" "echo top $dep > $out" ];
          };
        in {
          nixosConfigurations.testhost.config.system.build.toplevel = top;
        };
    }
  '';

  flakeGood = mkFlake { };
  flakeMidFails = mkFlake { midFails = true; };

  fakeNixosRebuild = pkgs.writeShellScriptBin "nixos-rebuild" ''
    echo "fake nixos-rebuild: $*"
  '';
in
nixpkgs.lib.nixos.runTest {
  name = "auto-upgrade-prebuild";
  hostPkgs = pkgs;
  globalTimeout = 900;

  nodes.machine = { lib, ... }: {
    imports = [
      ../modules/nix-settings.nix
      ../modules/auto-upgrade.nix
    ];

    networking.hostName = "auto-upgrade-prebuild";

    common.autoUpgrade = {
      enable = true;
      flake = "/etc/nixos#testhost";
    };

    # The upgrade drags a GC in ahead of itself. Make it a complete no-op here, not merely
    # a capped sweep: nothing roots the derivations this test builds, so a GC that actually
    # collects would delete them between runs and the "second run has nothing to build"
    # subtest would be measuring a rebuild instead. (That the outputs are unrooted is the
    # real design -- spec/features/gc.md accepts it -- but it belongs in
    # tests/nix-gc-upgrade-exclusion.nix, not here.)
    systemd.services.nix-gc.script = lib.mkForce "${pkgs.coreutils}/bin/true";

    # Only the rebuild is mocked: the prebuild under test is the real one.
    system.build.nixos-rebuild = lib.mkForce fakeNixosRebuild;

    environment.systemPackages = [ pkgs.git ];

    # The fake derivations' builder. A VM test's store holds the node's closure, and a store
    # path named only inside the flake *text* is not part of it.
    virtualisation.additionalPaths = [ pkgs.bash ];

    # ...and having the path in the store is still not enough, because the flake is written
    # as text: the builder path in it is a bare string with no Nix string context, so the
    # guest's evaluator records no inputSrcs for it and the sandbox does not bind-mount it
    # ("executing .../bin/bash: No such file or directory"). `builtins.storePath` would
    # attach the context, but it is impure and flake evaluation is pure. Dropping the
    # sandbox for this node is the simple way out, and costs nothing here: the derivations
    # under test are three echo statements.
    nix.settings.sandbox = lib.mkForce false;

    # mkForce because nix.settings.substituters is a list option -- a plain `[ ]` merges
    # with nixpkgs' default and leaves cache.nixos.org in place, which in a network-less VM
    # means every single `nix build` first spends ~5s failing to resolve it.
    nix.settings.substituters = lib.mkForce [ ];

    system.stateVersion = stateVersion;
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("systemctl stop nixos-upgrade.timer nix-gc.timer")

    toplevel_attr = '/etc/nixos#nixosConfigurations."testhost".config.system.build.toplevel'

    def install_flake(path):
        machine.succeed(
            "mkdir -p /etc/nixos /etc/common-src",
            # A minimal flake for the `common` input; a path: input keeps this offline.
            "printf '{ outputs = _: { }; }\\n' > /etc/common-src/flake.nix",
            f"cp {path} /etc/nixos/flake.nix",
            "chmod u+w /etc/nixos/flake.nix",
        )
        machine.succeed(
            "cd /etc/nixos && git init -q 2>/dev/null || true",
            "cd /etc/nixos && git add -A",
            # The unit supplies GIT_AUTHOR_*/GIT_COMMITTER_*; a manual commit here needs its own.
            "cd /etc/nixos && git -c user.email=t@t -c user.name=t commit -q -m flake || true",
        )

    def run_upgrade():
        machine.succeed("systemctl reset-failed nixos-upgrade.service || true")
        return machine.execute("systemctl start nixos-upgrade.service")[0]

    def upgrade_log():
        # Scoped to the latest invocation rather than the unit's whole history: this test
        # runs the upgrade several times and every assertion below is about the run that
        # just happened. (Rotating the journal between runs would also work, but selecting
        # the invocation cannot race with a rotation that has not finished.)
        inv = machine.succeed(
            "systemctl show nixos-upgrade.service -p InvocationID --value"
        ).strip()
        return machine.succeed(f"journalctl _SYSTEMD_INVOCATION_ID={inv} -o cat --no-pager")

    def built_names():
        """Derivation names the loop actually attempted, in order.

        Parsed from the progress lines rather than substring-matching the whole log: the
        prebuild also prints "toplevel is <drv>", so a plain `"obo-top" in log` is true even
        when obo-top was never built. The progress lines carry the full `<hash>-<name>` --
        the hash is deliberate, since a real closure holds distinct derivations sharing a
        name (the Pi has two nixos-help) -- so strip it here rather than making the journal
        ambiguous. Store hashes contain no "-".
        """
        return [
            line.split("] ", 1)[1].split("-", 1)[1]
            for line in upgrade_log().splitlines()
            if "auto-upgrade: [" in line and "] " in line
        ]

    install_flake("${flakeGood}")

    with subtest("every outstanding derivation is built, one per nix process"):
        assert run_upgrade() == 0, upgrade_log()
        log = upgrade_log()
        # leaf, mid, top -- and the count nix planned must match what the loop iterated,
        # which is the cross-check that stops a parse regression from silently building
        # nothing and falling back to one monolithic (OOM-prone) build.
        assert "building 3 derivations, one per nix process" in log, log
        assert "all 3 derivations built" in log, log

    with subtest("built in dependency order"):
        assert built_names() == ["obo-leaf", "obo-mid", "obo-top"], built_names()

    with subtest("all outputs of every derivation are realised"):
        # The ^* requirement. A derivation whose default output is built but whose other
        # outputs are not counts as unbuilt to nix, so the nixos-rebuild that follows would
        # rebuild it -- on the real host that means recompiling the kernel, which is the
        # entire cost this loop exists to pay once. obo-leaf has out+dev precisely so an
        # out-only build fails here.
        machine.succeed(f"""
          set -eu
          drv=$(nix eval --raw '{toplevel_attr}.drvPath')
          for d in $(nix-store --query --requisites "$drv" | grep '[.]drv$'); do
            for o in $(nix-store --query --outputs "$d"); do
              nix-store --check-validity "$o" || {{ echo "missing output: $o" >&2; exit 1; }}
            done
          done
        """)

    with subtest("a second run has nothing to build"):
        assert run_upgrade() == 0
        assert "nothing to build" in upgrade_log()

    with subtest("a failing derivation aborts the loop and blocks the rebuild"):
        install_flake("${flakeMidFails}")
        assert run_upgrade() != 0, "the upgrade should fail when a derivation fails"
        # Only obo-mid and obo-top are in this plan: obo-leaf is byte-identical between the
        # two flake variants, so it is already built and correctly excluded. obo-mid fails,
        # so obo-top -- which depends on it -- must never be attempted, and the rebuild must
        # not run on a half-built system.
        assert built_names() == ["obo-mid"], built_names()
        assert "fake nixos-rebuild" not in upgrade_log(), upgrade_log()
  '';
}
