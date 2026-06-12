# Auto-Upgrade Test Plan

## Goal

Add an end-to-end NixOS VM test for `modules/auto-upgrade.nix` that verifies the
real update flow without contacting GitHub.

The test should prove:

- a laptop-local `/etc/nixos/flake.lock` initially pins `common` to commit A
- `nixos-upgrade.service` runs `nix flake update common --flake /etc/nixos --commit-lock-file`
- the local lock advances to commit B from a local Git repo
- `nixos-rebuild boot` prepares generation B without switching the running system
- after reboot, generation B is active

## Current Module Behavior

`modules/auto-upgrade.nix` is imported by `modules/common-desktop.nix` and is
enabled by default.

Public options are intentionally minimal:

```nix
common.autoUpgrade = {
  enable = true;
  flake = "/etc/nixos#my-laptop";
};
```

The input name is hardcoded to `common`. Laptop flakes must use:

```nix
inputs.common.url = "github:sashee/nixos-test";
```

Generated behavior for a host named `auto-upgrade-test` with
`common.autoUpgrade.flake = "/etc/nixos#auto-upgrade-test"` should include:

```bash
nix flake update common --flake /etc/nixos --commit-lock-file
```

and then NixOS' built-in auto-upgrade service should run approximately:

```bash
nixos-rebuild boot \
  --print-build-logs \
  --commit-lock-file \
  --refresh \
  --flake /etc/nixos#auto-upgrade-test
```

The module also sets Git identity for the service:

```text
GIT_AUTHOR_NAME=NixOS Auto-upgrade
GIT_AUTHOR_EMAIL=root@auto-upgrade-test
GIT_COMMITTER_NAME=NixOS Auto-upgrade
GIT_COMMITTER_EMAIL=root@auto-upgrade-test
```

## Proposed Test File

Add:

```text
tests/auto-upgrade.nix
```

Wire it into `flake.nix`:

```nix
autoUpgradeTest = import ./tests/auto-upgrade.nix {
  inherit nixpkgs pkgs commonDesktopModule stateVersion;
};

testResults = {
  auto-upgrade = autoUpgradeTest;
  # existing tests...
};

packages.${system} = {
  auto-upgrade-driver = autoUpgradeTest.driver;
  auto-upgrade-driver-interactive = autoUpgradeTest.driverInteractive;
  # existing packages...
};
```

Update `qemuPlasmaResult` output links if needed through the existing
`testResults` aggregation.

## VM Test Design

Use one VM node.

Node config:

```nix
nodes.machine = { ... }: {
  imports = [ commonDesktopModule ];

  networking.hostName = "auto-upgrade-test";
  common.autoUpgrade.flake = "/etc/nixos#auto-upgrade-test";
  system.stateVersion = stateVersion;
};
```

The test should create two local Git repositories inside the VM:

```text
/srv/common       fake central common repo, with commits A then B
/etc/nixos        fake laptop-local flake repo, locked to /srv/common commit A
```

No GitHub/network access should be needed. Use `git+file:///srv/common` for the
local `common` input.

## Fake Central Repo

Create `/srv/common` as a Git repo.

Commit A should export a NixOS module that writes a recognizable file:

```nix
{
  outputs = { self }: {
    nixosModules.test = { ... }: {
      environment.etc."auto-upgrade-value".text = "a";
    };
  };
}
```

Commit B changes only the value:

```nix
environment.etc."auto-upgrade-value".text = "b";
```

Record both commit hashes in files for assertions:

```text
/tmp/common-rev-a
/tmp/common-rev-b
```

## Fake Laptop Flake

Create `/etc/nixos` as a Git repo.

Use a local flake like this:

```nix
{
  inputs = {
    nixpkgs.url = "path:/nix/store/...-source";
    common.url = "git+file:///srv/common";
  };

  outputs = { nixpkgs, common, ... }: {
    nixosConfigurations.auto-upgrade-test = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        common.nixosModules.test
        {
          system.stateVersion = "26.05";
          networking.hostName = "auto-upgrade-test";
          common.autoUpgrade.enable = false;
        }
      ];
    };
  };
}
```

Important notes:

- The `nixpkgs.url` must avoid network. Generate the file from the Nix test and
  splice in the store path `${nixpkgs}`.
- The rebuilt target config should set `common.autoUpgrade.enable = false` or not
  import this repo's common module at all. For this fake rebuilt system, the test
  only needs `/etc/auto-upgrade-value`. Avoid recursive dependence on the real
  common desktop module inside the fake target unless necessary.
