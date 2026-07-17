SHELL := bash
NIX := nix --extra-experimental-features 'nix-command flakes'
FLAKE := path:$(CURDIR)
MAX_JOBS := 2
# Concurrent per-check instantiations; each nix process peaks around 2 GiB,
# so keep EVAL_JOBS * 2 GiB well under available RAM.
EVAL_JOBS := 3

.PHONY: all-tests test-results qemu-result host-vm update-flake run-tests run-rpi-tests run-host-tests run-checks export-rpi-kernel import-rpi-kernel

all-tests: test-results

test-results:
	$(NIX) build -L --max-jobs $(MAX_JOBS) "$(FLAKE)#all-test-results"

qemu-result:
	$(NIX) build -L --max-jobs $(MAX_JOBS) "$(FLAKE)#qemu-plasma-result"

# QEMU runner for a laptop host config; run it with ./result/bin/run-<host>-vm
host-vm:
	@test -n "$(HOST)" || { echo "usage: make host-vm HOST=<host>" >&2; exit 1; }
	$(NIX) build -L --max-jobs $(MAX_JOBS) "$(FLAKE)#$(HOST)-vm"

update-flake:
	$(NIX) flake update

run-tests:
	$(MAKE) run-checks SYSTEM=x86_64-linux SET=generic-x86

run-rpi-tests:
	$(MAKE) run-checks SYSTEM=aarch64-linux

# Per-host check set (lib.checkSets.<host>), run by the host's own CI job.
run-host-tests:
	@test -n "$(HOST)" || { echo "usage: make run-host-tests HOST=<host>" >&2; exit 1; }
	$(MAKE) run-checks SYSTEM=x86_64-linux SET=$(HOST)

# CI: build the patched rpi kernel (the expensive part every rpi check reuses)
# and pack its closure into a file:// binary cache for upload as a workflow
# artifact. zstd instead of the default xz: the multi-hundred-MB kernel NAR
# compresses much faster and the artifact gets zipped anyway.
export-rpi-kernel:
	$(NIX) build -L --max-jobs $(MAX_JOBS) --no-link "$(FLAKE)#packages.aarch64-linux.rpi-test-kernel"
	rm -rf rpi-kernel-cache
	$(NIX) copy --to "file://$(CURDIR)/rpi-kernel-cache?compression=zstd" "$(FLAKE)#packages.aarch64-linux.rpi-test-kernel"

# Laptop: import a CI-built rpi kernel (the downloaded+unzipped rpi-kernel-cache
# artifact) into the local store so run-rpi-tests skips the kernel compile.
# Evaluates the kernel path locally first: if flake.lock or the kernel config
# drifted from the CI run that produced the artifact, the copy fails with "path
# not available" instead of silently importing a stale kernel. The artifact is
# unsigned (CI has no signing key), hence --no-check-sigs via sudo.
import-rpi-kernel:
	@test -n "$(CACHE)" || { echo "usage: make import-rpi-kernel CACHE=path/to/rpi-kernel-cache" >&2; exit 1; }
	set -euo pipefail; \
	path=$$($(NIX) eval --raw "$(FLAKE)#packages.aarch64-linux.rpi-test-kernel.outPath"); \
	echo "importing $$path"; \
	sudo $(NIX) copy --no-check-sigs --from "file://$(abspath $(CACHE))" "$$path"

# Evaluating all tests in one nix process peaks at ~15 GiB (each NixOS machine
# eval costs 1-2 GiB and the Boehm-GC evaluator never returns heap to the OS),
# which OOMed the 16 GiB CI runners. So: list the check names (cheap -
# attrNames doesn't force the derivations), instantiate each check in its own
# short-lived process, then build the .drvs one by one with a small, eval-free
# client. Memory stays bounded by the largest single check no matter how many
# tests are added. Outputs land in results/$(SYSTEM)/<check-name>.
#
# SET (optional) names a lib.checkSets.<SET> subset to run; the checks are
# still addressed as checks.$(SYSTEM).<name> (names are globally unique).
# Without SET the whole checks.$(SYSTEM) runs (the rpi/aarch64 path).
run-checks:
	@test -n "$(SYSTEM)" || { echo "use 'make run-tests', 'make run-rpi-tests' or 'make run-host-tests HOST=...'" >&2; exit 1; }
	set -euo pipefail; \
	names_attr="$(if $(SET),lib.checkSets.$(SET),checks.$(SYSTEM))"; \
	attrs=$$($(NIX) eval --raw "$(FLAKE)#$$names_attr" --apply 'cs: builtins.concatStringsSep "\n" (builtins.attrNames cs)'); \
	echo "$$names_attr:" $$attrs; \
	mkdir -p .drvs/$(SYSTEM) results/$(SYSTEM); \
	echo "$$attrs" | xargs -P $(EVAL_JOBS) -I NAME -- sh -c "$(NIX) path-info --derivation '$(FLAKE)#checks.$(SYSTEM).NAME' > .drvs/$(SYSTEM)/NAME"; \
	for name in $$attrs; do \
		echo "=== check: $$name"; \
		$(NIX) build -L --max-jobs $(MAX_JOBS) -o "results/$(SYSTEM)/$$name" "$$(cat .drvs/$(SYSTEM)/$$name)^*"; \
	done; \
	echo "=== all checks.$(SYSTEM) passed"
