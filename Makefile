SHELL := bash
NIX := nix --extra-experimental-features 'nix-command flakes'
FLAKE := path:$(CURDIR)
MAX_JOBS := 2
# Concurrent per-check instantiations; each nix process peaks around 2 GiB,
# so keep EVAL_JOBS * 2 GiB well under available RAM.
EVAL_JOBS := 3

.PHONY: all-tests test-results qemu-result update-flake run-tests run-rpi-tests run-checks

all-tests: test-results

test-results:
	$(NIX) build -L --max-jobs $(MAX_JOBS) "$(FLAKE)#all-test-results"

qemu-result:
	$(NIX) build -L --max-jobs $(MAX_JOBS) "$(FLAKE)#qemu-plasma-result"

update-flake:
	$(NIX) flake update

run-tests:
	$(MAKE) run-checks SYSTEM=x86_64-linux

run-rpi-tests:
	$(MAKE) run-checks SYSTEM=aarch64-linux

# Evaluating all tests in one nix process peaks at ~15 GiB (each NixOS machine
# eval costs 1-2 GiB and the Boehm-GC evaluator never returns heap to the OS),
# which OOMed the 16 GiB CI runners. So: list the check names (cheap -
# attrNames doesn't force the derivations), instantiate each check in its own
# short-lived process, then build the .drvs one by one with a small, eval-free
# client. Memory stays bounded by the largest single check no matter how many
# tests are added. Outputs land in results/$(SYSTEM)/<check-name>.
run-checks:
	@test -n "$(SYSTEM)" || { echo "use 'make run-tests' or 'make run-rpi-tests'" >&2; exit 1; }
	set -euo pipefail; \
	attrs=$$($(NIX) eval --raw "$(FLAKE)#checks.$(SYSTEM)" --apply 'cs: builtins.concatStringsSep "\n" (builtins.attrNames cs)'); \
	echo "checks.$(SYSTEM):" $$attrs; \
	mkdir -p .drvs/$(SYSTEM) results/$(SYSTEM); \
	echo "$$attrs" | xargs -P $(EVAL_JOBS) -I NAME -- sh -c "$(NIX) path-info --derivation '$(FLAKE)#checks.$(SYSTEM).NAME' > .drvs/$(SYSTEM)/NAME"; \
	for name in $$attrs; do \
		echo "=== check: $$name"; \
		$(NIX) build -L --max-jobs $(MAX_JOBS) -o "results/$(SYSTEM)/$$name" "$$(cat .drvs/$(SYSTEM)/$$name)^*"; \
	done; \
	echo "=== all checks.$(SYSTEM) passed"
