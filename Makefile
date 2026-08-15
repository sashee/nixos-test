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

# SHARD=i/n: run every n'th check of the set, starting at i. One field rather than
# a separate index and total, so the two always travel together -- a CI matrix
# listing 1/4 2/4 3/4 4/4 states the total on every line, where an index paired
# with a total declared elsewhere could quietly disagree about how many shards
# exist and drop the difference.
#
# The check list is still lib.checkSets.$(SET) read exactly as an unsharded run
# reads it, so the flake stays the single source of truth -- a check added there
# lands in some shard on its own, and CI never names a test. Round-robin over the
# (alphabetical) attrNames rather than a duration-balanced split: balancing would
# mean checking in a table of measured runtimes that silently goes stale, for a
# worst-shard difference measured at ~20 minutes. Raising n is the cheaper knob.
#
# The default runs the whole set, so `make run-rpi-tests` on a laptop is unchanged.
SHARD := 1/1
# Recursive `=`: these have to see a SHARD given on the command line.
SHARD_INDEX = $(word 1,$(subst /, ,$(SHARD)))
SHARD_TOTAL = $(word 2,$(subst /, ,$(SHARD)))

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

# Build the patched rpi kernel (the expensive part every rpi check reuses) and
# pack it into a file:// binary cache under ./rpi-kernel-cache. Pairs with
# import-rpi-kernel to carry a built kernel from an aarch64 machine to a laptop,
# so a local run-rpi-tests does not compile it under emulation. NOT used by CI:
# each rpi shard builds the kernel natively on its own runner, which was measured
# to cost the same wall clock as sharing one build (see the checks-rpi5 header in
# ci.yml). zstd instead of the default xz: the multi-hundred-MB kernel NAR
# compresses much faster and the directory usually gets zipped anyway.
#
# `^*` -- ALL outputs, not just the default `out`. The kernel derivation has
# three (out, dev, modules) and a NixOS system needs `modules` too, so an
# out-only cache leaves the derivation unbuilt as far as nix is concerned:
# an importer would recompile the whole kernel to produce the missing output,
# which is exactly what this target exists to avoid.
export-rpi-kernel:
	$(NIX) build -L --max-jobs $(MAX_JOBS) --no-link "$(FLAKE)#packages.aarch64-linux.rpi-test-kernel^*"
	rm -rf rpi-kernel-cache
	$(NIX) copy --to "file://$(CURDIR)/rpi-kernel-cache?compression=zstd" "$(FLAKE)#packages.aarch64-linux.rpi-test-kernel^*"

# Import an export-rpi-kernel cache into the local store so run-rpi-tests skips
# the kernel compile. Evaluates the kernel paths locally first: if flake.lock or
# the kernel config drifted from the machine that produced the cache, the copy
# fails with "path not available" instead of silently importing a stale kernel.
#
# Every output, not just `out` -- see export-rpi-kernel. The output names are read
# off the derivation rather than listed here, so a kernel that grows an output
# cannot leave this target quietly importing a partial set (which nix repairs by
# recompiling, turning a 2-minute import into a 1.5-hour build).
#
# The cache is unsigned, so the copy needs --no-check-sigs, which in turn needs a
# trusted user -- hence sudo by default, since a laptop's login user usually is
# not one. Pass SUDO= to drop it where the invoking user is already trusted.
SUDO := sudo
import-rpi-kernel:
	@test -n "$(CACHE)" || { echo "usage: make import-rpi-kernel CACHE=path/to/rpi-kernel-cache [SUDO=]" >&2; exit 1; }
	set -euo pipefail; \
	paths=$$($(NIX) eval --raw "$(FLAKE)#packages.aarch64-linux.rpi-test-kernel" \
		--apply 'k: builtins.concatStringsSep "\n" (map (o: k.$${o}.outPath) k.outputs)'); \
	echo "importing:"; printf '  %s\n' $$paths; \
	$(SUDO) $(NIX) copy --no-check-sigs --from "file://$(abspath $(CACHE))" $$paths

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
# and a check outside every set is never built by anyone. SHARD (see above) narrows
# that iteration to one CI leg's slice of the set; it changes which checks this
# invocation runs, never how one runs.
#
# Each check gets up to ATTEMPTS runs (see above). A pass that needed a retry is
# announced as "=== FLAKY: <name> ...", so grepping the CI log still shows which
# tests are unstable instead of the retry quietly absorbing them. The loop stops
# at the first check that exhausts its attempts, so a genuinely broken suite
# costs one extra check run, not double.
run-checks:
	@test -n "$(SYSTEM)" -a -n "$(SET)" || { echo "usage: make run-checks SYSTEM=<system> SET=<set> [SHARD=i/n]; or one of run-eval-tests, run-rpi-tests, run-rpi-x86-tests, run-host-tests HOST=..." >&2; exit 1; }
	@test "$(words $(subst /, ,$(SHARD)))" -eq 2 -a "$(SHARD_INDEX)" -ge 1 -a "$(SHARD_INDEX)" -le "$(SHARD_TOTAL)" 2>/dev/null || { echo "invalid SHARD=$(SHARD): expected i/n with 1 <= i <= n" >&2; exit 1; }
	set -euo pipefail; \
	names_attr="lib.checkSets.$(SET)"; \
	all=$$($(NIX) eval --raw "$(FLAKE)#$$names_attr" --apply 'cs: builtins.concatStringsSep "\n" (builtins.attrNames cs)'); \
	attrs=$$(printf '%s\n' "$$all" | awk 'NR % $(SHARD_TOTAL) == $(SHARD_INDEX) % $(SHARD_TOTAL)'); \
	test -n "$$attrs" || { echo "shard $(SHARD) of $$names_attr is empty (more shards than checks); a leg that runs nothing must not report green" >&2; exit 1; }; \
	echo "$$names_attr shard $(SHARD):" $$attrs; \
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
	echo "=== all of lib.checkSets.$(SET) shard $(SHARD) passed on $(SYSTEM)"
