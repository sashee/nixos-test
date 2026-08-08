SHELL := bash
NIX := nix --extra-experimental-features 'nix-command flakes'
FLAKE := path:$(CURDIR)
# Parallelism for dependency builds within one nix invocation (nix's own
# default is 1). Serializing the VM tests does NOT depend on this: run-checks
# builds one check per invocation, so at most one test runs regardless.
# Override (e.g. MAX_JOBS=1) on RAM-constrained machines.
MAX_JOBS := auto

# Attempts per check before run-checks gives up. Derived from SYSTEM rather than
# set by each caller, because the reason for the retry IS the system: the aarch64
# runner (ubuntu-24.04-arm) has no /dev/kvm, so its guests run under TCG and
# timing-sensitive tests lose races they win with KVM - CI run 31093886542 opened
# iroh-ssh's failsafe against a demonstrably healthy tunnel because three probes
# in a row came back empty during relay churn. The x86 sets run with KVM and get
# no retry, so a failure there stays a failure. A retry re-runs the VM test for
# real: nix does not cache build failures, and the check derivation is unchanged,
# so the same drv is built again.
#
# Recursive `=`, so it sees the SYSTEM of the invocation. A command-line
# ATTEMPTS=2 still overrides it, to retry an x86 set by hand.
ATTEMPTS = $(if $(filter aarch64-linux,$(SYSTEM)),2,1)

.PHONY: host-vm update-flake run-eval-tests run-rpi-tests run-rpi-x86-tests run-host-tests run-checks export-rpi-kernel import-rpi-kernel

# QEMU runner for a laptop host config; run it with ./result/bin/run-<host>-vm
host-vm:
	@test -n "$(HOST)" || { echo "usage: make host-vm HOST=<host>" >&2; exit 1; }
	$(NIX) build -L --max-jobs $(MAX_JOBS) "$(FLAKE)#$(HOST)-vm"

update-flake:
	$(NIX) flake update

# The eval-only checks (lib.checkSets.eval): runCommands that assert on pure data
# and on the deployed host configs without building a machine image, so this needs
# no KVM and finishes in about a minute. Its own set, and its own CI leg, for that
# reason - a stamp/endpoint drift should not report behind a VM suite.
run-eval-tests:
	$(MAKE) run-checks SYSTEM=x86_64-linux SET=eval

run-rpi-tests:
	$(MAKE) run-checks SYSTEM=aarch64-linux SET=rpi5

# The rpi5 host config on x86 (lib.checkSets.rpi5-x86): the same feature tests as
# run-rpi-tests, on the real config but the stock x86 kernel, so they run under KVM
# in minutes instead of under aarch64 TCG. Not a substitute for run-rpi-tests - see
# the header on rpi5X86Checks in flake.nix for what it cannot catch.
run-rpi-x86-tests:
	$(MAKE) run-checks SYSTEM=x86_64-linux SET=rpi5-x86

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
# attrNames doesn't force the derivations), then eval+run the checks strictly
# one by one, each in its own nix process. No check is evaluated before its
# turn, so memory stays bounded by one eval (~2 GiB, held by the nix client
# while its VM test runs) plus the VM under test, no matter how many tests are
# added. Outputs land in results/$(SYSTEM)/<check-name>.
#
# SET names the lib.checkSets.<SET> to run; the checks are still addressed as
# checks.$(SYSTEM).<name> (names are globally unique). Every check belongs to
# exactly one set, so iterating the set - not checks.$(SYSTEM) - is what CI does,
# and a check outside every set is never built by anyone.
#
# Each check gets up to ATTEMPTS runs (see above). A pass that needed a retry is
# announced as "=== FLAKY: <name> ...", so grepping the CI log still shows which
# tests are unstable instead of the retry quietly absorbing them. The loop stops
# at the first check that exhausts its attempts, so a genuinely broken suite
# costs one extra check run, not double.
run-checks:
	@test -n "$(SYSTEM)" -a -n "$(SET)" || { echo "usage: make run-checks SYSTEM=<system> SET=<set>; or one of run-eval-tests, run-rpi-tests, run-rpi-x86-tests, run-host-tests HOST=..." >&2; exit 1; }
	set -euo pipefail; \
	names_attr="lib.checkSets.$(SET)"; \
	attrs=$$($(NIX) eval --raw "$(FLAKE)#$$names_attr" --apply 'cs: builtins.concatStringsSep "\n" (builtins.attrNames cs)'); \
	echo "$$names_attr:" $$attrs; \
	mkdir -p results/$(SYSTEM); \
	for name in $$attrs; do \
		attempt=1; \
		while :; do \
			echo "=== check: $$name (attempt $$attempt/$(ATTEMPTS))"; \
			if $(NIX) build -L --max-jobs $(MAX_JOBS) -o "results/$(SYSTEM)/$$name" "$(FLAKE)#checks.$(SYSTEM).$$name"; then \
				if [ "$$attempt" -gt 1 ]; then echo "=== FLAKY: $$name passed on attempt $$attempt of $(ATTEMPTS)"; fi; \
				break; \
			fi; \
			if [ "$$attempt" -ge $(ATTEMPTS) ]; then echo "=== FAILED: $$name after $(ATTEMPTS) attempt(s)" >&2; exit 1; fi; \
			echo "=== RETRY: $$name failed on attempt $$attempt, retrying" >&2; \
			attempt=$$((attempt + 1)); \
		done; \
	done; \
	echo "=== all of lib.checkSets.$(SET) passed on $(SYSTEM)"
