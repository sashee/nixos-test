# The iroh tunnel tools (iroh-uds-listen etc.) from sashee/nixos-test, pinned to a commit, built with this
# repository's nixpkgs. Only for development: `make iroh` exposes the backend's socket over iroh.
{
  pkgs ? import ./pkgs.nix { },
}:
let
  nixosTest = fetchTarball "https://github.com/sashee/nixos-test/archive/65892504d0ec05f258d4b6b578b0f3711dd778dc.tar.gz";
in
pkgs.callPackage "${nixosTest}/packages/iroh-ssh/package.nix" { }
