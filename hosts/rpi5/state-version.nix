# The stateVersion this host deploys, as a plain string.
#
# A file rather than a literal in configuration.nix because flake.nix needs the value
# WITHOUT evaluating a system. The aarch64 checks can afford
# `rpi5Base.config.system.stateVersion` -- they evaluate rpi5Base anyway, for
# boot.kernelPackages -- but the x86 variant has no such base, and standing one up would
# mean a second module-system fixpoint of this whole host config in every one of its check
# processes (the Makefile gives each check its own), in the suite that exists to be fast.
# Reading a string costs nothing and cannot drift: configuration.nix is still the only
# place that DEFINES system.stateVersion, so both check sets resolve to the same value by
# construction.
"24.11"