- `system.stateVersion` should use the test's `stateVersion` value.

After creating `/etc/nixos/flake.nix`, run:

```bash
nix flake lock --flake /etc/nixos
git -C /etc/nixos add flake.nix flake.lock
git -C /etc/nixos commit -m 'initial laptop lock'
```

This should lock `common` to commit A.

Then add commit B to `/srv/common`.

## Test Flow

The test script should:

1. Start the VM and wait for boot.

2. Create `/srv/common` commit A.

3. Create `/etc/nixos` and lock it to commit A.

4. Add `/srv/common` commit B.

5. Verify `/etc/nixos/flake.lock` currently references commit A and not B.

6. Verify the generated service contains expected static pieces:

   ```bash
   systemctl cat nixos-upgrade.service
   systemctl cat nixos-upgrade.timer
   ```

   Check for:

   ```text
   nix flake update common --flake /etc/nixos --commit-lock-file
   boot
   --print-build-logs
   --commit-lock-file
   --flake /etc/nixos#auto-upgrade-test
   RandomizedDelaySec=2h
   ```

7. Start the real service:

   ```bash
   systemctl start nixos-upgrade.service
   ```

8. Verify the service succeeded:

   ```bash
   systemctl status nixos-upgrade.service --no-pager
   journalctl -u nixos-upgrade.service --no-pager
   ```

9. Verify `/etc/nixos/flake.lock` now references commit B.

10. Verify `/etc/nixos` has a new Git commit from auto-upgrade:

    ```bash
    git -C /etc/nixos log --oneline -2
    git -C /etc/nixos status --short
    ```

    Expected: clean worktree after service success.

11. Verify the running system has not switched live. If the initial VM system does
    not contain `/etc/auto-upgrade-value`, assert one of these:

    ```bash
    test ! -e /etc/auto-upgrade-value
    ```

    or, if the test installs initial A before running the service:

    ```bash
    test "$(cat /etc/auto-upgrade-value)" = a
    ```

12. Reboot the VM:

    ```python
    machine.reboot()
    ```

13. After reboot, verify generation B is active:

    ```bash
    test "$(cat /etc/auto-upgrade-value)" = b
    ```

This proves `operation = "boot"`: generation B is only active after reboot.

## Avoiding Network

Use only local inputs:

```nix
inputs.nixpkgs.url = "path:${nixpkgs}";
inputs.common.url = "git+file:///srv/common";
```

If Nix complains about dirty Git trees, ensure both `/srv/common` and
`/etc/nixos` are committed before running lock/update/build commands.

## Git Requirements

Set Git identity in the test setup for manual commits:

```bash
git config --global user.name 'Test User'
git config --global user.email 'test@example.invalid'
```

The auto-upgrade service itself should use the module-provided env:

```text
NixOS Auto-upgrade <root@auto-upgrade-test>
```

Because `/etc/nixos` is created as root-owned inside the VM, Git
`safe.directory` should not be needed for the test.

## Acceptance Criteria

The new check should pass with:

```bash
nix --extra-experimental-features 'nix-command flakes' build -L \
  'path:/home/sashee/workspace/nixos-test#checks.x86_64-linux.auto-upgrade'
```

The test should fail if:

- `common.autoUpgrade` stops defaulting to enabled
- the update input name changes from `common`
- `--commit-lock-file` is removed
- `operation` changes from `boot`
- the local lock does not advance from commit A to B
- the rebuilt generation switches live before reboot
- generation B is not active after reboot

## Potential Pitfalls

- `nixos-rebuild` may need a bootloader/root filesystem in the fake rebuilt
  target. If so, add minimal VM-safe settings to the fake target flake or reuse
  modules from the current VM config.
- The running test VM imports `commonDesktopModule`, but the fake rebuilt target
  does not need to. Keeping the fake target minimal should make the test faster.
- `system.autoUpgrade` appends `--refresh` and `--flake ...` automatically when
  `system.autoUpgrade.flake` is set. Do not duplicate those flags manually.
- `nix flake update` updates existing locked inputs; `nix flake lock` only adds
  missing locks and should not be used for the actual update step.
- `--commit-lock-file` commits lock changes. If the lock does not change, no new
  commit is expected.
- Use committed Git changes for `/srv/common`; flake inputs track commits, not
  arbitrary dirty working tree state.
