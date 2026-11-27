# Where e2ee-store (the backend, the SDK, the NixOS module) comes from: the one place it is pinned. The hash makes
# the pin usable from pure evaluation too (e.g. a host's flake).
#
# Everything else imports this file and only uses paths inside it. To work on e2ee-store at the same time, see
# the Makefile (BACKEND, SDK) for the development loop.
fetchTarball {
  url = "https://github.com/sashee/e2ee-store/archive/09f0d147377d6f31b4a90e3420ecd500da6d85cd.tar.gz";
  sha256 = "134kapvp02fdmvp80lsx20dg6nc3i7fzhm6v9kc75756v09sp8a4";
}
