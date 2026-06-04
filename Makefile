NIX := nix --extra-experimental-features 'nix-command flakes'
FLAKE := path:$(CURDIR)
MAX_JOBS := 2

.PHONY: all-tests test-results qemu-result update-flake

all-tests: test-results

test-results:
	$(NIX) build -L --max-jobs $(MAX_JOBS) "$(FLAKE)#all-test-results"

qemu-result:
	$(NIX) build -L --max-jobs $(MAX_JOBS) "$(FLAKE)#qemu-plasma-result"

update-flake:
	$(NIX) flake update
